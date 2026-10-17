import Foundation
import Darwin

public enum DataCopyPolicy: String, CaseIterable, Identifiable, Sendable {
    case applicationOnly
    case includeExistingData
    public var id: String { rawValue }
    public var title: String {
        self == .applicationOnly ? "仅复制应用程序" : "复制应用及现有数据"
    }
}

public struct DataCopyLocation: Codable, Sendable {
    public let source: URL?
    public let destination: URL
    public let label: String
    public let excludedTopLevelNames: [String]
    public let requireInternalSymlinks: Bool
    public init(source: URL?, destination: URL, label: String, excludedTopLevelNames: [String] = [], requireInternalSymlinks: Bool = false) {
        self.source = source; self.destination = destination; self.label = label
        self.excludedTopLevelNames = excludedTopLevelNames; self.requireInternalSymlinks = requireInternalSymlinks
    }
}

public enum DataCopyPaths {
    public static func backupRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/AppDual/DataBackups")
    }

    public static func defaultDBXSource(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/com.dbx.app")
    }
    public static func dbxCopiedKey(source: AppDescriptor, home: URL) -> URL {
        home.appendingPathComponent("Library/Containers/\(source.cloneID)/Data/Library/Application Support/TwinSpaceKeys/DBX/secret.key")
    }
    public static func dbxSourceKey(home: URL, directory: URL) throws -> URL? {
        for key in [directory.appendingPathComponent(".dbx/secret.key"), home.appendingPathComponent("Library/Application Support/dbx/secret.key")] {
            if try pathExists(key) { try rejectSymlinkAncestors(key); return key }
        }
        return nil
    }

    public static func locations(source: AppDescriptor, mode: CloneMode, entitlements: [String: Any],
                                 home: URL, dbxOverride: URL? = nil, browserOverride: URL? = nil, electronOverride: URL? = nil) throws -> [DataCopyLocation] {
        let container = home.appendingPathComponent("Library/Containers/\(source.cloneID)/Data")
        if mode == .electronProfile {
            guard let origin = electronOverride ?? ElectronProfile.defaultSource(for: source, home: home), try pathExists(origin) else {
                throw DualError.message("没有找到原版应用的资料目录，请选择实际目录，或先使用“仅复制应用程序”。")
            }
            return [DataCopyLocation(source: origin, destination: try ElectronLaunchConfiguration(source: source, home: home).profile,
                label: "应用本机资料", excludedTopLevelNames: ["SingletonLock", "SingletonCookie", "SingletonSocket", "DevToolsActivePort", "RunningChromeVersion"], requireInternalSymlinks: true)]
        }
        if mode == .chromiumProfile {
            guard let origin = browserOverride ?? ChromiumProfile.defaultSource(for: source, home: home),
                  try pathExists(origin.appendingPathComponent("Local State")) else {
                throw DualError.message("请选择包含 Local State 文件的原版浏览器数据目录。可在浏览器版本页查看“个人资料路径”，再选择它的上一级目录。")
            }
            return [DataCopyLocation(source: origin, destination: ChromiumProfile.directory(for: source, home: home),
                label: "浏览器本机数据", excludedTopLevelNames: ["SingletonLock", "SingletonCookie", "SingletonSocket", "DevToolsActivePort", "RunningChromeVersion"], requireInternalSymlinks: true)]
        }
        if mode == .dbxSandbox {
            let origin = dbxOverride ?? defaultDBXSource(home: home)
            guard try pathExists(origin.appendingPathComponent("dbx.db")) else {
                throw DualError.message("没有在所选目录找到 dbx.db，请在创建选项中选择 DBX 原版实际使用的数据目录。")
            }
            var result = [DataCopyLocation(source: origin,
                destination: Compatibility.dbxDataDirectory(for: source, home: home), label: "DBX 配置与记录")]
            // Only the application's legacy local key file is included. Never export the system keychain.
            let localKey = try dbxSourceKey(home: home, directory: origin)
            let targetKey = dbxCopiedKey(source: source, home: home)
            let hasTargetKey = try pathExists(targetKey)
            if localKey != nil || hasTargetKey {
                result.append(DataCopyLocation(source: localKey,
                                               destination: targetKey, label: "DBX 本地密钥文件"))
            }
            return result
        }
        let origin = home.appendingPathComponent("Library/Containers/\(source.bundleID)/Data")
        guard try pathExists(origin) else {
            throw DualError.message("没有找到原版应用的数据容器。请先运行原版，或选择“仅复制应用程序”。")
        }
        var result = [DataCopyLocation(source: origin, destination: container, label: "应用本机数据")]
        let sourceGroups = entitlements["com.apple.security.application-groups"] as? [String] ?? []
        let targetGroups = EntitlementPolicy.main(entitlements, source: source)["com.apple.security.application-groups"] as? [String] ?? []
        for (oldID, newID) in zip(sourceGroups, targetGroups) {
            guard safeSegment(oldID), safeSegment(newID), oldID != newID else {
                throw DualError.message("应用组数据路径无法安全隔离。")
            }
            let from = home.appendingPathComponent("Library/Group Containers/" + oldID)
            let to = home.appendingPathComponent("Library/Group Containers/" + newID)
            // Container Manager owns the root metadata. Copy children without replacing that metadata.
            let sourceNames = try names(in: from), targetNames = try names(in: to)
            for name in Set(sourceNames + targetNames).sorted() {
                result.append(DataCopyLocation(source: sourceNames.contains(name) ? from.appendingPathComponent(name) : nil,
                    destination: to.appendingPathComponent(name), label: "应用组数据：\(name)"))
            }
        }
        return result
    }

    private static func names(in url: URL) throws -> [String] {
        guard try pathExists(url) else { return [] }
        try rejectSymlinkAncestors(url)
        return try FileManager.default.contentsOfDirectory(atPath: url.path).filter {
            !$0.hasPrefix(".com.apple.containermanagerd.")
        }
    }
    public static func safeSegment(_ text: String) -> Bool {
        !text.isEmpty && text != "." && text != ".." && !text.contains("/") && !text.contains("\0")
    }
}

