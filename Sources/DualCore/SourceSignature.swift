import Foundation

/// Source integrity failures are distinct from failures while signing the new clone.
/// Keep the underlying tool output for diagnostics without presenting raw tool jargon in the alert.
public struct SourceSignatureFailure: LocalizedError, Sendable {
    public struct ResourceIssue: Equatable, Sendable {
        public let kind: String
        public let path: String
    }
    public let name: String
    public let sourceURL: URL
    public let status: Int32
    public let output: String

    public init(name: String, sourceURL: URL, status: Int32, output: String) {
        self.name = name; self.sourceURL = sourceURL; self.status = status; self.output = output
    }

    public var resourceIssues: [ResourceIssue] {
        let labels = [("file added: ", "新增资源"), ("file modified: ", "资源已变更"), ("file missing: ", "缺少资源")]
        let prefixes = [sourceURL.path + "/", sourceURL.resolvingSymlinksInPath().path + "/"]
        var result = [ResourceIssue]()
        for line in output.components(separatedBy: .newlines) {
            for (prefix, label) in labels where line.hasPrefix(prefix) {
                var path = String(line.dropFirst(prefix.count))
                if let root = prefixes.first(where: path.hasPrefix) {
                    path = String(path.dropFirst(root.count))
                } else if path.hasPrefix("/") {
                    // codesign may print /var while Foundation canonicalizes it to /private/var.
                    var ancestor = URL(fileURLWithPath: path).standardizedFileURL
                    var missing = [String]()
                    while ancestor.path != "/", !FileManager.default.fileExists(atPath: ancestor.path) {
                        missing.append(ancestor.lastPathComponent); ancestor.deleteLastPathComponent()
                    }
                    var resolved = ancestor.resolvingSymlinksInPath()
                    for part in missing.reversed() { resolved.appendPathComponent(part) }
                    let canonical = resolved.path
                    if let root = prefixes.first(where: canonical.hasPrefix) { path = String(canonical.dropFirst(root.count)) }
                }
                let issue = ResourceIssue(kind: label, path: path)
                if !result.contains(issue) { result.append(issue) }
            }
        }
        return result
    }

    public var allowsManualConfirmation: Bool {
        status > 0 && (!resourceIssues.isEmpty || output.contains("a sealed resource is missing or invalid"))
    }

    public var summary: String {
        let reason: String
        if output.contains("code object is not signed at all") {
            reason = "原版“\(name)”没有代码签名，无法完成完整性校验。"
        } else if !resourceIssues.isEmpty || output.contains("a sealed resource is missing or invalid") {
            reason = "原版“\(name)”的应用文件与签名记录不一致。"
        } else {
            reason = "原版“\(name)”未通过签名完整性校验。"
        }
        let issues = resourceIssues
        var parts = [reason]
        if !issues.isEmpty {
            parts.append(issues.prefix(6).map { "\($0.kind)：\($0.path)" }.joined(separator: "\n"))
            if issues.count > 6 { parts.append("另有 \(issues.count - 6) 项，详见“复制诊断”。") }
        }
        return parts.joined(separator: "\n\n")
    }

    public var errorDescription: String? {
        summary + "\n\n本次创建已停止，已有副本保留。请从原安装渠道重新安装签名完整的版本，再重试；账号数据无需删除。"
    }

    public var verificationDetails: String {
        "阶段：原版完整性校验（复制前）\n退出码：\(status)\n原版路径：\(sourceURL.path)\n系统校验详情：\n\(output)"
    }

    public var diagnostics: String {
        (errorDescription ?? "原版签名校验失败") + "\n\n" + verificationDetails
    }

    fileprivate var confirmationKey: String {
        // codesign reports validated nested code in a nondeterministic order.
        let lines = output.components(separatedBy: .newlines).filter {
            !$0.isEmpty && !$0.hasPrefix("--prepared:") && !$0.hasPrefix("--validated:")
        }.sorted()
        return digest("\(status)\n" + lines.joined(separator: "\n"))
    }
}

/// A per-attempt acknowledgement of one application's reported resource differences.
/// This is never saved in preferences, the registry, or a clone manifest.
public struct SourceSignatureApproval: Sendable {
    private let source: AppDescriptor
    private let failure: SourceSignatureFailure

    public init(source: AppDescriptor, failure: SourceSignatureFailure) {
        self.source = source; self.failure = failure
    }

    public var diagnostics: String {
        "用户已手动确认：仅本次允许继续创建。原版完整性校验仍未通过；副本仍须重新签名并完成校验。\n\n"
            + failure.summary + "\n\n" + failure.verificationDetails
    }

    fileprivate func permits(_ current: SourceSignatureFailure, for source: AppDescriptor) -> Bool {
        self.source == source && failure.allowsManualConfirmation && current.allowsManualConfirmation
            && failure.sourceURL.standardizedFileURL == source.url.standardizedFileURL
            && current.sourceURL.standardizedFileURL == source.url.standardizedFileURL
            && failure.confirmationKey == current.confirmationKey
    }
}

public enum SourceSignature {
    public static func verify(_ source: AppDescriptor, approval: SourceSignatureApproval? = nil,
                              commands: CommandRunning = SystemCommands()) throws {
        if approval != nil, try AppDescriptor.inspect(source.url) != source {
            throw DualError.message("原版应用在确认期间发生变化，请重新创建并检查最新差异。")
        }
        // Request verbose resource differences so the alert can identify the affected files.
        let result = try commands.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", source.url.path], timeout: 120)
        try Task.checkCancellation()
        guard result.status == 0 else {
            let failure = SourceSignatureFailure(name: source.name, sourceURL: source.url, status: result.status, output: result.output)
            guard approval?.permits(failure, for: source) == true else { throw failure }
            return
        }
    }
}
