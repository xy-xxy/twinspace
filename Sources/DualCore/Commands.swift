import Foundation
import Darwin

public struct CommandResult {
    public let status: Int32
    public let output: String
    public init(status: Int32, output: String) { self.status = status; self.output = output }
}

public protocol CommandRunning {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult
}

/// No shell interpolation. Child output goes to a file so verbose tools cannot deadlock a pipe.
public struct SystemCommands: CommandRunning {
    private let cancellable: Bool
    public init(cancellable: Bool = true) { self.cancellable = cancellable }
    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120) throws -> CommandResult {
        if cancellable { try Task.checkCancellation() }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("appdual-command-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: log) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.standardOutput = handle; process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        var failure: Error?
        while process.isRunning {
            if cancellable && Task.isCancelled { failure = CancellationError(); break }
            if Date() > deadline { failure = DualError.message("操作超时：\(URL(fileURLWithPath: executable).lastPathComponent)"); break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if failure != nil, process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        if let failure { throw failure }
        let reader = try FileHandle(forReadingFrom: log)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: 65_536) ?? Data()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

public extension CommandRunning {
    @discardableResult
    func checked(_ executable: String, _ args: [String], timeout: TimeInterval = 120) throws -> String {
        let result = try run(executable, args, timeout: timeout)
        guard result.status == 0 else {
            throw DualError.message("\(URL(fileURLWithPath: executable).lastPathComponent) 失败（\(result.status)）：\n\(result.output.prefix(3000))")
        }
        return result.output
    }
}
