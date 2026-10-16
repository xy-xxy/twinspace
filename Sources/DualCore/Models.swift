import Foundation
import CryptoKit

public enum DualError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}

public func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

public struct AppDescriptor: Codable, Equatable, Sendable {
    public let url: URL
    public let bundleID: String
    public let name: String
    public let version: String
    public let build: String
    public let executable: String
    public let fingerprint: String

    public static func inspect(_ input: URL) throws -> AppDescriptor {
        let url = input.standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension.lowercased() == "app", !url.path.hasPrefix("/System/"),
              let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String, !id.isEmpty,
              id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil,
              !id.hasPrefix("io.local.appdual"),
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), executable != ".", executable != ".."
        else { throw DualError.message("请选择原版的 macOS 应用（.app），系统应用、双开工具和已有副本暂不支持。") }
        let binary = url.appendingPathComponent("Contents/MacOS/\(executable)")
        guard FileManager.default.isExecutableFile(atPath: binary.path),
              binary.resolvingSymlinksInPath().path.hasPrefix(url.path + "/") else {
            throw DualError.message("应用缺少有效的可执行文件。请重新安装原版应用。")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: binary.path)
        let signature = try? Data(contentsOf: url.appendingPathComponent("Contents/_CodeSignature/CodeResources"))
        let material = data.base64EncodedString() + (signature?.base64EncodedString() ?? "")
            + "\(attrs[.size] ?? 0):\(attrs[.modificationDate] ?? "")"
        let name = id == "com.tencent.xinWeChat" ? "微信" :
            (info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent)
        return AppDescriptor(url: url, bundleID: id, name: name,
                             version: info["CFBundleShortVersionString"] as? String ?? "未知",
                             build: info["CFBundleVersion"] as? String ?? "未知",
                             executable: executable, fingerprint: digest(material))
    }

    public var cloneID: String { "io.local.appdual.clone." + digest(bundleID).prefix(20) }
    public var bundleInfo: [String: Any] {
        (try? PropertyListSerialization.propertyList(from: Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]) ?? [:]
    }
    public var isChromiumBrowser: Bool { bundleInfo["NSPrincipalClass"] as? String == "BrowserCrApplication" && !isElectron }
    public var electronTeamID: String? {
        guard let info = try? PropertyListSerialization.propertyList(from: Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any],
              let team = info["ElectronTeamID"] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        return team
    }
    public var isElectron: Bool {
        guard let info = try? PropertyListSerialization.propertyList(from: Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any] else { return false }
        return info["NSPrincipalClass"] as? String == "AtomApplication" || info["ElectronTeamID"] is String
    }
    public var defaultCloneName: String {
        if bundleID == "com.tencent.xinWeChat" { return "微信副本.app" }
        let clean = name.components(separatedBy: CharacterSet(charactersIn: "/:\n\r")).joined(separator: "-")
        return "\(clean.prefix(60))副本-\(digest(bundleID).prefix(6)).app"
    }
}

public struct AppRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public var sourcePath: String
    public var name: String
    public let cloneName: String

    public init(app: AppDescriptor) {
        bundleID = app.bundleID; sourcePath = app.url.path
        name = app.name; cloneName = app.defaultCloneName
    }
    public func cloneURL(in directory: URL) throws -> URL {
        guard cloneName == URL(fileURLWithPath: cloneName).lastPathComponent,
              cloneName.hasSuffix(".app"), !cloneName.hasPrefix(".") else {
            throw DualError.message("副本路径无效。请从列表移除后重新添加应用。")
        }
        return directory.appendingPathComponent(cloneName)
    }
}

public struct CloneManifest: Codable, Equatable, Sendable {
    public static let relativePath = "Contents/Resources/AppDualManifest.json"
    public static let currentRecipe = 3
    public let recipe: Int
    public let sourceID: String
    public let sourceFingerprint: String
    public let sourceVersion: String
    public let sourceBuild: String
    public let cloneID: String
    public let builtAt: Date
    public let mode: CloneMode?
    public let profilePath: String?

    public init(source: AppDescriptor, mode: CloneMode = .existingSandbox, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        recipe = Self.currentRecipe; sourceID = source.bundleID
        sourceFingerprint = source.fingerprint; sourceVersion = source.version
        sourceBuild = source.build; cloneID = source.cloneID; builtAt = Date()
        self.mode = mode
        switch mode {
        case .dbxSandbox: profilePath = Compatibility.dbxDataDirectory(for: source, home: home).path
        case .chromiumProfile: profilePath = ChromiumProfile.directory(for: source, home: home).path
        case .electronProfile: profilePath = ElectronProfile.root(for: source, home: home).path
        case .existingSandbox: profilePath = nil
        }
    }
    public static func read(at url: URL) throws -> CloneManifest {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url.appendingPathComponent(relativePath)))
    }
    public func isCurrent(for app: AppDescriptor) -> Bool {
        (recipe == Self.currentRecipe || (recipe == 2 && mode != .electronProfile) || (recipe == 1 && !app.isElectron)) && sourceID == app.bundleID
            && sourceFingerprint == app.fingerprint && cloneID == app.cloneID
            && (mode != .dbxSandbox || profilePath == Compatibility.dbxDataDirectory(for: app).path)
            && (mode != .chromiumProfile || profilePath == ChromiumProfile.directory(for: app).path)
            && (mode != .electronProfile || profilePath == ElectronProfile.root(for: app).path)
    }
}

public struct Registry {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> [AppRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([AppRecord].self, from: Data(contentsOf: url))
    }
    public func save(_ records: [AppRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
    }
}
