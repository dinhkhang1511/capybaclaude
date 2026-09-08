#!/usr/bin/env bash
# Compile main.swift into ~/Applications/Dino.app and launch it.
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/Dino.app"

echo "▸ Building…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O main.swift -o "$APP/Contents/MacOS/Dino"

# Bundle sprite assets if provided next to main.swift.
# Capy skin: dino.png (idle) + dino-working.gif (working).
# MaoMao skin: maomao/*.gif → canonical names (idle / review→working / jumping→done).
for pair in "dino.png:dino.png" \
            "dino-working.gif:dino-working.gif" \
            "maomao/maomao-kusuriya-idle.gif:maomao-idle.gif" \
            "maomao/maomao-kusuriya-review.gif:maomao-review.gif" \
            "maomao/maomao-kusuriya-jumping.gif:maomao-jumping.gif" \
            "frieren/frieren-idle.gif:frieren-idle.gif" \
            "frieren/frieren-review.gif:frieren-review.gif" \
            "frieren/frieren-jumping.gif:frieren-jumping.gif" \
            "frieren/frieren-waiting.gif:frieren-waiting.gif" \
            "frieren/frieren-failed.gif:frieren-failed.gif"; do
  src="${pair%%:*}"; dst="${pair##*:}"
  if [ -f "$src" ]; then
    mkdir -p "$APP/Contents/Resources"
    cp "$src" "$APP/Contents/Resources/$dst"
    echo "▸ Bundled $dst."
  fi
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Dino</string>
  <key>CFBundleDisplayName</key>     <string>Dino</string>
  <key>CFBundleIdentifier</key>      <string>local.dino.overlay</string>
  <key>CFBundleExecutable</key>      <string>Dino</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>1.0</string>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
  <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS treats it as a stable app (needed for Login Items).
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# Restart any running instance.
pkill -x Dino 2>/dev/null || true
sleep 0.3
open "$APP"

echo "✓ Built $APP — look for 🦖 in the menu bar."
