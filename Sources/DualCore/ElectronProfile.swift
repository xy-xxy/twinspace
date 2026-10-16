import Foundation
import Darwin

/// Read package metadata only; never unpack, execute or alter the application's JavaScript.
public enum ElectronPackage {
    public static func name(for app: AppDescriptor) throws -> String {
        let resources = app.url.appendingPathComponent("Contents/Resources")
        let plain = resources.appendingPathComponent("app/package.json")
        let archive = resources.appendingPathComponent("app.asar")
        let data: Data
        if FileManager.default.fileExists(atPath: plain.path) {
            guard plain.resolvingSymlinksInPath().path.hasPrefix(app.url.path + "/"),
                  ((try FileManager.default.attributesOfItem(atPath: plain.path)[.size] as? NSNumber)?.intValue ?? Int.max) <= 65536 else {
                throw DualError.message("Electron 应用的包信息无效。")
            }
            data = try Data(contentsOf: plain)
        } else {
            guard archive.resolvingSymlinksInPath().path.hasPrefix(app.url.path + "/") else {
                throw DualError.message("Electron 应用包指向应用外部，无法创建完整独立副本。")
            }
            let handle = try FileHandle(forReadingFrom: archive)
            defer { try? handle.close() }
            guard let prefix = try handle.read(upToCount: 16), prefix.count == 16 else { throw DualError.message("无法读取 Electron 应用包信息。") }
            func number(_ offset: Int) -> UInt64 {
                (0..<4).reduce(0) { $0 | (UInt64(prefix[offset + $1]) << (8 * $1)) }
            }
            let headerSize = number(4), jsonSize = number(12)
            guard number(0) == 4, jsonSize > 0, jsonSize <= 32 * 1024 * 1024, headerSize >= jsonSize + 8,
                  headerSize <= 32 * 1024 * 1024 + 16,
                  let headerData = try handle.read(upToCount: Int(jsonSize)), headerData.count == Int(jsonSize),
                  let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
                  let files = header["files"] as? [String: Any], let entry = files["package.json"] as? [String: Any],
                  let size = entry["size"] as? Int, size > 0, size <= 65536,
                  let offsetString = entry["offset"] as? String, let offset = UInt64(offsetString),
                  entry["unpacked"] as? Bool != true, entry["link"] == nil else {
                throw DualError.message("Electron 应用的 ASAR 包信息无效，无法确定独立数据目录。")
            }
            let length = try handle.seekToEnd()
            guard length >= 8 + headerSize, offset <= length - 8 - headerSize,
                  UInt64(size) <= length - 8 - headerSize - offset else { throw DualError.message("Electron 应用包已损坏。") }
            try handle.seek(toOffset: 8 + headerSize + offset)
            data = try handle.read(upToCount: size) ?? Data()
        }
        guard let package = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = package["productName"] as? String ?? package["name"] as? String else {
            throw DualError.message("Electron 应用缺少名称信息，无法确定独立数据目录。")
        }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DataCopyPaths.safeSegment(name), !name.contains("\\"), name.utf8.count <= 200 else {
            throw DualError.message("Electron 应用的数据目录名称无效。")
        }
        return name
    }
}

public struct ElectronLaunchConfiguration: Codable, Sendable {
    public static let relativePath = "Contents/Resources/TwinSpaceLaunch.json"
    public let schema: Int
    public let cloneID: String
    public let executable: String
    public let packageName: String
    public let root: URL
    public var home: URL { root.appendingPathComponent("Home") }
    public var profile: URL { home.appendingPathComponent("Library/Application Support/" + packageName) }
    public var cache: URL { home.appendingPathComponent("Library/Caches/" + packageName) }
    public var temporary: URL {
        var base = root
        for _ in 0..<5 { base.deleteLastPathComponent() }
        // A short, persistent directory also works for Finder launches after a reboot.
        return base.appendingPathComponent(".twinspace-tmp/" + cloneID.suffix(20))
    }

