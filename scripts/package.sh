#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
TASK_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
[[ "$TASK_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid release version' >&2; exit 1; }
TASK_APP="dist/双栖.app"
TASK_APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TASK_APP/Contents/Info.plist")"
[[ "$TASK_APP_VERSION" == "$TASK_VERSION" ]] || { echo 'Build the current version before packaging' >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$TASK_APP"
for TASK_ARCH in arm64 x86_64; do
    /usr/bin/lipo -verify_arch "$TASK_ARCH" "$TASK_APP/Contents/MacOS/AppDual"
done

mkdir -p .build
TASK_STAGE="$(mktemp -d "$TASK_ROOT/.build/release.XXXXXX")"
TASK_RELEASE="$TASK_STAGE/双栖测试版"
mkdir -p "$TASK_RELEASE"
/usr/bin/ditto --norsrc --noextattr "$TASK_APP" "$TASK_RELEASE/双栖.app"
cp README.md "$TASK_RELEASE/使用说明.md"
cp VALIDATION.md "$TASK_RELEASE/验证记录.md"
cp CHANGELOG.md "$TASK_RELEASE/更新日志.md"
TASK_BINARY="TwinSpace-$TASK_VERSION-macos-universal.zip"
TASK_SOURCE_ARCHIVE="TwinSpace-$TASK_VERSION-source.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$TASK_RELEASE" "dist/$TASK_BINARY"

# Package only project sources and public documentation, never local build/test data.
TASK_SOURCE="$TASK_STAGE/TwinSpace-$TASK_VERSION-source"
mkdir -p "$TASK_SOURCE"
/usr/bin/tar --exclude='.DS_Store' -cf - Package.swift README.md VALIDATION.md CHANGELOG.md .gitignore Sources Tests Resources scripts docs .github |
    /usr/bin/tar -xf - -C "$TASK_SOURCE"
/usr/bin/ditto -c -k --keepParent "$TASK_SOURCE" "dist/$TASK_SOURCE_ARCHIVE"
cp README.md dist/README.zh-CN.md
cp VALIDATION.md dist/VALIDATION.zh-CN.md
cp README.md dist/使用说明.md
cp VALIDATION.md dist/验证记录.md
(
    cd dist
    /usr/bin/shasum -a 256 "$TASK_BINARY" "$TASK_SOURCE_ARCHIVE" README.zh-CN.md VALIDATION.zh-CN.md > SHA256SUMS.txt
)
printf '\nRelease assets: %s/dist/%s\n' "$TASK_ROOT" "$TASK_BINARY"
