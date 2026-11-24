// SnapStrip：拖动窗口时，屏幕顶部出现一条提示细条；把窗口拖到屏幕上三分之一
// 区域，条展开成一排布局格（左半、右半、四个角、最大化）；拖到某格上放开，
// 窗口就贴到那个布局。
// 只做这一件事：无菜单、无设置、无 Dock 图标。移动别人的窗口靠「辅助功能」
// 权限（AXUIElement），拖动检测靠全局鼠标事件监听。
import Cocoa
import ApplicationServices

// 布局定义：分数坐标，x/y 是左下角在屏幕可用区里的占比，w/h 是宽高占比
// （与 Cocoa 坐标方向一致：原点左下）
struct Layout {
    let x, y, w, h: CGFloat
    static let all: [Layout] = [
        Layout(x: 0,   y: 0,   w: 0.5, h: 1),   // 左半
        Layout(x: 0.5, y: 0,   w: 0.5, h: 1),   // 右半
        Layout(x: 0,   y: 0.5, w: 0.5, h: 0.5), // 左上
        Layout(x: 0.5, y: 0.5, w: 0.5, h: 0.5), // 右上
        Layout(x: 0,   y: 0,   w: 0.5, h: 0.5), // 左下
        Layout(x: 0.5, y: 0,   w: 0.5, h: 0.5), // 右下
        Layout(x: 0,   y: 0,   w: 1,   h: 1),   // 最大化
    ]
}

// 条的几何尺寸：收起时是菜单栏下方的一根提示细条，展开后是一排大格子；
// 展开位置特意压到距顶 110px，彻底避开菜单栏与刘海
enum StripGeom {
    static let tileW: CGFloat = 108
    static let tileH: CGFloat = 76
    static let gap: CGFloat = 12
    static let pad: CGFloat = 16
    static let hintTopGap: CGFloat = 52    // 提示条距屏幕顶边的距离（菜单栏下方）
    static let hintHeight: CGFloat = 50    // 提示条高度（宽度为屏幕的一半，水平居中）
    static let expandedTopGap: CGFloat = 110   // 布局列距屏幕顶边的距离（刘海下方）
    static let expandedSize = NSSize(
        width: pad * 2 + tileW * CGFloat(Layout.all.count) + gap * CGFloat(Layout.all.count - 1),
        height: pad * 2 + tileH)
}

// 条的绘制：半透明深色圆角底；展开时逐格画「小屏幕描边 + 按布局分数填色」，
// 鼠标悬停的格子底色更亮、填充更实
final class StripView: NSView {
    var expanded = false
    var highlight = -1  // 悬停的格子下标，-1 表示无

