import Foundation

/// Chromium's native macOS product-directory override works for Finder launches and helpers.
/// Detect the capability in the installed framework instead of allowing browser brand names.
public enum ChromiumProfile {
    public static func relativeDirectory(for app: AppDescriptor) -> String { "AppDual/Profiles/" + app.cloneID }
    public static func directory(for app: AppDescriptor, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/" + relativeDirectory(for: app))
    }

    public static func ensureDirectory(for app: AppDescriptor, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let target = directory(for: app, home: home)
        var path = target.standardizedFileURL
        while path.path != "/" {
            if path.path != "/var", path.path != "/tmp",
               (try? FileManager.default.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw DualError.message("浏览器副本的数据路径包含符号链接，无法确认数据独立。")
            }
            path.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    public static func supportsProductDirectory(_ app: AppDescriptor) throws -> Bool {
        guard app.isChromiumBrowser else { return false }
        let frameworks = app.url.appendingPathComponent("Contents/Frameworks")
        let candidates = (try? FileManager.default.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil)) ?? []
        let marker = Data("CrProductDirName\0".utf8)
        for framework in candidates where framework.pathExtension == "framework" {
            let binary = framework.appendingPathComponent(framework.deletingPathExtension().lastPathComponent).resolvingSymlinksInPath()
            guard binary.path.hasPrefix(app.url.path + "/"), FileManager.default.isExecutableFile(atPath: binary.path) else { continue }
            let handle = try FileHandle(forReadingFrom: binary)
            defer { try? handle.close() }
            var tail = Data()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                let block = tail + chunk
                if block.range(of: marker) != nil { return true }
                tail = Data(block.suffix(marker.count - 1))
            }
        }
        return false
    }

    /// Brand defaults only suggest a source folder for optional import; they do not gate support.
    public static func defaultSource(for app: AppDescriptor, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let known = ["com.google.Chrome": "Google/Chrome", "com.google.Chrome.beta": "Google/Chrome Beta",
                     "com.google.Chrome.dev": "Google/Chrome Dev", "com.google.Chrome.canary": "Google/Chrome Canary",
                     "org.chromium.Chromium": "Chromium", "com.microsoft.edgemac": "Microsoft Edge"]
        guard let relative = app.bundleInfo["CrProductDirName"] as? String ?? known[app.bundleID],
              !relative.hasPrefix("/"), relative.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ DataCopyPaths.safeSegment(String($0)) }) else { return nil }
        return home.appendingPathComponent("Library/Application Support/" + relative)
    }

    public static func configure(_ info: inout [String: Any], source: AppDescriptor) {
        info["CrProductDirName"] = relativeDirectory(for: source)
        // A re-signed copy must not register itself as the vendor's auto-update target.
        for key in Array(info.keys) where key.hasPrefix("KS") { info.removeValue(forKey: key) }
    }

    /// Examine file paths only. Never read browser databases, account information or credentials.
    public static func verifyRunning(pid: Int32, source: AppDescriptor, commands: CommandRunning = SystemCommands()) throws {
        let output = try commands.checked("/usr/sbin/lsof", ["-a", "-p", String(pid), "-Fn"], timeout: 15)
        try validateOpenFiles(output, expected: directory(for: source), original: defaultSource(for: source))
    }

    public static func validateOpenFiles(_ output: String, expected: URL, original: URL?, kind: String = "浏览器") throws {
        let paths = output.split(separator: "\n").filter { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
        func contains(_ root: URL) -> Bool {
            let prefix = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            return paths.contains { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(prefix) }
        }
        if let original, contains(original) {
            throw DualError.message("检测到副本仍在访问原版\(kind)的数据目录，隔离验证未通过。请退出副本，暂勿登录账号。")
        }
        guard contains(expected) else {
            throw DualError.message("副本已启动，但尚未确认它使用独立\(kind)数据目录。请完成首次启动界面后重试打开。")
        }
    }
}
