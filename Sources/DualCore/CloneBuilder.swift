import Foundation
import Darwin

public enum EntitlementPolicy {
    public static func main(_ original: [String: Any], source: AppDescriptor) -> [String: Any] {
        var result = original
        let oldIdentifier = original["com.apple.application-identifier"] as? String ?? ""
        let declaredTeam = oldIdentifier.hasSuffix("." + source.bundleID)
            ? String(oldIdentifier.dropLast(source.bundleID.count + 1)) : ""
        let team = declaredTeam.isEmpty ? (source.electronTeamID ?? "") : declaredTeam
        let appIdentifier = team.isEmpty ? source.cloneID : team + "." + source.cloneID
        result["com.apple.application-identifier"] = appIdentifier
        // Preserve existing clone data-group identities when repairing missing Electron IPC permissions.
        let dataGroupNamespace = declaredTeam.isEmpty ? source.cloneID : declaredTeam + "." + source.cloneID
        if let groups = original["com.apple.security.application-groups"] as? [String] {
            result["com.apple.security.application-groups"] = groups.map { group in
                group.contains(source.bundleID) ? group.replacingOccurrences(of: source.bundleID, with: source.cloneID)
                    : dataGroupNamespace + ".group." + digest(group).prefix(10)
            }
        }
        if source.electronTeamID != nil {
            var groups = result["com.apple.security.application-groups"] as? [String] ?? []
            if !groups.contains(where: { appIdentifier == $0 || appIdentifier.hasPrefix($0 + ".") }) {
                groups.append(appIdentifier)
            }
            result["com.apple.security.application-groups"] = groups
        }
        for key in Array(result.keys) where key.hasPrefix("com.apple.developer.") || key == "keychain-access-groups" || key == "application-identifier" {
            result.removeValue(forKey: key)
        }
        return result
    }
}

/// Atomic exchange keeps the previous bundle available even if the process is interrupted.
public enum AtomicInstaller {
    public static func install(staged: URL, destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            let status = staged.path.withCString { a in
                destination.path.withCString { b in renameatx_np(AT_FDCWD, a, AT_FDCWD, b, UInt32(RENAME_SWAP)) }
            }
            guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
    }
}

public struct CloneBuilder {
    private let commands: CommandRunning
    public init(commands: CommandRunning = SystemCommands()) { self.commands = commands }

