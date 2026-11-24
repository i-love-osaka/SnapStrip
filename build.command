#!/bin/bash
# 把 main.swift 编译成 SnapStrip.app（就在本目录里），只需系统自带的 Swift 编译器
cd "$(dirname "$0")"
set -e
swiftc -O -o SnapStrip-bin main.swift
rm -rf SnapStrip.app
mkdir -p SnapStrip.app/Contents/MacOS SnapStrip.app/Contents/Resources
mv SnapStrip-bin SnapStrip.app/Contents/MacOS/SnapStrip
cp Info.plist SnapStrip.app/Contents/Info.plist
iconutil -c icns AppIcon.iconset -o SnapStrip.app/Contents/Resources/SnapStrip.icns
# 有固定签名身份就用它签名：辅助功能授权按签名认人，身份不变，重编后授权保留；
# 没有就跳过（链接器自带临时签名，但每次重编都要删掉旧授权重新加）
if security find-identity -v -p codesigning 2>/dev/null | grep -q "SnapStrip Signing"; then
  codesign --force --sign "SnapStrip Signing" SnapStrip.app
  echo "已用固定身份签名（辅助功能授权可保留）"
fi
echo "已生成 SnapStrip.app，双击即可运行（首次运行会弹辅助功能授权）"
