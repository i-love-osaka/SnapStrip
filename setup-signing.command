#!/bin/bash
# 一次性设置：给 SnapStrip 建一个固定的自签名身份。
# 背景：辅助功能授权是按「签名」认程序的；临时签名每次重编都变，系统就把
# 新版当成另一个程序——列表里旧条目还显示开着，其实对新版无效，必须删了重加。
# 用固定身份签名后，重编多少次都是「同一个人」，授权一次给好、长期有效。
set -e
cd /tmp
rm -f snapstrip-key.pem snapstrip-cert.pem snapstrip-cert.p12
/usr/bin/openssl req -x509 -newkey rsa:2048 -keyout snapstrip-key.pem -out snapstrip-cert.pem \
  -days 3650 -nodes -subj "/CN=SnapStrip Signing" 2>/dev/null
/usr/bin/openssl pkcs12 -export -out snapstrip-cert.p12 \
  -inkey snapstrip-key.pem -in snapstrip-cert.pem -passout pass:snapstrip
security import snapstrip-cert.p12 -k ~/Library/Keychains/login.keychain-db \
  -P snapstrip -T /usr/bin/codesign
rm -f snapstrip-key.pem snapstrip-cert.pem snapstrip-cert.p12
echo ""
echo "完成：固定签名身份「SnapStrip Signing」已建好。"
echo "接下来照常 bash build.command 重编一次，再去辅助功能里删掉旧的 SnapStrip、"
echo "把新的拖进去打开——这是最后一次，之后重编不用再弄。"
