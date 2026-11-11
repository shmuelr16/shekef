#!/bin/bash
# בונה את שקף.app. עם הפרמטר install: מתקין ב-/Applications.
set -e
cd "$(dirname "$0")"
# בנייה אוניברסלית: Intel + Apple Silicon
swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -E "error|Build complete|Build succeeded" | tail -40
BIN=".build/apple/Products/Release/Shekef"
[ -f "$BIN" ] || { echo "build failed"; exit 1; }
APP="build/שקף.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web" "$APP/Contents/Resources/sounds" "$APP/Contents/Resources/he.lproj"
cp "$BIN" "$APP/Contents/MacOS/Shekef"
cp Info.plist "$APP/Contents/Info.plist"
cp Web/* "$APP/Contents/Resources/web/"
cp Sounds/*.wav "$APP/Contents/Resources/sounds/"
printf '"CFBundleName" = "שקף";\n"CFBundleDisplayName" = "שקף";\n' > "$APP/Contents/Resources/he.lproj/InfoPlist.strings"
if [ ! -f AppIcon.icns ]; then
  swift icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o AppIcon.icns
fi
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP" 2>/dev/null
echo "built: $APP"
if [ "$1" = "install" ]; then
  osascript -e 'tell application id "il.shmuel.shekef" to quit' 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/שקף.app"
  cp -R "$APP" "/Applications/שקף.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/שקף.app"
  echo "installed: /Applications/שקף.app"
fi
