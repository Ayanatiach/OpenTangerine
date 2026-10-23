#!/usr/bin/env bash
#
# package_app.sh — Builds OpenTangerine with SwiftPM and wraps it into a macOS .app bundle.
#
# Usage:  ./scripts/package_app.sh [--native]
#   --native   Build only for the host architecture (default: universal arm64 + x86_64)
#
# Output: dist/OpenTangerine.app  and  dist/OpenTangerine-<version>-macOS.zip
#
set -euo pipefail

APP_NAME="OpenTangerine"
BUNDLE_ID="com.ayanatiach.OpenTangerine"
VERSION="1.1.0"
BUILD_NUMBER="1"
MIN_MACOS="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ICON_SRC="$ROOT_DIR/Assets/AppIcon.png"

cd "$ROOT_DIR"

# ---------------------------------------------------------------------------
# 1. Compile release binary
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--native" ]]; then
    echo "==> Building $APP_NAME (release, native arch)…"
    swift build -c release
    BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
else
    echo "==> Building $APP_NAME (release, universal arm64 + x86_64)…"
    swift build -c release --arch arm64 --arch x86_64
    BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"
fi
[[ -x "$BIN_PATH" ]] || { echo "error: binary not found at $BIN_PATH" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 2. Assemble bundle skeleton
# ---------------------------------------------------------------------------
echo "==> Assembling $APP_NAME.app…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# Bundle opencore-amr if available for standalone AMR encoding
if [[ -f "/opt/homebrew/lib/libopencore-amrnb.0.dylib" ]]; then
    cp "/opt/homebrew/lib/libopencore-amrnb.0.dylib" "$APP_DIR/Contents/Frameworks/libopencore-amrnb.dylib"
elif [[ -f "/usr/local/lib/libopencore-amrnb.0.dylib" ]]; then
    cp "/usr/local/lib/libopencore-amrnb.0.dylib" "$APP_DIR/Contents/Frameworks/libopencore-amrnb.dylib"
fi

# ---------------------------------------------------------------------------
# 3. App icon (.icns generated from Assets/AppIcon.png)
# ---------------------------------------------------------------------------
if [[ -f "$ICON_SRC" ]]; then
    echo "==> Generating AppIcon.icns…"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size           "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png"    >/dev/null
        sips -z $((size*2)) $((size*2)) "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
fi

# ---------------------------------------------------------------------------
# 4. Info.plist
#    LSUIElement = true -> menu-bar-only app (no Dock icon), matching the
#    MenuBarExtra-based UI in OpenTangerine.swift.
# ---------------------------------------------------------------------------
cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>     <string>en</string>
    <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleName</key>                  <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>           <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>        <string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.utilities</string>
    <key>LSUIElement</key>                   <true/>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
    <key>NSHumanReadableCopyright</key>      <string>Copyright © 2026 Ayanatiach. MIT License.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

# ---------------------------------------------------------------------------
# 5. Ad-hoc code signature (required for Apple Silicon; no Developer ID needed)
# ---------------------------------------------------------------------------
echo "==> Code signing (ad-hoc)…"
codesign --force --deep --options runtime --timestamp=none --sign - "$APP_DIR"
codesign --verify --strict --verbose=1 "$APP_DIR"

# ---------------------------------------------------------------------------
# 6. Distributable zip (ditto preserves bundle metadata & signature)
# ---------------------------------------------------------------------------
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION-macOS.zip"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

echo ""
echo "✅ Done"
echo "   App: $APP_DIR"
echo "   Zip: $ZIP_PATH"
lipo -info "$APP_DIR/Contents/MacOS/$APP_NAME"
