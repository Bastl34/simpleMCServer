#!/bin/zsh
# Builds build/simpleMCServer.app.
#   ./build.sh            build only
#   ./build.sh install    build, copy to /Applications and launch
# Sign with your own certificate (then macOS keeps login item + notification permissions across rebuilds):
#   SIGN_ID="Apple Development: …" ./build.sh
# Version, bundle ID etc. live in Resources/Info.plist.
set -euo pipefail
cd "${0:A:h}"

APP=simpleMCServer
SIGN_ID=${SIGN_ID:--}

# only generate the icon if there isn't one yet (delete Resources/AppIcon.icns to redraw it)
if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "▸ Icon"
  ICONSET=build/AppIcon.iconset
  mkdir -p $ICONSET Resources
  swift Icon/MakeIcon.swift build/icon.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns $ICONSET -o Resources/AppIcon.icns
  sips -z 512 512 build/icon.png --out Icon/AppIcon.png >/dev/null # for the README
fi

echo "▸ Compiling"
CONTENTS=build/$APP.app/Contents
rm -rf build/$APP.app
mkdir -p $CONTENTS/MacOS $CONTENTS/Resources
swiftc -O -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macos14.4" \
  -o $CONTENTS/MacOS/$APP Sources/*.swift

echo "▸ Resources"
plutil -lint -s Resources/Info.plist Resources/*.lproj/*.strings # a typo in a .strings file silently breaks all translations
cp Resources/Info.plist $CONTENTS/
cp -R Resources/AppIcon.icns Resources/*.lproj $CONTENTS/Resources/

echo "▸ Signing ($SIGN_ID)"
codesign --force --sign "$SIGN_ID" build/$APP.app

echo "✓ build/$APP.app"

if [[ ${1:-} == install ]]; then
  if pgrep -qx $APP; then
    echo "$APP is still running – please quit it from the menu first (this also stops the Minecraft server)."
    exit 1
  fi
  rm -rf /Applications/$APP.app
  cp -R build/$APP.app /Applications/
  open /Applications/$APP.app
  echo "✓ installed and launched: /Applications/$APP.app"
fi