    // 每格在 view 坐标里的矩形（绘制与命中判断共用同一套几何）
    func tileRects() -> [NSRect] {
        guard expanded else { return [] }
        return Layout.all.indices.map { i in
            NSRect(x: StripGeom.pad + CGFloat(i) * (StripGeom.tileW + StripGeom.gap),
                   y: StripGeom.pad, width: StripGeom.tileW, height: StripGeom.tileH)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = expanded ? 14 : 16
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard expanded else {
            // 提示条：居中一行小字，告诉用户下一步往哪拖
            let text = "继续向上拖动，展开布局" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                  y: (bounds.height - size.height) / 2),
                      withAttributes: attrs)
            return
        }
        for (i, tile) in tileRects().enumerated() {
            NSColor.white.withAlphaComponent(i == highlight ? 0.20 : 0.08).setFill()
            NSBezierPath(roundedRect: tile, xRadius: 6, yRadius: 6).fill()
            let inner = tile.insetBy(dx: 12, dy: 12)
            let screen = NSBezierPath(roundedRect: inner, xRadius: 3, yRadius: 3)
            NSColor.white.withAlphaComponent(0.45).setStroke()
            screen.lineWidth = 1
            screen.stroke()
            let f = Layout.all[i]
            let region = NSRect(x: inner.minX + f.x * inner.width,
                                y: inner.minY + f.y * inner.height,
                                width: f.w * inner.width,
                                height: f.h * inner.height)
            NSColor.systemBlue.withAlphaComponent(i == highlight ? 0.95 : 0.55).setFill()
            NSBezierPath(roundedRect: region, xRadius: 2, yRadius: 2).fill()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var stripView: StripView!
    private var monitors: [Any] = []
    private var trustTimer: Timer?

    // 一次拖动的状态：按下时命中的窗口、它的起始原点（AX 坐标）、条是否已亮起
    private var dragWindow: AXUIElement?
    private var startOrigin: CGPoint = .zero
    private var stripVisible = false
    private var expanded = false
    private var dragScreen: NSScreen?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)  // 只在后台待命，不占 Dock、不抢焦点
        log("启动：\(Bundle.main.bundlePath) 屏幕：\(NSScreen.screens.map { NSStringFromRect($0.frame) })")
        buildPanel()
        showAbout()
        buildStatusItem()
        syncLoginItem()
        // 辅助功能权限：没授权时系统弹窗引导去「系统设置 → 隐私与安全性 →
        // 辅助功能」勾选本应用；轮询到授权后才装鼠标监听
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            installMonitors()
        } else {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    self?.installMonitors()
                }
            }
        }
    }

    // 关于窗口（家族经典样式）：应用名、版本、一句用法、权限提示，底部两个按钮——
    // 「在 GitHub 上查看」与「开始使用」（点它或关窗都只是隐藏，后台继续待命）
    private var aboutWindow: NSWindow?

    @objc private func showAbout() {
        if let window = aboutWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "关于 SnapStrip"
        window.isReleasedWhenClosed = false
        window.center()

        // 家族一贯布局（同 VideoTag 关于窗）：居中大图标、应用名、版本、说明、
        // 关键词一行、By Mr.Ben、mrben.net 链接；底部再钉两个按钮
        let icon = NSImageView()
        icon.image = NSApplication.shared.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 112).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 112).isActive = true
        let name = NSTextField(labelWithString: "SnapStrip")
        name.font = .systemFont(ofSize: 24, weight: .semibold)
        name.alignment = .center
        let version = NSTextField(labelWithString: "版本 0.1.0")
        version.font = .systemFont(ofSize: 13)
        version.textColor = .secondaryLabelColor
        version.alignment = .center
        let desc = NSTextField(wrappingLabelWithString: "拖动任意窗口时，顶部会出现提示条；把窗口拖到屏幕上三分之一，展开布局列表；拖到某个布局上放开，窗口就会贴到那个布局。")
        desc.alignment = .center
        let keywords = NSTextField(labelWithString: "左半 · 右半 · 左上 · 右上 · 左下 · 右下 · 最大化")
        keywords.font = .systemFont(ofSize: 12)
        keywords.textColor = .secondaryLabelColor
        keywords.alignment = .center
        let note = NSTextField(wrappingLabelWithString: "移动窗口需要「辅助功能」权限：系统设置 → 隐私与安全性 → 辅助功能，勾选 SnapStrip。")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.alignment = .center
        let by = NSTextField(labelWithString: "By Mr.Ben")
        by.font = .systemFont(ofSize: 13)
        by.alignment = .center
        let site = NSButton(title: "https://mrben.net", target: self, action: #selector(openSite))
        site.isBordered = false
        site.contentTintColor = .linkColor
        site.font = .systemFont(ofSize: 13)

        // 内容区：图标、名字、版本、说明、关键词、权限提示、署名、链接，自上而下居中排
        let stack = NSStackView(views: [icon, name, version, desc, keywords, note, by, site])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 底部按钮行（家族一贯布局）：一条发丝线压在上方，按钮钉在窗口最底部——
        // 左「在 GitHub 上查看」，右「开始使用」，中间留空
        let github = NSButton(title: "在 GitHub 上查看", target: self, action: #selector(openGitHub))
        let start = NSButton(title: "开始使用", target: self, action: #selector(startUsing))
        start.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        let buttons = NSStackView(views: [github, spacer, start])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.separatorColor.cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false

        if let content = window.contentView {
            content.addSubview(stack)
            content.addSubview(hairline)
            content.addSubview(buttons)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                desc.widthAnchor.constraint(equalTo: stack.widthAnchor),
                note.widthAnchor.constraint(equalTo: stack.widthAnchor),
                hairline.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                hairline.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                hairline.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -54),
                hairline.heightAnchor.constraint(equalToConstant: 1),
                buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            ])
        }
        aboutWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/i-love-osaka/SnapStrip")!)
    }

    @objc private func openSite() {
        NSWorkspace.shared.open(URL(string: "https://mrben.net")!)
    }

    @objc private func startUsing() {
        aboutWindow?.close()
    }

    // 再次双击图标（应用已在后台运行时）把关于窗口叫回来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showAbout() }
        return true
    }

    // 关于窗口关掉后应用不退出：它要在后台一直待命（明确写死，不靠默认行为）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // 菜单栏小图标：证明它在后台运行着，也能从这里重开关于窗或退出
    private var statusItem: NSStatusItem?

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1",
                                     accessibilityDescription: "SnapStrip")
        let menu = NSMenu()
        let about = NSMenuItem(title: "关于 SnapStrip", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        let login = NSMenuItem(title: "开机时启动", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        login.state = (UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? true) ? .on : .off
        let quit = NSMenuItem(title: "退出 SnapStrip",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(about)
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    // 开机启动：往 ~/Library/LaunchAgents 放一个 RunAtLoad 的 plist（删掉即取消）。
    // 默认开（用户明确要开机启动），菜单栏里可关；每次启动按当前 app 路径刷新一遍，
    // 挪了位置也不会失效
    private var loginItemURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/net.mrben.snapstrip.plist")
    }

    private func syncLoginItem() {
        let enabled = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? true
        let fm = FileManager.default
        if enabled {
            let plist: [String: Any] = [
                "Label": "net.mrben.snapstrip",
                "ProgramArguments": [Bundle.main.executablePath ?? ""],
                "RunAtLoad": true,
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? fm.createDirectory(at: loginItemURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                try? data.write(to: loginItemURL)
            }
        } else {
            try? fm.removeItem(at: loginItemURL)
        }
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let enabled = !(UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? true)
        UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
        sender.state = enabled ? .on : .off
        syncLoginItem()
    }

    private func buildPanel() {
        stripView = StripView(frame: NSRect(x: 0, y: 0, width: 480, height: StripGeom.hintHeight))
        panel = NSPanel(contentRect: stripView.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.contentView = stripView
        panel.level = .screenSaver                 // 压在普通窗口之上
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true            // 条只负责显示，鼠标事件全走全局监听
        panel.hidesOnDeactivate = false
    }

    private func installMonitors() {
        let masks: [NSEvent.EventTypeMask] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        for mask in masks {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
                self?.handle(event)
            }) {
                monitors.append(monitor)
            }
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: mouseDown()
        case .leftMouseDragged: mouseDragged()
        case .leftMouseUp: mouseUp()
        default: break
        }
    }

    // MARK: - 拖动状态机

    // 按下：命中某个窗口的标题栏区域（窗口顶部 40px）才记为「可能在拖这个窗口」
    private func mouseDown() {
        resetDrag()
        let point = NSEvent.mouseLocation
        guard let window = windowAt(point: point), isTitlebarArea(window, cocoaPoint: point) else { return }
        dragWindow = window
        startOrigin = axPoint(window, kAXPositionAttribute) ?? .zero
    }

    // 拖动中：窗口原点真的变了才亮出提示条；被拖窗口进入屏幕上三分之一就展开布局列；展开后跟踪悬停格
    private func mouseDragged() {
        guard let window = dragWindow else { return }
        if !stripVisible {
            guard let now = axPoint(window, kAXPositionAttribute), now != startOrigin else { return }
            showStrip()
        }
        updateHover()
    }

    // 放开：停在某格上就把窗口贴到那个布局；无论如何收条、清状态。
    // 贴靠延迟约 80ms 再执行——原应用自己的拖放收尾会把窗口放到落点，
    // 抢在它前面写位置会被它覆盖；写完再读回校验，没贴上就补写一次。
    private func mouseUp() {
        defer { resetDrag() }
        guard stripVisible else { return }
        updateHover()  // 先按放开瞬间的位置刷新一次展开/悬停状态，免得快速拖放漏判
        guard expanded, let window = dragWindow,
              let index = hoveredTile(),
              let target = targetFrame(Layout.all[index]) else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "未知应用"
        let layout = Layout.all[index]
        log("放开：\(appName) 布局\(index)（x\(layout.x) y\(layout.y) w\(layout.w) h\(layout.h)）"
            + " 目标 pos=\(NSStringFromPoint(target.pos)) size=\(NSStringFromSize(target.size))"
            + " 屏=\(NSStringFromRect(dragScreen?.frame ?? .zero))"
            + " 可见区=\(NSStringFromRect(dragScreen?.visibleFrame ?? .zero))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.assertFrame(target, of: window, attempt: 1)
        }
    }

    // 贴靠断言：写一次、隔一会儿读回核对，没贴稳就再写，最多五次（约 1.5 秒）。
    // 日志实测：写入都返回成功，但原应用结束拖放、系统多桌面退出等动作会在
    // 头一秒内把窗口挪回放手位置——单写一次会被顶掉，多断言几次直到贴稳为止
    private func assertFrame(_ target: AXFrame, of window: AXUIElement, attempt: Int) {
        let errors = setFrame(target, of: window)
        log("  第\(attempt)次写入 \(errors.map { $0.rawValue }) → 实际 pos=\(NSStringFromPoint(axPoint(window, kAXPositionAttribute) ?? .zero)) size=\(NSStringFromSize(axSize(window, kAXSizeAttribute) ?? .zero))")
        guard attempt < 5, !frameMatches(window, target: target) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.assertFrame(target, of: window, attempt: attempt + 1)
        }
    }

    private func resetDrag() {
        dragWindow = nil
        if stripVisible {
            stripVisible = false
            expanded = false
            stripView.expanded = false
            stripView.highlight = -1
            panel.orderOut(nil)
        }
    }

    // MARK: - 条的显示与悬停

    private func showStrip() {
        let point = NSEvent.mouseLocation
        dragScreen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        stripVisible = true
        expanded = false
        stripView.expanded = false
        placeStrip(expanded: false, animate: false)
        panel.orderFrontRegardless()
    }

    // 展开触发：被拖的窗口本体进入它所在屏幕的上三分之一区域（窗口矩形与
    // 上三分之一矩形相交即算），不用精确对准提示条；展开后不自动收起
    private func windowInTopThird(_ window: AXUIElement) -> Bool {
        guard let frame = dragScreen?.frame,
              let pos = axPoint(window, kAXPositionAttribute),
              let size = axSize(window, kAXSizeAttribute) else { return false }
        // 屏幕矩形换算到 AX 坐标（原点主屏左上）：x 不变，y 用主屏高翻转
        let screenAX = NSRect(x: frame.minX, y: mainScreenHeight - frame.maxY,
                              width: frame.width, height: frame.height)
        let topThird = NSRect(x: screenAX.minX, y: screenAX.minY,
                              width: screenAX.width, height: screenAX.height / 3)
        let windowRect = NSRect(x: pos.x, y: pos.y, width: size.width, height: size.height)
        return windowRect.intersects(topThird)
    }

    // 光标进入拖动所在屏幕的上三分之一（Cocoa 坐标：y 不小于 maxY 减去屏高三分之一）
    private func mouseInTopThird() -> Bool {
        guard let frame = dragScreen?.frame else { return false }
        let point = NSEvent.mouseLocation
        return frame.contains(point) && point.y >= frame.maxY - frame.height / 3
    }

    private func updateHover() {
        if !expanded {
            // 展开触发取其一：被拖窗口本体、或光标（拖到顶时光标先于窗口到位，
            // 且系统多桌面是在光标顶到边上停留后才触发，布局列会先展开）
            if let window = dragWindow, windowInTopThird(window) || mouseInTopThird() {
                expanded = true
                stripView.expanded = true
                placeStrip(expanded: true, animate: true)
            }
            return
        }
        let index = hoveredTile() ?? -1
        if index != stripView.highlight {
            stripView.highlight = index
            stripView.needsDisplay = true
        }
    }

    // 鼠标当前悬停的格子下标，不在条的范围里返回 nil。命中判定放宽：
    // 纵向从屏幕顶边到条下沿都算（拖到最顶时光标在格子上方的留白里，
    // 不能因此落空）；横向落在格子间隙时取最近的一格
    private func hoveredTile() -> Int? {
        let tiles = stripView.tileRects()
        guard let first = tiles.first, let last = tiles.last else { return nil }
        let point = NSEvent.mouseLocation
        let frame = panel.frame
        let local = NSPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        // 纵向上限按面板顶边到屏幕顶边的实际距离放宽（光标顶到屏幕边也算）
        let topAllowance = (dragScreen?.frame.maxY ?? frame.maxY) - frame.maxY + 4
        guard local.y >= 0, local.y <= frame.height + topAllowance else { return nil }
        if let index = tiles.firstIndex(where: { $0.contains(local) }) { return index }
        guard local.x >= first.minX - StripGeom.gap,
              local.x <= last.maxX + StripGeom.gap else { return nil }
        return tiles.indices.min { abs(tiles[$0].midX - local.x) < abs(tiles[$1].midX - local.x) }
    }

    // 条的落位：提示条宽为屏幕一半、高 50，挂在菜单栏下方；布局列更大，
    // 压到距顶 110px（刘海下方）。两者都水平居中于拖动所在屏幕
    private func placeStrip(expanded: Bool, animate: Bool) {
        guard let frame = dragScreen?.frame else { return }
        let rect: NSRect
        if expanded {
            let size = StripGeom.expandedSize
            rect = NSRect(x: frame.midX - size.width / 2,
                          y: frame.maxY - StripGeom.expandedTopGap - size.height,
                          width: size.width, height: size.height)
        } else {
            let width = frame.width / 2
            rect = NSRect(x: frame.midX - width / 2,
                          y: frame.maxY - StripGeom.hintTopGap - StripGeom.hintHeight,
                          width: width, height: StripGeom.hintHeight)
        }
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().setFrame(rect, display: true)
            }
        } else {
            panel.setFrame(rect, display: true)
        }
        stripView.needsDisplay = true
    }

    // MARK: - 窗口定位（AX：坐标原点在主屏左上，与 Cocoa 的左下原点要换算）

    private var mainScreenHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    // 屏幕坐标（Cocoa 点）处最上层元素所属的窗口；不是窗口就返回 nil
    // 诊断日志：写在 .app 同目录的 snapstrip.log，贴靠不对时靠它定位，不靠猜
    private func log(_ line: String) {
        let file = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("snapstrip.log")
        let text = line + "\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private func windowAt(point: NSPoint) -> AXUIElement? {
        let axPoint = CGPoint(x: point.x, y: mainScreenHeight - point.y)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                               Float(axPoint.x), Float(axPoint.y),
                                               &element) == .success,
              let element = element else { return nil }
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
              let windowRef = windowRef else { return nil }
        let window = windowRef as! AXUIElement
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef) == .success,
              (roleRef as? String) == (kAXWindowRole as String) else { return nil }
        // 不可移动的窗口不用另查：拖不动时原点不变，后面自然不会亮条
        return window
    }

    // 点是否落在窗口的标题栏拖动区：窗口左右范围内、距窗口顶边 40px 内
    private func isTitlebarArea(_ window: AXUIElement, cocoaPoint: NSPoint) -> Bool {
        guard let pos = axPoint(window, kAXPositionAttribute),
              let size = axSize(window, kAXSizeAttribute) else { return false }
        let axY = mainScreenHeight - cocoaPoint.y
        return cocoaPoint.x >= pos.x && cocoaPoint.x <= pos.x + size.width
            && axY >= pos.y && axY <= pos.y + 40
    }

    // 目标布局在 AX 坐标下的位置与尺寸：先按拖动所在屏幕的可用区
    // （visibleFrame）算 Cocoa 矩形，再换算成左上原点的 AX 坐标
    private struct AXFrame {
        let pos: CGPoint
        let size: CGSize
    }

    private func targetFrame(_ layout: Layout) -> AXFrame? {
        guard let visible = dragScreen?.visibleFrame else { return nil }
        let rect = NSRect(x: visible.minX + layout.x * visible.width,
                          y: visible.minY + layout.y * visible.height,
                          width: layout.w * visible.width,
                          height: layout.h * visible.height)
        return AXFrame(pos: CGPoint(x: rect.minX, y: mainScreenHeight - rect.maxY),
                       size: CGSize(width: rect.width, height: rect.height))
    }

    // 写窗口位置与尺寸：「位置 → 尺寸 → 位置 → 尺寸」——有些应用会吞掉移动后
    // 的第一次改尺寸，尺寸连写两遍才稳；位置同理防被尺寸约束顶回。
    // 返回四次写入的系统结果码（0=成功），供日志定位是谁没写进去
    private func setFrame(_ frame: AXFrame, of window: AXUIElement) -> [AXError] {
        [setAX(window, kAXPositionAttribute, point: frame.pos),
         setAX(window, kAXSizeAttribute, size: frame.size),
         setAX(window, kAXPositionAttribute, point: frame.pos),
         setAX(window, kAXSizeAttribute, size: frame.size)]
    }

    // 读回校验：窗口实际位置/尺寸与目标差在 12px 内算贴上了
    // （应用有最小尺寸限制时会差得多，补写一次即可，不必死磕）
    private func frameMatches(_ window: AXUIElement, target: AXFrame) -> Bool {
        guard let pos = axPoint(window, kAXPositionAttribute),
              let size = axSize(window, kAXSizeAttribute) else { return false }
        let tol: CGFloat = 12
        return abs(pos.x - target.pos.x) <= tol && abs(pos.y - target.pos.y) <= tol
            && abs(size.width - target.size.width) <= tol
            && abs(size.height - target.size.height) <= tol
    }

    private func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref = ref else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(ref as! AXValue, .cgPoint, &point)
        return point
    }

    private func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref = ref else { return nil }
        var size = CGSize.zero
        AXValueGetValue(ref as! AXValue, .cgSize, &size)
        return size
    }

    @discardableResult
    private func setAX(_ element: AXUIElement, _ attribute: String, point: CGPoint) -> AXError {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    @discardableResult
    private func setAX(_ element: AXUIElement, _ attribute: String, size: CGSize) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }
}

// 入口：单文件程序，顶层代码直接跑起应用
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
