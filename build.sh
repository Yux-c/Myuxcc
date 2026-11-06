#!/bin/zsh
# Builds Myuxcc.app (release, arm64) into ./build, signs it and installs a copy in /Applications.
# Pass --no-install to only build.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/Myuxcc.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Myuxcc "$APP/Contents/MacOS/Myuxcc"
cp Info.plist "$APP/Contents/Info.plist"
# Regenerate with Icon/make_icns.sh after changing Icon/make_icon.swift.
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Signing with a stable certificate keeps the Screen Recording grant across rebuilds;
# ad-hoc signatures are pinned to the binary hash, so every rebuild would need a new grant.
# The certificate kept its name from when the app was called ScshootDemo.
IDENTITY="ScshootDemo Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    codesign --force --sign "$IDENTITY" --identifier com.yuxccu.myuxcc "$APP"
else
    echo "warning: '$IDENTITY' not found, falling back to ad-hoc signing" >&2
    codesign --force --sign - --identifier com.yuxccu.myuxcc "$APP"
fi
echo "Built $APP"

# The system's app list only shows apps in /Applications. The copy keeps the same bundle ID and
# signature, so permission grants carry over; a running instance keeps running until relaunched.
if [[ "${1:-}" != "--no-install" ]]; then
    INSTALLED=/Applications/Myuxcc.app
    # Update /Applications/Myuxcc.app in-place instead of `rm -rf "$INSTALLED"` so macOS TCC
    # (Screen Recording permission) and Login Items keep the existing bundle directory inode across builds,
    # and automatically restart the running instance if one was active.
    WAS_RUNNING=0
    if pgrep -x Myuxcc >/dev/null 2>&1; then
        WAS_RUNNING=1
        killall Myuxcc 2>/dev/null || true
        sleep 0.2
    fi
    rm -rf "$INSTALLED/Contents/_CodeSignature"
    ditto "$APP" "$INSTALLED"
    # Register the installed copy and forget the build copy, so Spotlight and "Open With" offer one Myuxcc.
    LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    "$LSREGISTER" -f "$INSTALLED"
    "$LSREGISTER" -u "$APP" || true
    echo "Installed $INSTALLED"
    if [[ "$WAS_RUNNING" -eq 1 ]]; then
        open "$INSTALLED"
        echo "Restarted $INSTALLED"
    fi
fi
