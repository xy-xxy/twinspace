import Foundation

public enum CloneMode: String, Codable, Sendable {
    case existingSandbox
    case dbxSandbox
    case chromiumProfile
    case electronProfile

    public var requiresAppSandbox: Bool { self == .existingSandbox || self == .dbxSandbox }
}

public enum Compatibility {
    public static func isAdaptedDBX(_ app: AppDescriptor) -> Bool {
        app.bundleID == "com.dbx.app" && app.version == "0.6.21" && app.executable == "dbx"
    }

    public static func mode(for app: AppDescriptor, entitlements: [String: Any]) throws -> CloneMode {
        if entitlements["com.apple.security.app-sandbox"] as? Bool == true { return .existingSandbox }
        if isAdaptedDBX(app) { return .dbxSandbox }
        if app.isChromiumBrowser, try ChromiumProfile.supportsProductDirectory(app) { return .chromiumProfile }
        if app.isElectron { return .electronProfile }
        throw DualError.message("未检测到可用的独立数据目录机制，暂时无法为该应用创建隔离副本。")
    }

    public static func dbxDataDirectory(for app: AppDescriptor, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Containers/\(app.cloneID)/Data/Library/Application Support/DBX")
    }

    public static func preparedEntitlements(_ original: [String: Any], mode: CloneMode) -> [String: Any] {
        guard mode == .dbxSandbox else { return original }
        // DBX's upstream data-directory override is combined with an App Sandbox
        // container. This also separates WebKit state and restricts the original's
        // /tmp single-instance socket, without patching the client executable.
        var entitlements = original
        entitlements["com.apple.security.app-sandbox"] = true
        entitlements["com.apple.security.network.client"] = true
        entitlements["com.apple.security.network.server"] = true
        entitlements["com.apple.security.files.user-selected.read-write"] = true
        entitlements["com.apple.security.files.bookmarks.app-scope"] = true
        return entitlements
    }
}