private func pathExists(_ url: URL) throws -> Bool {
    var attributes = stat()
    if lstat(url.path, &attributes) == 0 { return true }
    if errno == ENOENT { return false }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

private func rejectSymlinkAncestors(_ path: URL) throws {
    var url = path.standardizedFileURL
    while url.path != "/" {
        if url.path != "/var", url.path != "/tmp",
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw DualError.message("数据根路径包含符号链接，请选择实际目录后重试：\(path.lastPathComponent)")
        }
        url.deleteLastPathComponent()
    }
}

/// Durable old snapshots are prepared before any destination is changed. A pending journal
/// blocks launching the clone until recovery restores the complete previous state.
public final class DataCopyTransaction {
    private struct Entry: Codable {
        let destination: URL
        let oldSnapshot: URL?
        let newSnapshot: URL?
        let label: String
    }
    private struct Journal: Codable {
        let cloneID: String
        let appDestination: URL
        let folder: URL
        var state: String
        var entries: [Entry]
    }
    public let folder: URL
    private let home: URL
    private let commands: CommandRunning
    private let pending: URL
    private var journal: Journal
    private var snapshots: [(URL, String)] = []
    private let fm = FileManager.default

    deinit {
        if journal.state == "preparing" || journal.state == "prepared" { try? fm.removeItem(at: folder) }
    }

