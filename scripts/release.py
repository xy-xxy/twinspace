#!/usr/bin/env python3
"""Prepare, verify and publish tag releases using GitHub CLI and the standard library."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from urllib.parse import quote
import zipfile

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "xy-xxy/twinspace"
TAG = re.compile(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(alpha|beta|rc)\.([1-9]\d*))?")


def git_commit(root):
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()


def asset_names(version):
    return [f"TwinSpace-{version}-macos-universal.zip", f"TwinSpace-{version}-source.zip",
            "README.md", "VALIDATION.zh-CN.md", f"TwinSpace-{version}-macos-universal.dmg", "SHA256SUMS.txt"]


def prepare(root, tag, destination, commit):
    with (root / "Resources/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    version = info["CFBundleShortVersionString"]
    tag = tag or f"v{version}"
    match = TAG.fullmatch(tag)
    if not match or ".".join(match.groups()[:3]) != version:
        raise ValueError("Tag must match CFBundleShortVersionString (e.g. v0.4.2 or v0.4.2-beta.1).")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Invalid source commit.")
    prerelease = match[1] == "0" or match[4] is not None
    marker = f"<!-- TwinSpace source commit: {commit} -->"
    plan = {"tag": tag, "version": version, "build": info["CFBundleVersion"], "commit": commit,
            "prerelease": prerelease, "repository": REPOSITORY, "assets": asset_names(version), "marker": marker}
    candidates = [root / f"docs/releases/{tag}.md", root / f"docs/releases/v{version}.md"]
    notes_file = next((path for path in candidates if path.is_file()), None)
    if notes_file:
        notes = notes_file.read_text(encoding="utf-8").strip()
        if not notes:
            raise ValueError("Release notes must not be empty.")
    else:
        notes = f"""## TwinSpace {tag}

TwinSpace is a native macOS app duplicator. The Universal binary includes Apple Silicon
and Intel architectures and requires macOS 13 or later.

Open `TwinSpace-{version}-macos-universal.dmg` and drag `TwinSpace.app` onto the Applications
shortcut, then eject the disk image. A ZIP installer is also included. Quit the previous manager
before updating; remove its old bundle first if it used a different name.
Your application list, managed copies, and their data are preserved.
The app uses an ad-hoc local signature and is not notarized by Apple. Follow macOS
Privacy & Security instructions if the first launch is blocked after checking its source.

