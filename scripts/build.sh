#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
mkdir -p dist .build
# Keep generated staging inside the ignored build directory for recovery.
TASK_STAGE="$(mktemp -d "$TASK_ROOT/.build/package.XXXXXX")"

# Build both slices independently, then combine. No third-party dependencies.
for TASK_ARCH in arm64 x86_64; do
    swift build -c release --arch "$TASK_ARCH" --product AppDual
    TASK_BIN_DIR="$(swift build -c release --arch "$TASK_ARCH" --show-bin-path)"
    cp "$TASK_BIN_DIR/AppDual" "$TASK_STAGE/AppDual-$TASK_ARCH"
done
swift build -c release --product DualProbe
TASK_BIN_DIR="$(swift build -c release --show-bin-path)"
TASK_APP="$TASK_STAGE/双栖.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
/usr/bin/lipo -create "$TASK_STAGE/AppDual-arm64" "$TASK_STAGE/AppDual-x86_64" -output "$TASK_APP/Contents/MacOS/AppDual"
cp Resources/Info.plist "$TASK_APP/Contents/Info.plist"
"$TASK_BIN_DIR/DualProbe" --make-icon "$TASK_APP/Contents/Resources/AppDual.icns"
/usr/bin/codesign --force --sign - --timestamp=none "$TASK_APP"
/usr/bin/codesign --verify --deep --strict "$TASK_APP"
for TASK_ARCH in arm64 x86_64; do
    /usr/bin/lipo -verify_arch "$TASK_ARCH" "$TASK_APP/Contents/MacOS/AppDual"
done

# Only generated deliverables inside this project's dist directory are replaced.
if [ -d dist/双栖.app ]; then
    mv dist/双栖.app "$TASK_STAGE/previous-bundle"
fi
mv "$TASK_APP" dist/双栖.app
"$TASK_ROOT/scripts/package.sh"
printf '\n已生成：%s/dist/双栖.app\n' "$TASK_ROOT"