    public init(source: AppDescriptor, appDestination: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                commands: CommandRunning = SystemCommands()) throws {
        guard appDestination.standardizedFileURL.path != source.url.standardizedFileURL.path else {
            throw DualError.message("副本路径不能指向原版应用。")
        }
        self.home = home; self.commands = commands
        let root = DataCopyPaths.backupRoot(home: home)
        try rejectSymlinkAncestors(root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        folder = root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        pending = root.appendingPathComponent(source.cloneID + ".pending.json")
        guard !fm.fileExists(atPath: pending.path) else { throw DualError.message("上次数据复制尚未恢复，请先恢复备份。") }
        journal = Journal(cloneID: source.cloneID, appDestination: appDestination, folder: folder, state: "preparing", entries: [])
        try save()
    }

    public func prepare(locations: [DataCopyLocation], stagedApp: URL,
                        checkStopped: () throws -> Void, progress: (String) -> Void) throws {
        let all = locations + [DataCopyLocation(source: stagedApp, destination: journal.appDestination, label: "副本应用程序")]
        var destinations = Set<String>()
        for (index, item) in all.enumerated() {
            try Task.checkCancellation(); try checkStopped()
            guard Self.allowed(item.destination, journal: journal, home: home), destinations.insert(item.destination.path).inserted else {
                throw DualError.message("数据目标路径无效或重复。")
            }
            try rejectSymlinkAncestors(item.destination)
            if let source = item.source {
                try rejectSymlinkAncestors(source)
                let a = source.standardizedFileURL.path.lowercased(), b = item.destination.standardizedFileURL.path.lowercased()
                guard a != b, !a.hasPrefix(b + "/"), !b.hasPrefix(a + "/") else {
                    throw DualError.message("原版与副本的数据路径不能重合。")
                }
                let storage = folder.standardizedFileURL.path.lowercased()
                guard a != storage, !storage.hasPrefix(a + "/"), !a.hasPrefix(storage + "/") else {
                    throw DualError.message("数据目录包含TwinSpace的备份目录，请选择应用专用的数据目录。")
                }
            }
            let newURL = item.source == nil ? nil : folder.appendingPathComponent("new-\(index)")
            let oldURL = try pathExists(item.destination) ? folder.appendingPathComponent("old-\(index)") : nil
            if let source = item.source, let newURL {
                progress("复制\(item.label)")
                try snapshot(source, to: newURL, exclusions: item.excludedTopLevelNames,
                             requireInternalSymlinks: item.requireInternalSymlinks, checkStopped: checkStopped)
            }
            if let oldURL {
                progress("备份副本原有数据：\(item.label)")
                try snapshot(item.destination, to: oldURL, checkStopped: checkStopped)
            }
            journal.entries.append(Entry(destination: item.destination, oldSnapshot: oldURL, newSnapshot: newURL, label: item.label))
            try save()
        }
        try checkStopped(); try verifyUnchanged(); journal.state = "prepared"; try save()
    }

    public func commit(checkStopped: () throws -> Void) throws {
        try Task.checkCancellation(); try checkStopped(); try verifyUnchanged()
        journal.state = "applying"; try save()
        try JSONEncoder().encode(journal).write(to: pending, options: .atomic)
        do {
            for entry in journal.entries {
                try Task.checkCancellation(); try checkStopped()
                try rejectSymlinkAncestors(entry.destination)
                try fm.createDirectory(at: entry.destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if let staged = entry.newSnapshot {
                    try AtomicInstaller.install(staged: staged, destination: entry.destination)
                } else if fm.fileExists(atPath: entry.destination.path) {
                    // The old snapshot is already durable; a unique holding path avoids deletion here.
                    try fm.moveItem(at: entry.destination, to: folder.appendingPathComponent("removed-" + UUID().uuidString))
                }
            }
            journal.state = "complete"; try save()
            try fm.removeItem(at: pending)
            // Old data is retained in old-*; discard only swapped-out duplicate staging copies.
            for entry in journal.entries { if let new = entry.newSnapshot { try? fm.removeItem(at: new) } }
        } catch {
            // Do not overwrite a clone that the user opened during the transaction.
            do {
                try checkStopped()
                try Self.restore(journal, home: home, commands: SystemCommands(cancellable: false), checkStopped: checkStopped)
                journal.state = "rolled-back"; try save(); try fm.removeItem(at: pending)
            } catch {
                throw DualError.message("复制未完成，暂未恢复。请退出原版和副本后，在TwinSpace中重试。备份位于：\(folder.path)")
            }
            throw error
        }
    }

    public static func recoverIfNeeded(source: AppDescriptor, appDestination: URL, home: URL,
                                       isRunning: (URL) -> Bool, acquireLock: Bool = true) throws {
        guard appDestination.standardizedFileURL.path != source.url.standardizedFileURL.path else {
            throw DualError.message("副本路径不能指向原版应用。")
        }
        let root = DataCopyPaths.backupRoot(home: home)
        let marker = root.appendingPathComponent(source.cloneID + ".pending.json")
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        var lock: Int32 = -1
        if acquireLock {
            lock = open(appDestination.deletingLastPathComponent().appendingPathComponent(".appdual-build.lock").path,
                        O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lock >= 0 else { throw DualError.message("无法锁定副本目录以恢复备份。") }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { close(lock); throw DualError.message("另一个操作正在使用副本，请稍后重试。") }
        }
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }
        guard !isRunning(appDestination) else { throw DualError.message("上次复制被中断，请先退出副本，再重试以恢复备份。") }
        try rejectSymlinkAncestors(root)
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: marker))
        guard journal.cloneID == source.cloneID, journal.appDestination.standardizedFileURL.path == appDestination.standardizedFileURL.path,
              journal.folder.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
              UUID(uuidString: journal.folder.lastPathComponent) != nil else {
            throw DualError.message("备份恢复记录无效，已停止操作。")
        }
        try restore(journal, home: home, commands: SystemCommands(cancellable: false)) {
            guard !isRunning(appDestination) else { throw DualError.message("副本在恢复期间被打开，请退出后重试。") }
        }
        var restored = journal; restored.state = "recovered"
        try JSONEncoder().encode(restored).write(to: journal.folder.appendingPathComponent("manifest.json"), options: .atomic)
        try FileManager.default.removeItem(at: marker)
    }

