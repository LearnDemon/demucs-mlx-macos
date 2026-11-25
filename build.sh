#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="音乐分轨"
EXECUTABLE="DemucsSeparator"
BUILD_DIR="$ROOT/.build"
APP_DIR="$HOME/Applications/$APP_NAME.app"

mkdir -p "$BUILD_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

echo "编译 Swift 界面…"
swiftc -O -swift-version 5 -parse-as-library \
    "$ROOT/Sources/AppMain.swift" \
    "$ROOT/Sources/MainViewController.swift" \
    "$ROOT/Sources/SeparationModel.swift" \
    -o "$BUILD_DIR/$EXECUTABLE" \
    -framework AppKit \
    -framework UniformTypeIdentifiers

cp "$BUILD_DIR/$EXECUTABLE" "$APP_DIR/Contents/MacOS/$EXECUTABLE"
cp "$ROOT/Resources/gui_backend.py" "$APP_DIR/Contents/Resources/gui_backend.py"
cp "$ROOT/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_DIR/Contents/MacOS/$EXECUTABLE"

# 本地构建的应用做一次 ad-hoc 签名，避免 Finder 启动时的校验问题。
xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "已生成：$APP_DIR"
echo "可以直接双击打开，或执行：open \"$APP_DIR\""
