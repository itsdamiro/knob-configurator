#!/bin/sh
# Builds Knob Agent.app as a universal app (Apple Silicon and Intel).
#   ./build.sh           build into build/
#   ./build.sh install   build, copy to ~/Applications and open it
#   ./build.sh dmg       build and package dist/KnobAgent-<version>.dmg
set -eu
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' agent/Info.plist)
APP="build/Knob Agent.app"
rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web" build/obj

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13" \
    agent/main.swift -o "build/obj/KnobAgent-$arch"
done
lipo -create build/obj/KnobAgent-arm64 build/obj/KnobAgent-x86_64 -output "$APP/Contents/MacOS/KnobAgent"
cp agent/Info.plist "$APP/Contents/Info.plist"
cp web/index.html web/presets.json "$APP/Contents/Resources/web/"
codesign --force --sign - "$APP"
echo "Built $APP ($VERSION)"

case "${1:-}" in
  install)
    DEST="$HOME/Applications/Knob Agent.app"
    mkdir -p "$HOME/Applications"
    pkill -x KnobAgent 2>/dev/null || true
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "Installed to $DEST"
    open "$DEST"
    ;;
  dmg)
    STAGE=build/dmg
    DMG="dist/KnobAgent-$VERSION.dmg"
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE" dist
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "Knob Agent $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "Packaged $DMG"
    shasum -a 256 "$DMG"
    ;;
esac
