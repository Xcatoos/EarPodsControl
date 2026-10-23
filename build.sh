#!/bin/zsh
# Builds "EarPods Control.app" (Apple Silicon + Intel), installs it to /Applications and opens it.
#   ./build.sh              build, install and open
#   ./build.sh --no-install only build (app and zip land in build/)
#   DEV=1 ./build.sh        keep Accessibility permission across rebuilds (for people hacking on the code)
set -e
cd "${0:a:h}"

command -v swiftc >/dev/null || { echo "Swift not found. Install Apple's Command Line Tools first:  xcode-select --install"; exit 1; }
[[ $(sw_vers -productVersion | cut -d. -f1) -ge 15 ]] || { echo "EarPods Control needs macOS 15 Sequoia or newer."; exit 1; }

APP="build/EarPods Control.app"
ID="app.earpodscontrol.EarPodsControl"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target $arch-apple-macos15 Sources/*.swift -o build/EarPodsControl-$arch 2>&1 | grep -E "error" || true
  [[ -f build/EarPodsControl-$arch ]] || { echo "Build failed ($arch)."; exit 1; }
done
lipo -create build/EarPodsControl-arm64 build/EarPodsControl-x86_64 -output "$APP/Contents/MacOS/EarPodsControl"
rm build/EarPodsControl-arm64 build/EarPodsControl-x86_64
cp Info.plist "$APP/Contents/"

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signing ties privacy permissions to this exact build. DEV=1 ties them to the bundle id instead,
# so frequent rebuilds keep Accessibility; don't ship DEV builds, since any app with this id would inherit it.
if [[ -n $DEV ]]; then
  codesign --force --sign - --requirements "=designated => identifier \"$ID\"" "$APP"
else
  codesign --force --sign - "$APP"
fi

"$APP/Contents/MacOS/EarPodsControl" --selftest
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "build/EarPods-Control.zip"
echo "Built $APP and build/EarPods-Control.zip"

[[ $1 == --no-install ]] && exit 0
pkill -x EarPodsControl || true
rm -rf "/Applications/EarPods Control.app" && cp -R "$APP" /Applications/
sleep 1 && open "/Applications/EarPods Control.app"
echo "Installed to /Applications and opened. Look for the EarPods icon in your menu bar."
