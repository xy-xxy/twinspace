import AppKit
import Darwin

public enum LaunchFailure: LocalizedError, Equatable {
    case exited
    case identityUnavailable
    case differentApplication(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .exited:
            return "应用在启动过程中退出，未能打开窗口。可复制诊断继续排查该版本的启动问题。"
        case .identityUnavailable:
            return "系统没有返回可确认的应用启动位置，请稍后重试。"
        case let .differentApplication(expected, actual):
            return "系统打开了其他位置的应用。\n预期：\(expected)\n实际：\(actual)\n请先退出该应用后重试。"
        }
    }
}

public enum LaunchValidation {
    public static func sameLocation(_ first: URL, _ second: URL) -> Bool {
        guard first.isFileURL, second.isFileURL else { return false }
        let a = first.standardizedFileURL.resolvingSymlinksInPath().path
        let b = second.standardizedFileURL.resolvingSymlinksInPath().path
        if a == b { return true }
        var firstStat = stat(), secondStat = stat()
        return lstat(a, &firstStat) == 0 && lstat(b, &secondStat) == 0
            && firstStat.st_dev == secondStat.st_dev && firstStat.st_ino == secondStat.st_ino
    }

    public static func validate(requested: URL, actual: URL?, processID: Int32, terminated: Bool) throws {
        guard processID > 0, !terminated else { throw LaunchFailure.exited }
        guard let actual else { throw LaunchFailure.identityUnavailable }
        guard sameLocation(requested, actual) else {
            throw LaunchFailure.differentApplication(expected: requested.path, actual: actual.path)
        }
    }
}

public struct ApplicationInstance {
    public let processIdentifier: Int32
    public let application: NSRunningApplication
    private let executable: String?
    public init(application: NSRunningApplication, processIdentifier: Int32) {
        self.application = application; self.processIdentifier = processIdentifier
        executable = RunningApps.executablePath(for: processIdentifier)
    }
    public var isTerminated: Bool {
        guard processIdentifier > 0, let executable else { return true }
        return RunningApps.executablePath(for: processIdentifier) != executable
    }
}

@MainActor
public enum ApplicationLauncher {
    public static func open(_ url: URL) async throws -> ApplicationInstance {
        try Task.checkCancellation()
        RunningApps.primary(at: url)?.unhide()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true; configuration.createsNewApplicationInstance = false
        let usesElectronProfile = (try? CloneManifest.read(at: url).mode) == .electronProfile
        if usesElectronProfile {
            let settings = try ElectronProfile.configuration(at: url)
            try settings.prepareDirectories(includeTemporary: true)
            configuration.arguments = settings.arguments(preserving: [])
            configuration.environment = settings.environment
        }
        var launched: NSRunningApplication?, launchError: Error?
        do { launched = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration) }
        catch { if !usesElectronProfile { throw error }; launchError = error }
        if usesElectronProfile {
            // Allow late application registration, but require an actual process and exact paths.
            for _ in 0..<100 {
                try Task.checkCancellation()
                if let instance = RunningApps.observed(at: url), !instance.isTerminated {
                    try LaunchValidation.validate(requested: url, actual: instance.application.bundleURL,
                        processID: instance.processIdentifier, terminated: instance.isTerminated)
                    instance.application.unhide()
                    instance.application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                    return instance
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard let launched else { throw launchError ?? LaunchFailure.exited }
        var app = RunningApps.primary(at: url) ?? launched
        // A process that crashes during launch may be returned with PID -1 and no bundleURL.
        // Allow a live process briefly to finish registering, but never call a crash a path mismatch.
        for _ in 0..<20 where app.bundleURL == nil && app.processIdentifier > 0 && !app.isTerminated {
            try await Task.sleep(nanoseconds: 100_000_000)
            app = RunningApps.primary(at: url) ?? launched
        }
        try LaunchValidation.validate(requested: url, actual: app.bundleURL,
                                      processID: app.processIdentifier, terminated: app.isTerminated)
        app.unhide(); app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        return ApplicationInstance(application: app, processIdentifier: app.processIdentifier)
    }
}

public enum RunningApps {
    public static func executablePath(for pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        return length > 0 ? String(cString: path) : nil
    }

    public static func observed(at url: URL) -> ApplicationInstance? {
        guard let settings = try? ElectronProfile.configuration(at: url) else {
            guard let app = primary(at: url) else { return nil }
            return ApplicationInstance(application: app, processIdentifier: app.processIdentifier)
        }
        let runtime = url.appendingPathComponent("Contents/MacOS/" + settings.executable).resolvingSymlinksInPath().path
        for pid in processIDs(at: url) {
            guard let executable = executablePath(for: pid), URL(fileURLWithPath: executable).resolvingSymlinksInPath().path == runtime,
                  let app = NSRunningApplication(processIdentifier: pid), let bundle = app.bundleURL,
                  LaunchValidation.sameLocation(bundle, url) else { continue }
            // Combine the kernel PID, executable and registered bundle paths.
            return ApplicationInstance(application: app, processIdentifier: pid)
        }
        return nil
    }
    public static func isRunning(at url: URL) -> Bool {
        !matchingProcesses(at: url, stopAtFirst: true).isEmpty
    }
    public static func processIDs(at url: URL) -> [Int32] {
        matchingProcesses(at: url, stopAtFirst: false)
    }
    private static func matchingProcesses(at url: URL, stopAtFirst: Bool) -> [Int32] {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        // Query executable paths directly. Asking LaunchServices for every application's
        // dynamic isTerminated property can stall the UI during frequent status refreshes.
        // This also includes headless workers that keep writing after the UI exits.
        let capacity = max(1024, Int(proc_listallpids(nil, 0)) + 128)
        var pids = [pid_t](repeating: 0, count: capacity)
        var found = [Int32]()
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        for pid in pids.prefix(max(0, Int(count))) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4096)
            let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            if length > 0 {
                let executable = String(cString: path)
                if executable.hasPrefix(target + "/") {
                    found.append(pid); if stopAtFirst { return found }; continue
                }
                // Normalize macOS's /var and /private/var aliases in either direction.
                if ["/var/", "/tmp/", "/private/var/", "/private/tmp/"].contains(where: executable.hasPrefix),
                   URL(fileURLWithPath: executable).resolvingSymlinksInPath().path.hasPrefix(target + "/") {
                    found.append(pid); if stopAtFirst { return found }
                }
            }
        }
        return found
    }
    public static func primary(at url: URL) -> NSRunningApplication? {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == target && $0.processIdentifier > 0 && !$0.isTerminated
        }
    }
}