Assets include DMG and ZIP installers, source code, English README, Chinese validation record,
and SHA-256 checksums. The app interface remains Chinese.
See the [changelog](https://github.com/{REPOSITORY}/blob/{tag}/CHANGELOG.md) for changes
and the [validation record](https://github.com/{REPOSITORY}/blob/{tag}/VALIDATION.md)
for the tested scope. Intel hardware and complete account workflows are not fully verified.
"""
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "release-plan.json").write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
    (destination / "release-notes.md").write_text(notes.rstrip() + "\n\n" + marker + "\n", encoding="utf-8")
    return plan


def load_plan(directory, root):
    plan = json.loads((directory / "release-plan.json").read_text(encoding="utf-8"))
    match = TAG.fullmatch(plan["tag"])
    if (not match or ".".join(match.groups()[:3]) != plan["version"]
            or plan["repository"] != REPOSITORY or plan["assets"] != asset_names(plan["version"])
            or plan["commit"] != git_commit(root)
            or plan["prerelease"] != (match[1] == "0" or match[4] is not None)
            or plan["marker"] != f"<!-- TwinSpace source commit: {plan['commit']} -->"):
        raise ValueError("Release metadata does not match this checkout.")
    with (root / "Resources/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if plan["version"] != info["CFBundleShortVersionString"] or plan["build"] != info["CFBundleVersion"]:
        raise ValueError("Release metadata does not match the application version.")
    if plan["marker"] not in (directory / "release-notes.md").read_text(encoding="utf-8"):
        raise ValueError("Release notes are missing their source commit marker.")
    return plan


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(block)
    return "sha256:" + result.hexdigest()


def verify_assets(directory, plan):
    for name in plan["assets"]:
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"Missing or invalid release asset: {name}")
    checksums = {}
    for line in (directory / "SHA256SUMS.txt").read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match or match[2] in checksums:
            raise ValueError("Invalid or duplicate checksum entry.")
        checksums[match[2]] = "sha256:" + match[1]
    if set(checksums) != set(plan["assets"][:-1]):
        raise ValueError("Checksum manifest must cover exactly the downloadable files, including the DMG.")
    for name, expected in checksums.items():
        if digest(directory / name) != expected:
            raise ValueError(f"Checksum mismatch: {name}")
    for name in plan["assets"][:2]:
        with zipfile.ZipFile(directory / name) as archive:
            if archive.testzip():
                raise ValueError(f"Corrupt archive: {name}")
            if name.endswith("-macos-universal.zip"):
                plists = [p for p in archive.namelist() if p.endswith(".app/Contents/Info.plist")]
                if len(plists) != 1:
                    raise ValueError("Installer must contain one TwinSpace application.")
                info = plistlib.loads(archive.read(plists[0]))
                if (Path(plists[0]).parts[-3] != "TwinSpace.app"
                        or info.get("CFBundleName") != "TwinSpace"
                        or info.get("CFBundleDisplayName") != "TwinSpace"):
                    raise ValueError("Installer application must be named TwinSpace.")
                if (info.get("CFBundleIdentifier") != "io.local.appdual"
                        or info.get("CFBundleShortVersionString") != plan["version"]
                        or info.get("CFBundleVersion") != plan["build"]):
                    raise ValueError("Installer identity or version does not match the tag.")


class GitHub:
    def api(self, endpoint, method="GET", data=None, optional=False):
        args = ["gh", "api", endpoint, "--method", method]
        if data is not None:
            args += ["--input", "-"]
        result = subprocess.run(args, input=json.dumps(data) if data is not None else None,
                                capture_output=True, text=True)
        if result.returncode:
            if optional and "(HTTP 404)" in result.stderr:
                return None
            raise RuntimeError(f"GitHub API failed: {result.stderr.strip()}")
        return json.loads(result.stdout) if result.stdout.strip() else None

    def upload(self, tag, files):
        subprocess.run(["gh", "release", "upload", tag, "--repo", REPOSITORY, "--clobber"]
                       + [str(path) for path in files], check=True)


def verify_remote_tag(github, plan):
    obj = github.api(f"repos/{REPOSITORY}/git/ref/tags/{quote(plan['tag'], safe='')}")["object"]
    for _ in range(8):
        if obj["type"] == "commit":
            if obj["sha"] != plan["commit"]:
                raise ValueError("Remote tag moved after this build; refusing to publish.")
            return
        if obj["type"] != "tag":
            break
        obj = github.api(f"repos/{REPOSITORY}/git/tags/{obj['sha']}")["object"]
    raise ValueError("Cannot resolve the remote version tag to a commit.")


def verify_remote_assets(release, plan, directory=None):
    assets = release.get("assets", [])
    if len(assets) != len(plan["assets"]) or {asset["name"] for asset in assets} != set(plan["assets"]):
        raise ValueError("Release does not contain exactly the expected assets.")
    for asset in assets:
        if asset["state"] != "uploaded" or asset["size"] <= 0 or not asset.get("digest", "").startswith("sha256:"):
            raise ValueError("Release asset upload is incomplete.")
        if directory and (asset["size"] != (directory / asset["name"]).stat().st_size
                          or asset["digest"] != digest(directory / asset["name"])):
            raise ValueError(f"Uploaded asset does not match the build: {asset['name']}")


def publish(github, plan, directory):
    verify_assets(directory, plan)
    verify_remote_tag(github, plan)
    endpoint = f"repos/{REPOSITORY}/releases"
    existing = github.api(f"{endpoint}/tags/{plan['tag']}", optional=True)
    # GitHub may not resolve an unpublished draft through the tag endpoint.
    if existing is None:
        for page in range(1, 101):
            releases = github.api(f"{endpoint}?per_page=100&page={page}")
            existing = next((r for r in releases if r["tag_name"] == plan["tag"]), None)
            if existing or len(releases) < 100:
                break
        else:
            raise ValueError("Unable to finish checking existing releases.")
    if existing:
        if (plan["marker"] not in (existing.get("body") or "")
                or existing["target_commitish"] != plan["commit"]
                or existing["prerelease"] != plan["prerelease"]):
            raise ValueError("This release belongs to another commit or was created manually; it will not be overwritten.")
        if not existing["draft"]:
            verify_remote_assets(existing, plan)
            print(f"Release already published; leaving its assets unchanged: {existing['html_url']}")
            return
    else:
        suffix = " Beta" if plan["prerelease"] else ""
        existing = github.api(endpoint, "POST", {
            "tag_name": plan["tag"], "target_commitish": plan["commit"],
            "name": f"TwinSpace {plan['tag']}{suffix}",
            "body": (directory / "release-notes.md").read_text(encoding="utf-8"),
            "draft": True, "prerelease": plan["prerelease"]})
    github.upload(plan["tag"], [directory / name for name in plan["assets"]])
    endpoint += f"/{existing['id']}"
    uploaded = github.api(endpoint)
    if not uploaded["draft"]:
        raise ValueError("Release state changed while uploading; refusing to modify it.")
    verify_remote_assets(uploaded, plan, directory)
    verify_remote_tag(github, plan)
    result = github.api(endpoint, "PATCH", {"draft": False, "prerelease": plan["prerelease"],
                                          "make_latest": "false" if plan["prerelease"] else "legacy"})
    if result["draft"]:
        raise ValueError("GitHub did not confirm publication.")
    print(f"Published {result['html_url']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "verify", "publish"])
    parser.add_argument("--tag", default="")
    parser.add_argument("--directory", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    if args.command == "prepare":
        plan = prepare(ROOT, args.tag, args.directory, git_commit(ROOT))
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
                output.write(f"tag={plan['tag']}\nversion={plan['version']}\n")
        print(f"Prepared {plan['tag']} at {plan['commit']}")
    else:
        plan = load_plan(args.directory, ROOT)
        if args.command == "publish":
            if (os.environ.get("GITHUB_EVENT_NAME") != "push"
                    or os.environ.get("GITHUB_REF") != "refs/tags/" + plan["tag"]
                    or os.environ.get("GITHUB_REPOSITORY") != REPOSITORY):
                raise ValueError("Publishing is allowed only for version-tag pushes to xy-xxy/twinspace.")
            publish(GitHub(), plan, args.directory)
        else:
            verify_assets(args.directory, plan)
            print("Release archives and all checksums verified.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, KeyError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        print(f"Release failed: {error}", file=sys.stderr)
        sys.exit(1)
