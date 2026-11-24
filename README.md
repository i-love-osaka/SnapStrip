# SnapStrip

**Drag a window up, pick a layout, let go — snapped.**

A tiny macOS window-tiling utility in the spirit of the Windows 11
snap bar. (Windows has this built in, so this is Mac-only.) Drag any
window and a hint bar appears at the top of the screen; keep dragging
into the top third and it expands into seven layouts — left half,
right half, four corners, maximize — placed safely below the notch.
Drop the window on a layout and it moves and resizes to fit.

- **Seven layouts:** left / right half, four quarter corners, maximize.
- **Two-stage bar:** a slim hint bar, half the screen wide, appears as
  soon as a window starts moving; the full layout strip appears when
  the window or the cursor reaches the top third of the screen.
- Lives in the menu bar — reopen the About window, toggle launch at
  login, or quit from there. No Dock icon, no settings window.
- Launch at login is on by default, via a LaunchAgent in
  `~/Library/LaunchAgents` that you can delete at any time.
- One Swift file, AppKit + Accessibility only, no dependencies.

Moving other apps' windows needs the Accessibility permission:
System Settings → Privacy & Security → Accessibility, tick SnapStrip.

Built with Swift + AppKit.

## Build

You need the Swift compiler from Xcode or the Command Line Tools.

```sh
bash build.command
```

This produces `SnapStrip.app` next to the sources. Double-click it,
click “开始使用” (Start Using) in the About window, and it stays
resident in the menu bar.

One tip if you rebuild often: the Accessibility grant follows the
app's code signature, and an ad-hoc signature changes on every build —
the grant then silently stops applying to the new build even though
the toggle in Settings still shows on. Run
`bash setup-signing.command` once to create a fixed self-signed
identity; `build.command` signs with it automatically and the grant
survives rebuilds.

## License

MIT © Ben Zhang
