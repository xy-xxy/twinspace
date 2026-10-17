# TwinSpace · macOS Beta

TwinSpace is a native macOS app duplicator built with SwiftUI. Select an application, create a separate copy, and manage both instances from one window.

Each application has one managed copy. Copies have a blue **2** badge on their icons and include the suffix `副本` (copy) in their names. See the [validation record](VALIDATION.md) for the scope of testing.

## Download

Get the latest published version, **v0.4.2 Beta**, from [Releases](https://github.com/xy-xxy/twinspace/releases).

- **TwinSpace-0.4.2-macos-universal.zip** — the macOS app, usage instructions, and validation record.
- **TwinSpace-0.4.2-source.zip** — source code, tests, and build scripts.
- **README.md** — this English guide.
- **VALIDATION.zh-CN.md** — validation details in Chinese.
- **SHA256SUMS.txt** — SHA-256 checksums for the release files.

Requires macOS 13 or later. The Universal binary includes Apple Silicon and Intel architectures. Interactive testing was performed on Apple Silicon with macOS 27.0.1; Intel hardware has not yet been verified. The app uses an ad-hoc local signature and is not notarized by Apple.

This version uses the TwinSpace name throughout the app and installer, and provides English release notes. Existing application entries, copy identities, and data locations are preserved. See the [changelog](CHANGELOG.md) for previous updates.

Development builds starting with **0.4.3** also produce `TwinSpace-X.Y.Z-macos-universal.dmg`. Open the DMG, drag `TwinSpace.app` onto the **Applications** shortcut, then eject the image and open the app from Applications. The current local build is `TwinSpace-0.4.3-macos-universal.dmg`; the published 0.4.2 release remains available as a ZIP.

## Installation and use

The app currently has a Chinese interface. Button labels below include English translations.

1. Download and extract `TwinSpace-0.4.2-macos-universal.zip`, then drag `TwinSpace.app` into Applications. When building from source, the app is available at `dist/TwinSpace.app`.
2. This is an **ad-hoc signed, unnotarized beta**. macOS may block the first launch of a downloaded copy. After checking its source, follow the system's instructions in **System Settings → Privacy & Security**. You do not need to disable Gatekeeper or SIP.
3. Click **Add App** (`添加应用…`) and select the original `.app`. You can select multiple apps. Selecting a new location for an existing bundle identifier updates its entry.
4. Click **Create and Open Copy** (`创建并打开副本`) and choose what to copy. **Application Only** (`仅复制应用程序`) is the default: it preserves an existing copy's data and starts with an empty data space when creating a copy for the first time. Allow space for the application plus approximately 512 MB; importing data also requires space for snapshots and backups.
5. Sign in separately inside the copied app if needed. TwinSpace observes startup for 20 seconds, but successful startup does not verify account login. It does not inspect account details, messages, or login credentials.
6. After updating the original app, select **Rebuild Copy** (`重建副本…`) and choose **Application Only** to update the program while preserving its data. Rebuilding also opens the copy. Its identity and data locations remain stable.

When upgrading from an earlier release, quit TwinSpace and remove the previous manager app from Applications before installing `TwinSpace.app`. Removing the manager bundle preserves your application list, managed copies, and their data.

TwinSpace manages at most one copy per application. Opening a running copy activates its existing window. Cancelling a build removes that build's temporary files; cancelling startup observation does not close the application.

## Copying existing data

Choose **Application and Existing Data** (`复制应用及现有数据`) during creation or rebuilding. Fully quit both the original and copied app, including background tasks, before starting. Closing a window alone may leave the application running. After import, the two sets of local data are stored separately.

Use the detected data location or select the original app's actual directory when a directory picker is available. Import covers local application data only. It does not clone external services, external files, cloud content, or the system keychain. Saved passwords, authorization details, and login sessions may require verification again.

If access to the original data is denied, the operation reports an error and preserves the existing copy. Leave enough disk space for both the source snapshot and the copy's previous data.

Before replacement, the previous program and data are backed up to:

```text
~/Library/Application Support/AppDual/DataBackups/<backup-id>/
```

Click **Data Backups** (`数据备份`) to open this location in Finder. Each backup's `manifest.json` maps its `old-N` snapshots to their original destinations. Quit the copied app before restoring a backup, and follow that mapping. Backups may contain private information or credentials; the backup directory is restricted to the current user.

Import uses snapshots before committing changes. If interrupted, TwinSpace restores the previous state before the next launch or rebuild and also preserves the state it finds during recovery. Opening the copied app directly in Finder bypasses this recovery check, so return to TwinSpace first after an interrupted import.

## Source integrity failures

Development builds starting with **0.4.3** add manual confirmation for source resource differences. The published 0.4.2 build stops on these failures without a continuation option.

A source integrity error means macOS detected added, changed, or missing resources compared with the original application's signature. The alert lists affected paths. **Copy Diagnostics** (`复制诊断`) includes the system's detailed output. Copying has not started at this stage.

You can reinstall a version with an intact signature from the original distribution channel, such as the Mac App Store or the developer's website, then retry. You do not need to delete account data. Do not remove the listed library files manually: other components may depend on them. Restoring source integrity does not, by itself, verify that the copied app will work correctly.

For reported added, changed, or missing resources, the confirmation dialog shows the application, source path, differences, and selected copy mode. Choose **Confirm and Continue Creating** (`确认后继续创建`) only if you understand and trust the installed application. Cancel leaves the existing copy in place. Confirmation applies to that attempt only; rebuilding requires a new confirmation if verification fails again. The selected data-copy mode and custom source directory are retained.

TwinSpace rechecks the source before continuing. A changed application version, location, or reported difference requires a fresh review. Only the source resource-integrity gate can be acknowledged: copying, signing, clone signature verification, isolation, and startup checks still apply. Tool failures and unsigned applications do not get this continuation option. Diagnostics record the manual acknowledgement without treating the original signature as valid.

## Compatibility

- macOS 13 or later, with an arm64 + x86_64 Universal binary. Intel hardware and older macOS releases still need interactive testing.
- TwinSpace selects an isolation strategy based on an app's runtime and storage mechanisms. Source resource-integrity failures stop creation unless explicitly acknowledged for that attempt in builds that support manual confirmation. Bundled resources must not link outside the application.
- Not every `.app` can run as an independent copy. Custom storage, single-instance restrictions, fixed local ports, vendor signature checks, and restricted entitlements can affect compatibility.
- Startup checks verify the launched location and process state, and check separate data locations where applicable. A visible window, running process, or existing directory does not prove that login or all application features work.
- Copies use local signatures. Keychain access, extensions, notifications, audio/video, and automatic updates may need separate testing. Update the original application first, then rebuild its copy.
- Running the packaged tool requires no developer tools. TwinSpace does not use binary patches, inject plugins, link resources to the original app, or disable system security settings. Release packages do not include third-party applications.

## File locations and removal

| Item | Location |
| --- | --- |
| Copied applications | Apps with the copy suffix under `~/Applications/` |
| Application list | `~/Library/Application Support/AppDual/apps.json` |
| Separate data and caches | Depends on the isolation strategy; identified by a stable copy identifier |
| Data backups | `~/Library/Application Support/AppDual/DataBackups/` |
| Separate temporary directories | Per-copy directories under `~/.twinspace-tmp/` |

**Delete Copy and Remove** (`删除副本并移除`) permanently deletes the copied `.app` and removes its list entry; it does not move the app to Trash. The original application, account data, and backups are retained. Re-adding the same original app and choosing **Application Only** recreates the same copy identity and reuses its data.

To uninstall manually, quit TwinSpace and the copied apps, then remove their `.app` bundles. **Account data is not deleted automatically.** Remove retained data or backups separately only after confirming that you no longer need them.

Builds use a temporary directory on the same filesystem. The application bundle is installed atomically after signature and entitlement checks. A failed build preserves the previous copy. An unexpected exit may leave `~/Applications/.appdual-stage-*` directories containing build files; remove them only when no build is running.

## Reporting issues

Open an [issue](https://github.com/xy-xxy/twinspace/issues) with reproduction steps and the output of **Copy Diagnostics**. Review diagnostics for private paths or other information before posting. Do not upload credentials, chat history, or database files.

## Building from source

Requires macOS and Swift 5.9 or later through Apple Command Line Tools or Xcode. There are no third-party package dependencies. End users do not need these development tools to run the packaged app.

```sh
./scripts/test.sh          # Core checks; works without XCTest
./scripts/build.sh         # Build both architectures, generate icons, sign, and package
open dist/TwinSpace.app
```

Build output includes the `.app`, a drag-to-install DMG, installer and source ZIPs, SHA-256 checksums, and documentation. The DMG includes an Applications shortcut and documentation. Packaging mounts it read-only to verify the app identity, version, signature, both architectures, and installation shortcut before replacing the output file. The scripts do not access an Apple developer account or perform notarization.

To repackage an existing build without recompiling, run `./scripts/package.sh`. DMG creation uses the macOS disk image tools and Python 3, with no additional packages.

The diagnostic CLI uses the same build engine as the GUI. Replace the example paths with the actual original and copied app locations:

```sh
swift run DualProbe inspect /Applications/Example.app
swift run DualProbe check-source /Applications/Example.app  # Read-only integrity check
swift run DualProbe build /Applications/Example.app
swift run DualProbe verify /Applications/Example.app
# Open both apps yourself, then observe them for 90 seconds.
swift run DualProbe observe /Applications/Example.app "$HOME/Applications/<copy-name>.app" 90
```

## Automatic releases

Pushing a `vX.Y.Z` tag triggers the [Release workflow](https://github.com/xy-xxy/twinspace/actions/workflows/release.yml), which tests, builds, verifies, and publishes the release. The tag must match the application version in `Resources/Info.plist`. Versions below `1.0.0` and tags with prerelease suffixes are marked as prereleases.

A manual workflow run verifies packaging without publishing. See the [release guide](docs/RELEASING.md) for version updates, tag formats, release notes, and retries. Use English Git commit messages and release notes. Release titles and fallback notes are generated in English.

## References

Application groups follow [Apple's entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups). Signing behavior is informed by [Apple Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html) and [code signing error documentation](https://developer.apple.com/documentation/security/errseccsbadresource). Source verification uses `codesign --verify --deep --strict --verbose=2`.
