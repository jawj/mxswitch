#!/bin/bash
#
# Builds mxswitch, wraps it in a minimal app bundle, and installs it as a
# LaunchAgent that runs at login and restarts if it dies.
#
# Usage:
#   ./build.sh          # defaults to input 16 (DisplayPort 2 / mDP)
#   ./build.sh 15       # on the other Mac: input 15 (DisplayPort 1)
#
# Re-running is safe: it rebuilds, then unloads and reloads the agent.
#
set -euo pipefail

ID="com.mackerron.mxswitch"
NAME="MXSwitch"
INPUT="${1:-16}"

APP="$HOME/Applications/$NAME.app"
PLIST="$HOME/Library/LaunchAgents/$ID.plist"
LOGDIR="$HOME/Library/Logs"
SRC="$(cd "$(dirname "$0")" && pwd)/mxswitch.m"

# ---------------------------------------------------------------- build

echo "Compiling $SRC ..."
clang -fobjc-arc -O2 -Wall -o "/tmp/$NAME.$$" "$SRC" \
    -framework Foundation \
    -framework IOKit \
    -framework CoreDisplay

# --------------------------------------------------------------- bundle

mkdir -p "$APP/Contents/MacOS" "$LOGDIR"
mv "/tmp/$NAME.$$" "$APP/Contents/MacOS/$NAME"
chmod +x "$APP/Contents/MacOS/$NAME"

cat > "$APP/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$ID</string>
    <key>CFBundleExecutable</key>
    <string>$NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
</dict>
</plist>
PLISTEOF

# Ad-hoc sign with a stable identifier, so macOS treats each rebuild as the
# same app. Without this, TCC grants and the Login Items entry are forgotten
# every time you recompile.
codesign --force --sign - --identifier "$ID" "$APP"

# ---------------------------------------------------------- launch agent

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$ID</string>

    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/$NAME</string>
        <string>$INPUT</string>
    </array>

    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Background</string>

    <key>StandardOutPath</key>
    <string>$LOGDIR/$NAME.log</string>
    <key>StandardErrorPath</key>
    <string>$LOGDIR/$NAME.err</string>
</dict>
</plist>
PLISTEOF

plutil -lint "$PLIST" >/dev/null

# ------------------------------------------------------------- (re)load

TARGET="gui/$(id -u)/$ID"

# bootout fails harmlessly if it was never loaded, hence the || true.
launchctl bootout "$TARGET" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

sleep 1
if launchctl print "$TARGET" >/dev/null 2>&1; then
    echo "Running: $TARGET (target input $INPUT)"
    echo "Log:     $LOGDIR/$NAME.log"
else
    echo "FAILED to bootstrap $TARGET — check $LOGDIR/$NAME.err" >&2
    exit 1
fi