    private static func restore(_ journal: Journal, home: URL, commands: CommandRunning, checkStopped: () throws -> Void) throws {
        let fm = FileManager.default
        try rejectSymlinkAncestors(journal.folder)
        let recovery = journal.folder.appendingPathComponent("recovery-" + UUID().uuidString)
        try fm.createDirectory(at: recovery, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for (index, entry) in journal.entries.enumerated().reversed() {
            try checkStopped()
            guard allowed(entry.destination, journal: journal, home: home) else { throw DualError.message("备份目标越界，停止恢复。") }
            try rejectSymlinkAncestors(entry.destination)
            // Preserve the state found during recovery as well, including data created outside TwinSpace.
            if fm.fileExists(atPath: entry.destination.path) {
                try commands.checked("/usr/bin/ditto", ["--norsrc", "--noextattr", entry.destination.path,
                    recovery.appendingPathComponent("before-\(index)").path], timeout: 3600)
            }
            if let old = entry.oldSnapshot {
                guard old.standardizedFileURL.path == journal.folder.appendingPathComponent("old-\(index)").standardizedFileURL.path else {
                    throw DualError.message("备份源路径无效。")
                }
                try rejectSymlinkAncestors(old)
                let stage = recovery.appendingPathComponent("restore-\(index)")
                try commands.checked("/usr/bin/ditto", ["--norsrc", "--noextattr", old.path, stage.path], timeout: 3600)
                try checkStopped()
                try fm.createDirectory(at: entry.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try AtomicInstaller.install(staged: stage, destination: entry.destination)
            } else if fm.fileExists(atPath: entry.destination.path) {
                try checkStopped()
                try fm.moveItem(at: entry.destination, to: recovery.appendingPathComponent("uncommitted-\(index)"))
            }
        }
    }

    private static func allowed(_ destination: URL, journal: Journal, home: URL) -> Bool {
        let path = destination.standardizedFileURL.path
        if path == journal.appDestination.standardizedFileURL.path { return true }
        let container = home.appendingPathComponent("Library/Containers/\(journal.cloneID)/Data").path
        if path == container || path.hasPrefix(container + "/") { return true }
        let profile = home.appendingPathComponent("Library/Application Support/AppDual/Profiles/\(journal.cloneID)").path
        if path == profile { return true }
        let electronHome = home.appendingPathComponent("Library/Application Support/AppDual/Electron/\(journal.cloneID)/Home").path
        if path.hasPrefix(electronHome + "/") { return true }
        let groups = home.appendingPathComponent("Library/Group Containers").path + "/"
        guard path.hasPrefix(groups) else { return false }
        let parts = String(path.dropFirst(groups.count)).split(separator: "/")
        return parts.count >= 2 && parts[0].contains(journal.cloneID) && !parts[1].hasPrefix(".com.apple.containermanagerd.")
    }

    private func snapshot(_ source: URL, to target: URL, exclusions: [String] = [], requireInternalSymlinks: Bool = false, checkStopped: () throws -> Void) throws {
        let before = try stamp(source)
        if requireInternalSymlinks {
            let root = source.standardizedFileURL.resolvingSymlinksInPath().path
            var failure: Error?
            guard let walk = fm.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey], errorHandler: { _, error in failure = error; return false }) else {
                throw DualError.message("无法检查浏览器数据目录。")
            }
            for case let item as URL in walk {
                try Task.checkCancellation()
                if exclusions.contains(item.lastPathComponent), item.deletingLastPathComponent().resolvingSymlinksInPath().path == root { walk.skipDescendants(); continue }
                if try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    let link = try fm.destinationOfSymbolicLink(atPath: item.path)
                    guard !link.hasPrefix("/"), item.resolvingSymlinksInPath().path.hasPrefix(root + "/") else {
                        throw DualError.message("浏览器数据含有绝对路径或外部链接，无法保证复制后独立。请选择“仅复制应用程序”。")
                    }
                }
            }
            if let failure { throw failure }
        }
        if exclusions.isEmpty {
            try commands.checked("/usr/bin/ditto", ["--norsrc", "--noextattr", source.path, target.path], timeout: 3600)
        } else {
            guard exclusions.allSatisfy(DataCopyPaths.safeSegment) else { throw DualError.message("数据复制排除项无效。") }
            try fm.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for name in try fm.contentsOfDirectory(atPath: source.path).sorted() where !exclusions.contains(name) {
                try checkStopped()
                try commands.checked("/usr/bin/ditto", ["--norsrc", "--noextattr", source.appendingPathComponent(name).path,
                    target.appendingPathComponent(name).path], timeout: 3600)
            }
        }
        try checkStopped()
        guard before == (try stamp(source)) else { throw DualError.message("复制期间数据发生变化，已取消本次操作。请退出相关应用后重试。") }
        snapshots.append((source, before))
    }

    private func verifyUnchanged() throws {
        for (url, expected) in snapshots {
            guard try stamp(url) == expected else {
                throw DualError.message("快照准备期间数据发生变化，已停止替换。请完全退出相关应用后重试。")
            }
        }
    }

    /// Metadata only: no parsing of chats, credentials or database contents.
    private func stamp(_ root: URL) throws -> String {
        var lines = [String]()
        func add(_ url: URL) throws {
            let a = try fm.attributesOfItem(atPath: url.path)
            let modified = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            lines.append("\(url.path.dropFirst(root.path.count))|\(a[.type] ?? "")|\(a[.size] ?? 0)|\(modified)")
        }
        try add(root)
        if (try fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType) == .typeDirectory {
            var failure: Error?
            guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: nil, errorHandler: { _, error in failure = error; return false }) else {
                throw DualError.message("无法读取应用数据目录。")
            }
            for case let url as URL in walk { try Task.checkCancellation(); try add(url) }
            if let failure { throw failure }
        }
        return digest(lines.sorted().joined(separator: "\n"))
    }

    private func save() throws {
        try JSONEncoder().encode(journal).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    }
}
