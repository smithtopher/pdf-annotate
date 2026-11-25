#!/bin/bash
# Builds a universal (Apple silicon + Intel) "PDF Annotate.app" into ./build,
# plus a zip of it ready to attach to a GitHub release.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0.0"
BUILD_NUMBER="1"

for arch in arm64 x86_64; do
  swift build -c release --triple "$arch-apple-macosx13.0"
done
mkdir -p build
BIN="build/PDFAnnotate-universal"
lipo -create \
  .build/arm64-apple-macosx/release/PDFAnnotate \
  .build/x86_64-apple-macosx/release/PDFAnnotate \
  -output "$BIN"

APP="build/PDF Annotate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BIN" "$APP/Contents/MacOS/PDFAnnotate"

# App icon: icon.png (square, ideally 1024px+) -> AppIcon.icns
if [ -f icon.png ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$ICONSET")"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PDF Annotate</string>
  <key>CFBundleDisplayName</key><string>PDF Annotate</string>
  <key>CFBundleIdentifier</key><string>local.pdfannotate</string>
  <key>CFBundleExecutable</key><string>PDFAnnotate</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PDF Document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1
# Nudge Finder/Dock to pick up a changed icon.
touch "$APP"
ZIP="build/PDF-Annotate-$VERSION-macOS-universal.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Built: $PWD/$APP ($(lipo -archs "$APP/Contents/MacOS/PDFAnnotate"))"
echo "Zip:   $PWD/$ZIP"