    public func entitlements(at url: URL, bundleVersion: String? = nil) throws -> [String: Any] {
        let options = bundleVersion.map { ["--bundle-version", $0] } ?? []
        let output = try commands.checked("/usr/bin/codesign", ["-d", "--entitlements", ":-"] + options + [url.path])
        guard let start = output.range(of: "<?xml"), let end = output.range(of: "</plist>") else { return [:] }
        let xml = String(output[start.lowerBound..<end.upperBound])
        return try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any] ?? [:]
    }

    public func verify(_ url: URL) throws {
        try commands.checked("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path])
    }

    public func build(source: AppDescriptor, destination: URL,
                      dataPolicy: DataCopyPolicy = .applicationOnly, dbxSourceDirectory: URL? = nil, browserSourceDirectory: URL? = nil,
                      electronSourceDirectory: URL? = nil,
                      sourceSignatureApproval: SourceSignatureApproval? = nil,
                      dataHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                      isRunning: @escaping (URL) -> Bool = { _ in false },
                      progress: (Double, String) -> Void = { _, _ in }) throws -> CloneManifest {
        let fm = FileManager.default
        guard !isRunning(destination) else { throw DualError.message("请先从副本的菜单退出应用，再修复或重建；不会强制结束它。") }
        if dataPolicy == .includeExistingData && isRunning(source.url) {
            throw DualError.message("复制现有数据前，请从菜单完全退出原版和副本（包括后台任务），然后再试。")
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockPath = destination.deletingLastPathComponent().appendingPathComponent(".appdual-build.lock")
        let fd = open(lockPath.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DualError.message("无法写入副本目录，请检查文件夹权限。") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw DualError.message("另一个窗口正在构建副本，请稍后再试。") }
        try DataCopyTransaction.recoverIfNeeded(source: source, appDestination: destination, home: dataHome, isRunning: isRunning, acquireLock: false)
        try validateDestination(destination, source: source)
        progress(0.02, "检查原版应用完整性")
        try SourceSignature.verify(source, approval: sourceSignatureApproval, commands: commands)
        let originalEntitlements = try entitlements(at: source.url)
        let mode = try Compatibility.mode(for: source, entitlements: originalEntitlements)
        if mode == .chromiumProfile { try ChromiumProfile.ensureDirectory(for: source, home: dataHome) }
        let electronConfiguration = mode == .electronProfile ? try ElectronLaunchConfiguration(source: source, home: dataHome) : nil
        if let electronConfiguration { try electronConfiguration.prepareDirectories(includeTemporary: true) }
        let inventory = try inspectTree(source.url)
        let available = (try fm.attributesOfFileSystem(forPath: destination.deletingLastPathComponent().path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard available > inventory.bytes + 512 * 1024 * 1024 else {
            throw DualError.message("磁盘空间不足。需要约 \(ByteCountFormatter.string(fromByteCount: inventory.bytes + 512 * 1024 * 1024, countStyle: .file)) 可用空间。")
        }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".appdual-stage-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let app = stage.appendingPathComponent(destination.lastPathComponent)
        progress(0.08, "完整复制应用资源，请稍候")
        try commands.checked("/usr/bin/ditto", ["--norsrc", "--noextattr", source.url.path, app.path], timeout: 900)
        try Task.checkCancellation()
        guard try AppDescriptor.inspect(source.url).fingerprint == source.fingerprint else {
            throw DualError.message("原版应用在复制期间发生了更新，请稍后重试。")
        }
        progress(0.30, "设置副本身份与角标图标")
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        var info = try readPlist(plistURL)
        info["CFBundleIdentifier"] = source.cloneID
        // Internal bundle names can be part of helper/resource paths (e.g. QQ Helper.app).
        // Change the user-facing name without changing the runtime's internal name.
        info["CFBundleDisplayName"] = source.name + "副本"
        info["CFBundleIconFile"] = "AppDualClone.icns"
        info.removeValue(forKey: "CFBundleIconName")
        // Avoid claiming the original's URL schemes and documents in LaunchServices.
        info.removeValue(forKey: "CFBundleURLTypes")
        info.removeValue(forKey: "CFBundleDocumentTypes")
        info.removeValue(forKey: "UTExportedTypeDeclarations")
        info.removeValue(forKey: "UTImportedTypeDeclarations")
        if mode == .chromiumProfile { ChromiumProfile.configure(&info, source: source) }
        if let electronConfiguration {
            var environment = info["LSEnvironment"] as? [String: String] ?? [:]
            environment.merge(electronConfiguration.environment) { _, isolated in isolated }
            info["LSEnvironment"] = environment
            // app.asar and its integrity hash remain untouched.
            try JSONEncoder().encode(electronConfiguration).write(to: app.appendingPathComponent(ElectronLaunchConfiguration.relativePath), options: .atomic)
        }
        if mode == .dbxSandbox {
            var environment = info["LSEnvironment"] as? [String: String] ?? [:]
            environment["DBX_DATA_DIR"] = Compatibility.dbxDataDirectory(for: source, home: dataHome).path
            let key = DataCopyPaths.dbxCopiedKey(source: source, home: dataHome)
            let hasKey: Bool
            if dataPolicy == .includeExistingData {
                hasKey = try DataCopyPaths.dbxSourceKey(home: dataHome, directory: dbxSourceDirectory ?? DataCopyPaths.defaultDBXSource(home: dataHome)) != nil
            } else { hasKey = fm.fileExists(atPath: key.path) }
            if hasKey { environment["DBX_SECRET_KEY_FILE"] = key.path }
            info["LSEnvironment"] = environment
        }
        // Keep TeamIdentifier metadata: some clients derive their private IPC namespace from it.
        try writePlist(info, to: plistURL)
        let resources = app.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try Icons.writeCloneIcon(source: source.url, destination: resources.appendingPathComponent("AppDualClone.icns"))
        try updateLocalizedNames(in: resources, name: source.name + "副本")
        let manifest = CloneManifest(source: source, mode: mode, home: dataHome)
        try JSONEncoder().encode(manifest).write(to: app.appendingPathComponent(CloneManifest.relativePath), options: .atomic)
        let mainEntitlements = EntitlementPolicy.main(Compatibility.preparedEntitlements(originalEntitlements, mode: mode), source: source)
        let mainEntitlementURL = stage.appendingPathComponent("main-entitlements.plist")
        try writePlist(mainEntitlements, to: mainEntitlementURL)
        let tree = try inspectTree(app)
        let nodes = (tree.machos + tree.bundles).sorted {
            if $0.pathComponents.count == $1.pathComponents.count { return $0.path < $1.path }
            return $0.pathComponents.count > $1.pathComponents.count
        }
        for (index, node) in nodes.enumerated() {
            try Task.checkCancellation()
            progress(0.36 + 0.43 * Double(index) / Double(max(nodes.count, 1)), "重新签名 \(index + 1)/\(nodes.count)")
            let nestedEntitlements = cleanNestedEntitlements(try entitlements(at: node))
            // Inherited helper apps keep their original IDs: clients can locate them by ID.
            // Standalone sandbox components need a distinct container identity as well.
            if tree.bundles.contains(node), nestedEntitlements["com.apple.security.app-sandbox"] as? Bool == true,
               nestedEntitlements["com.apple.security.inherit"] as? Bool != true {
                let nestedPlist = node.appendingPathComponent("Contents/Info.plist")
                if fm.fileExists(atPath: nestedPlist.path) {
                    var nestedInfo = try readPlist(nestedPlist)
                    let oldID = nestedInfo["CFBundleIdentifier"] as? String ?? node.lastPathComponent
                    nestedInfo["CFBundleIdentifier"] = source.cloneID + "." + digest(oldID).prefix(12)
                    nestedInfo.removeValue(forKey: "CFBundleURLTypes")
                    try writePlist(nestedInfo, to: nestedPlist)
                }
            }
            let nestedEntitlementURL = stage.appendingPathComponent("nested-entitlements.plist")
            let versions = try frameworkVersions(at: node)
            if versions.isEmpty {
                try writePlist(nestedEntitlements, to: nestedEntitlementURL)
                try commands.checked("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--entitlements", nestedEntitlementURL.path, node.path])
            } else {
                // codesign signs only Current by default, but --deep verifies every version.
                // Ad-hoc defaults use each binary's cdhash as its designated requirement.
                // The enclosing app requires all versions to satisfy one framework identity.
                let identity = try frameworkIdentityOptions(at: node, versions: versions)
                for version in versions {
                    let permissions = cleanNestedEntitlements(try entitlements(at: node, bundleVersion: version))
                    try writePlist(permissions, to: nestedEntitlementURL)
                    try commands.checked("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--bundle-version", version]
                        + identity + ["--entitlements", nestedEntitlementURL.path, node.path])
                }
            }
        }
        try commands.checked("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--entitlements", mainEntitlementURL.path, app.path])
        progress(0.84, "校验完整签名与副本权限")
        try verify(app)
        let embedded = try entitlements(at: app)
        guard (embedded["com.apple.security.app-sandbox"] as? Bool == true) == mode.requiresAppSandbox,
              embedded["com.apple.application-identifier"] as? String == mainEntitlements["com.apple.application-identifier"] as? String,
              embedded["com.apple.security.application-groups"] as? [String] == mainEntitlements["com.apple.security.application-groups"] as? [String] else {
            throw DualError.message("副本的身份或隔离权限校验失败，已保留旧副本。")
        }
        let mainExecutable = app.appendingPathComponent("Contents/MacOS/" + source.executable)
        let nestedNodes = (tree.machos + tree.bundles).filter { $0 != mainExecutable }
        for (index, node) in nestedNodes.enumerated() {
            progress(0.85 + 0.10 * Double(index) / Double(max(nestedNodes.count, 1)), "校验嵌套权限 \(index + 1)/\(nestedNodes.count)")
            let e = try entitlements(at: node)
            guard (e["com.apple.security.application-groups"] as? [String] ?? []).isEmpty,
                  (e["keychain-access-groups"] as? [String] ?? []).isEmpty else {
                throw DualError.message("嵌套组件仍包含原版共享权限，已取消安装：\(node.lastPathComponent)")
            }
        }
        try Task.checkCancellation()
        guard !isRunning(destination) else { throw DualError.message("副本在构建期间被打开，请退出副本后重试。") }
        guard try AppDescriptor.inspect(source.url).fingerprint == source.fingerprint else {
            throw DualError.message("原版应用已更新，本次构建已取消，请重新创建副本。")
        }
        try validateDestination(destination, source: source)
        if dataPolicy == .includeExistingData {
            let stopped = {
                guard !isRunning(source.url), !isRunning(destination) else {
                    throw DualError.message("原版或副本在复制期间被打开，请完全退出后重试。")
                }
            }
            try stopped()
            let locations = try DataCopyPaths.locations(source: source, mode: mode, entitlements: originalEntitlements,
                home: dataHome, dbxOverride: dbxSourceDirectory, browserOverride: browserSourceDirectory, electronOverride: electronSourceDirectory)
            let transaction = try DataCopyTransaction(source: source, appDestination: destination, home: dataHome, commands: commands)
            try transaction.prepare(locations: locations, stagedApp: app, checkStopped: stopped) { label in progress(0.96, label) }
            try Task.checkCancellation(); try stopped()
            guard try AppDescriptor.inspect(source.url).fingerprint == source.fingerprint else {
                throw DualError.message("原版在数据复制期间更新，已取消本次安装。")
            }
            progress(0.98, "安装程序和数据，保留旧副本备份")
            try transaction.commit(checkStopped: stopped)
        } else {
            progress(0.96, "安装副本，保留原有账号数据")
            try AtomicInstaller.install(staged: app, destination: destination)
        }
        progress(1, "副本已创建，等待启动验证")
        return manifest
    }

    private func validateDestination(_ destination: URL, source: AppDescriptor) throws {
        guard destination.standardizedFileURL != source.url,
              !destination.resolvingSymlinksInPath().path.hasPrefix(source.url.path + "/") else {
            throw DualError.message("副本路径不能指向原版应用。")
        }
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        let attr = try FileManager.default.attributesOfItem(atPath: destination.path)
        guard attr[.type] as? FileAttributeType != .typeSymbolicLink,
              let manifest = try? CloneManifest.read(at: destination),
              manifest.sourceID == source.bundleID, manifest.cloneID == source.cloneID else {
            throw DualError.message("目标位置已有其他应用，无法覆盖：\(destination.lastPathComponent)。请先在访达中移动该文件。")
        }
    }

    private func cleanNestedEntitlements(_ original: [String: Any]) -> [String: Any] {
        original.filter { key, _ in
            !key.hasPrefix("com.apple.developer.") &&
                !["com.apple.application-identifier", "application-identifier", "com.apple.security.application-groups", "keychain-access-groups"].contains(key)
        }
    }

    private func frameworkVersions(at node: URL) throws -> [String] {
        guard node.pathExtension == "framework" else { return [] }
        let versions = node.appendingPathComponent("Versions")
        guard FileManager.default.fileExists(atPath: versions.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).filter {
            let flags = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return flags.isDirectory == true && flags.isSymbolicLink != true
        }.map(\.lastPathComponent).sorted()
    }

    private func frameworkIdentityOptions(at node: URL, versions: [String]) throws -> [String] {
        guard versions.count > 1 else { return [] }
        var ids = Set<String>()
        for version in versions {
            let info = try readPlist(node.appendingPathComponent("Versions/\(version)/Resources/Info.plist"))
            guard let id = info["CFBundleIdentifier"] as? String,
                  id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
                throw DualError.message("框架版本缺少有效的签名标识：\(node.lastPathComponent)")
            }
            ids.insert(id)
        }
        guard ids.count == 1, let id = ids.first else {
            throw DualError.message("框架各版本的标识不一致，无法安全重新签名：\(node.lastPathComponent)")
        }
        return ["--identifier", id, "--requirements", "=designated => identifier \"\(id)\""]
    }

    private func readPlist(_ url: URL) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] else {
            throw DualError.message("应用属性文件无效。")
        }
        return value
    }
    private func writePlist(_ value: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url, options: .atomic)
    }
    private func updateLocalizedNames(in resources: URL, name: String) throws {
        for folder in try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil) where folder.pathExtension == "lproj" {
            let url = folder.appendingPathComponent("InfoPlist.strings")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var info = try readPlist(url)
            info["CFBundleDisplayName"] = name
            try writePlist(info, to: url)
        }
    }

    private func inspectTree(_ root: URL) throws -> (machos: [URL], bundles: [URL], bytes: Int64) {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        var enumerationError: Error?
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, errorHandler: { _, error in
            enumerationError = error; return false
        }) else { throw DualError.message("无法读取应用资源。") }
        var machos = [URL](), bundles = [URL](), bytes: Int64 = 0
        let magic: Set<[UInt8]> = [[0xcf,0xfa,0xed,0xfe],[0xce,0xfa,0xed,0xfe],[0xfe,0xed,0xfa,0xcf],
                                   [0xfe,0xed,0xfa,0xce],[0xca,0xfe,0xba,0xbe],[0xbe,0xba,0xfe,0xca],
                                   [0xca,0xfe,0xba,0xbf],[0xbf,0xba,0xfe,0xca]]
        for case let url as URL in walk {
            try Task.checkCancellation()
            let r = try url.resourceValues(forKeys: Set(keys))
            if r.isSymbolicLink == true {
                guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
                    throw DualError.message("该应用含有指向外部的资源链接，无法创建完整独立副本。")
                }
                continue
            }
            if r.isDirectory == true {
                if ["app", "framework", "xpc", "appex"].contains(url.pathExtension) { bundles.append(url) }
            } else if r.isRegularFile == true {
                bytes += Int64(r.fileSize ?? 0)
                let handle = try FileHandle(forReadingFrom: url)
                let header = try handle.read(upToCount: 4) ?? Data(); try handle.close()
                if magic.contains(Array(header)) { machos.append(url) }
            }
        }
        if let enumerationError { throw enumerationError }
        return (machos, bundles, bytes)
    }
}