    public init(source: AppDescriptor, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        schema = 1; cloneID = source.cloneID; executable = source.executable
        packageName = try ElectronPackage.name(for: source)
        root = ElectronProfile.root(for: source, home: home)
    }

    public func validate() throws {
        guard schema == 1, cloneID.range(of: "^io\\.local\\.appdual\\.clone\\.[a-f0-9]{20}$", options: .regularExpression) != nil,
              DataCopyPaths.safeSegment(executable),
              DataCopyPaths.safeSegment(packageName), !packageName.contains("\\"),
              root.isFileURL, root.path.hasSuffix("/Library/Application Support/AppDual/Electron/" + cloneID),
              !root.pathComponents.contains("..") else { throw DualError.message("副本的启动配置无效，请在双栖中重建副本。") }
    }

    public func prepareDirectories(includeTemporary: Bool = false) throws {
        try validate()
        for folder in [root, home, profile, cache] + (includeTemporary ? [temporary] : []) {
            var current = folder.standardizedFileURL
            while current.path != "/" {
                if current.path != "/var", current.path != "/tmp",
                   (try? FileManager.default.attributesOfItem(atPath: current.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
                    throw DualError.message("副本的数据路径包含符号链接，已停止启动。")
                }
                current.deleteLastPathComponent()
            }
            if let owner = try? FileManager.default.attributesOfItem(atPath: folder.path)[.ownerAccountID] as? NSNumber,
               owner.uint32Value != getuid() { throw DualError.message("副本目录不属于当前用户。") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    public var environment: [String: String] {
        ["HOME": home.path, "CFFIXED_USER_HOME": home.path,
         "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
         "XDG_CACHE_HOME": cache.path, "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path,
         "TMPDIR": temporary.path + "/"]
    }

    public func arguments(preserving input: [String]) -> [String] {
        var result = [String](), skipValue = false
        for value in input {
            if skipValue { skipValue = false; continue }
            if value == "--user-data-dir" || value == "--disk-cache-dir" { skipValue = true; continue }
            if value.hasPrefix("--user-data-dir=") || value.hasPrefix("--disk-cache-dir=") { continue }
            result.append(value)
        }
        return ["--user-data-dir=" + profile.path, "--disk-cache-dir=" + cache.path] + result
    }
}

public enum ElectronProfile {
    public static func root(for app: AppDescriptor, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/AppDual/Electron/" + app.cloneID)
    }
    public static func defaultSource(for app: AppDescriptor, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard let name = try? ElectronPackage.name(for: app) else { return nil }
        return home.appendingPathComponent("Library/Application Support/" + name)
    }
    public static func configuration(at clone: URL) throws -> ElectronLaunchConfiguration {
        let value = try JSONDecoder().decode(ElectronLaunchConfiguration.self, from: Data(contentsOf: clone.appendingPathComponent(ElectronLaunchConfiguration.relativePath)))
        try value.validate(); return value
    }

    public static func verifyRunning(source: AppDescriptor, clone: URL, commands: CommandRunning = SystemCommands()) throws {
        let configuration = try configuration(at: clone)
        let pids = RunningApps.processIDs(at: clone)
        guard !pids.isEmpty else { throw LaunchFailure.exited }
        let output = try commands.checked("/usr/sbin/lsof", ["-a", "-p", pids.map(String.init).joined(separator: ","), "-Fn"], timeout: 20)
        try ChromiumProfile.validateOpenFiles(output, expected: configuration.profile, original: defaultSource(for: source), kind: "应用")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let names = Set([source.name, source.bundleID, source.bundleInfo["CFBundleName"] as? String ?? "", configuration.packageName]).filter(DataCopyPaths.safeSegment)
        let originals = names.flatMap { name in ["Library/Application Support/", "Library/Caches/", "Library/Logs/"].map { home.appendingPathComponent($0 + name).path + "/" } }
        let paths = output.split(separator: "\n").filter { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
        if paths.contains(where: { path in originals.contains(where: path.hasPrefix) }) {
            throw DualError.message("检测到副本仍在使用原版的配置或缓存目录，隔离检查未通过。请先退出副本，暂勿登录。")
        }
    }
}
