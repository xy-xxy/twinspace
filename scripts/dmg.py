#!/usr/bin/env python3
"""Create and verify a drag-to-install TwinSpace disk image using macOS tools."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, timeout=180, **kwargs)


def app_info(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if (info.get('CFBundleIdentifier') != 'io.local.appdual'
            or info.get('CFBundleName') != 'TwinSpace'
            or info.get('CFBundleDisplayName') != 'TwinSpace'
            or info.get('CFBundleExecutable') != 'AppDual'):
        raise ValueError('The disk image must contain the TwinSpace application.')
    return info


def verify(image, app):
    expected = app_info(app)
    run('/usr/bin/hdiutil', 'verify', '-quiet', image)
    work = Path(tempfile.mkdtemp(prefix='dmg-check-', dir=ROOT / '.build'))
    mount = work / 'volume'
    mount.mkdir()
    attached = False
    try:
        run('/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen',
            '-mountpoint', mount, '-quiet', image)
        attached = True
        installed = mount / 'TwinSpace.app'
        if installed.is_symlink() or app_info(installed) != expected:
            raise ValueError('The mounted app does not match the packaged version.')
        shortcut = mount / 'Applications'
        if not shortcut.is_symlink() or shortcut.readlink() != Path('/Applications'):
            raise ValueError('The Applications shortcut is missing or incorrect.')
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', installed)
        binary = installed / 'Contents/MacOS/AppDual'
        for arch in ('arm64', 'x86_64'):
            run('/usr/bin/lipo', binary, '-verify_arch', arch)
        if hashlib.sha256(binary.read_bytes()).digest() != hashlib.sha256((app / 'Contents/MacOS/AppDual').read_bytes()).digest():
            raise ValueError('The mounted executable differs from the verified build.')
        for name in ('README.md', 'VALIDATION.md', 'CHANGELOG.md'):
            if (mount / 'Documentation' / name).read_bytes() != (ROOT / name).read_bytes():
                raise ValueError(f'Disk image documentation is out of date: {name}')
    finally:
        # Leave the mount and staging directory available if ejection fails.
        # Never remove files recursively while the image may still be mounted.
        if attached or os.path.ismount(mount):
            run('/usr/bin/hdiutil', 'detach', '-quiet', mount)
        if not os.path.ismount(mount):
            shutil.rmtree(work)
    print(f'Verified disk image, application signature, architectures, and installation shortcut: {image}')


def create(image, app):
    info = app_info(app)
    source_info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    if info != source_info:
        raise ValueError('Build the current application version before creating its disk image.')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    work = Path(tempfile.mkdtemp(prefix='dmg-build-', dir=ROOT / '.build'))
    payload = work / 'payload'
    payload.mkdir()
    run('/usr/bin/ditto', '--norsrc', '--noextattr', app, payload / 'TwinSpace.app')
    (payload / 'Applications').symlink_to('/Applications', target_is_directory=True)
    docs = payload / 'Documentation'
    docs.mkdir()
    for name in ('README.md', 'VALIDATION.md', 'CHANGELOG.md'):
        shutil.copyfile(ROOT / name, docs / name)
    (docs / 'docs').mkdir()
    shutil.copyfile(ROOT / 'docs/RELEASING.md', docs / 'docs/RELEASING.md')
    (payload / 'Read Me.txt').write_text(
        f"TwinSpace {info['CFBundleShortVersionString']}\n\n"
        "1. Quit any running version of TwinSpace.\n"
        "2. Drag TwinSpace.app onto Applications to install or update it.\n"
        "3. Eject this disk image, then open TwinSpace from Applications.\n\n"
        "Updating the manager preserves your application list, managed copies, and their data.\n"
        "Requires macOS 13 or later. Includes Apple Silicon and Intel architectures.\n"
        "The app is locally signed and is not notarized by Apple.\n"
        "See Documentation/README.md for first-launch instructions and tested scope.\n",
        encoding='utf-8')
    staged = work / 'TwinSpace.dmg'
    # HFS+ and UDZO keep the image readable on every supported macOS version.
    run('/usr/bin/hdiutil', 'create', '-srcfolder', payload, '-volname', 'TwinSpace',
        '-fs', 'HFS+', '-format', 'UDZO', '-quiet', staged)
    verify(staged, app)
    image.parent.mkdir(parents=True, exist_ok=True)
    if image.is_symlink():
        raise ValueError('Refusing to replace a symbolic link at the output path.')
    os.replace(staged, image)
    print(f'Created {image}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['create', 'verify'])
    parser.add_argument('--app', type=Path, default=ROOT / 'dist/TwinSpace.app')
    parser.add_argument('--image', type=Path, required=True)
    args = parser.parse_args()
    (ROOT / '.build').mkdir(exist_ok=True)
    if args.image.suffix.lower() != '.dmg':
        parser.error('--image must end in .dmg')
    (create if args.command == 'create' else verify)(args.image.absolute(), args.app.resolve(strict=True))
