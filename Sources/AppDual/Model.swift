import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DualCore

@MainActor
final class AppModel: ObservableObject {
    @Published var records: [AppRecord] = []
    @Published var selectedID: String?
    @Published var busy = false
    @Published var fraction: Double = 0
    @Published var phase = "准备就绪"
    @Published var errorText: String?
    @Published var notices: [String: String] = [:]
    @Published var diagnostics = ""
    @Published var refreshTick = 0
    private var task: Task<Void, Never>?
    private var work: Task<CloneManifest, Error>?
    private var timer: Timer?
    private var failures: [String: String] = [:]
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    private let registry = Registry(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AppDual/apps.json"))

    var selected: AppRecord? { records.first { $0.id == selectedID } }
    var source: AppDescriptor? {
        guard let selected else { return nil }
        return try? AppDescriptor.inspect(URL(fileURLWithPath: selected.sourcePath))
    }
    var cloneURL: URL? { try? selected?.cloneURL(in: directory) }
    var exists: Bool { cloneURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    var outdated: Bool {
        guard exists, let source, let cloneURL else { return false }
        return (try? CloneManifest.read(at: cloneURL).isCurrent(for: source)) != true
    }
    var sourceRunning: Bool { source.map { RunningApps.isRunning(at: $0.url) } ?? false }
    var cloneRunning: Bool { cloneURL.map { RunningApps.isRunning(at: $0) } ?? false }
    var status: String {
        if busy { return phase }
        if source == nil { return "原版应用已移动，请重新选择" }
        if outdated { return "副本需要更新，请重建副本" }
        if let id = selectedID, let notice = notices[id] { return notice }
        if cloneRunning { return "副本正在运行 · 账号登录待验证" }
        return exists ? "副本已创建 · 等待启动验证" : "尚未创建副本"
    }

    init() {
        do {
            records = try registry.load()
            if !FileManager.default.fileExists(atPath: registry.url.path),
               let wechat = try? AppDescriptor.inspect(URL(fileURLWithPath: "/Applications/WeChat.app")) {
                records = [AppRecord(app: wechat)]; try registry.save(records)
            }
            selectedID = records.first?.id
        } catch { errorText = "无法载入应用列表：\(error.localizedDescription)" }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTick += 1 }
        }
    }

    func chooseApp() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择需要双开的原版应用"
        panel.prompt = "添加应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self, !self.busy else { return }
                do {
                    var updated = self.records
                    for url in panel.urls {
                        let app = try AppDescriptor.inspect(url)
                        if let index = updated.firstIndex(where: { $0.bundleID == app.bundleID }) {
                            updated[index].sourcePath = app.url.path; updated[index].name = app.name
                        } else { updated.append(AppRecord(app: app)) }
                        self.selectedID = app.bundleID
                    }
                    try self.registry.save(updated); self.records = updated
                } catch { self.report(error) }
            }
        }
    }

    func removeSelected() {
        guard !busy, let selected else { return }
        busy = true; phase = "删除副本程序，保留账号数据"
        task = Task { [self] in
            defer { busy = false }
            do {
                let registry = registry, directory = directory
                records = try await Task.detached {
                    try CloneRemoval.remove(record: selected, directory: directory, registry: registry)
                }.value
                notices.removeValue(forKey: selected.id); selectedID = records.first?.id
            } catch { report(error) }
        }
    }

    func openOriginal() {
        guard !busy, let source else { return }
        busy = true; phase = "打开原版应用"
        task = Task { [self] in
            defer { busy = false }
            do { _ = try await launch(source.url) } catch { report(error) }
        }
    }

    func openClone(repair: Bool = false, dataPolicy: DataCopyPolicy = .applicationOnly, sourceDataDirectory: URL? = nil) {
        guard !busy, let source, let cloneURL, let selectedID else { return }
        if repair && cloneRunning {
            report(DualError.message("请先从副本菜单退出应用，再点击修复；不会强制结束它。")); return
        }
        busy = true; errorText = nil; fraction = 0; phase = "检查副本"
        notices.removeValue(forKey: selectedID)
        task = Task { [self] in
            defer { busy = false; work = nil }
            do {
                try await Task.detached {
                    try DataCopyTransaction.recoverIfNeeded(source: source, appDestination: cloneURL,
                        home: FileManager.default.homeDirectoryForCurrentUser, isRunning: RunningApps.isRunning)
                }.value
                if repair || !exists || outdated {
                    let worker = Task.detached(priority: .userInitiated) { [weak self] in
                        try CloneBuilder().build(source: source, destination: cloneURL, dataPolicy: dataPolicy,
                            dbxSourceDirectory: Compatibility.isAdaptedDBX(source) ? sourceDataDirectory : nil,
                            browserSourceDirectory: source.isChromiumBrowser ? sourceDataDirectory : nil,
                            electronSourceDirectory: source.isElectron ? sourceDataDirectory : nil,
                            isRunning: RunningApps.isRunning) { value, label in
                            Task { @MainActor [weak self] in
                                self?.fraction = value; self?.phase = label
                            }
                        }
                    }
                    work = worker
                    _ = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    failures.removeValue(forKey: source.fingerprint)
                }
                try Task.checkCancellation()
                guard failures[source.fingerprint] == nil || repair else {
                    throw DualError.message("这个版本的副本曾在启动观察期退出。请点击“重试启动”，或更新原版后修复副本。")
                }
                phase = "校验副本签名"
                try await Task.detached { try CloneBuilder().verify(cloneURL) }.value
                if try CloneManifest.read(at: cloneURL).mode == .chromiumProfile { try ChromiumProfile.ensureDirectory(for: source) }
                if try CloneManifest.read(at: cloneURL).mode == .electronProfile { try ElectronProfile.configuration(at: cloneURL).prepareDirectories(includeTemporary: true) }
                try Task.checkCancellation()
                let runningBefore = RunningApps.observed(at: cloneURL)
                phase = "正在打开副本"
                let application = try await launch(cloneURL)
                let validationNote = source.bundleID == "com.dbx.app" ? "数据库连接请在副本中单独配置" : "双账号登录待验证"
                if runningBefore != nil {
                    try await verifyProfile(source: source, cloneURL: cloneURL, pid: application.processIdentifier)
                    notices[selectedID] = "已打开现有副本窗口 · \(validationNote)"; return
                }
                phase = "观察副本启动状态（20 秒）"
                for index in 0..<20 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !application.isTerminated else {
                        failures[source.fingerprint] = "exited"
                        notices[selectedID] = "启动观察未通过"
                        throw DualError.message("副本在启动观察期内退出。如果不是你手动关闭，可能是当前版本不兼容。旧数据已保留；可重试启动，或更新原版后修复。")
                    }
                    fraction = Double(index + 1) / 20
                }
                try await verifyProfile(source: source, cloneURL: cloneURL, pid: application.processIdentifier)
                let mode = try CloneManifest.read(at: cloneURL).mode
                notices[selectedID] = (mode == .chromiumProfile || mode == .electronProfile) ? "启动及独立数据目录检查通过 · 登录待验证" : "启动观察通过 · \(validationNote)"
            } catch is CancellationError {
                notices[selectedID] = "操作已取消 · 如有中断的数据复制，下次打开前会恢复备份"
            } catch {
                if error is LaunchFailure { notices[selectedID] = "副本启动失败 · 请重建后重试" }
                if error is SourceSignatureFailure { notices[selectedID] = "原版完整性校验未通过 · 本次未创建副本" }
                report(error)
            }
            refreshTick += 1
        }
    }

    func retry() {
        guard let source else { return }
        failures.removeValue(forKey: source.fingerprint); openClone()
    }
    func cancel() { task?.cancel(); work?.cancel() }

    private func launch(_ url: URL) async throws -> ApplicationInstance {
        try await ApplicationLauncher.open(url)
    }

    private func verifyProfile(source: AppDescriptor, cloneURL: URL, pid: Int32) async throws {
        let mode = try CloneManifest.read(at: cloneURL).mode
        guard mode == .chromiumProfile || mode == .electronProfile else { return }
        phase = "检查应用实际使用的数据目录"
        do {
            try await Task.detached {
                if mode == .electronProfile { try ElectronProfile.verifyRunning(source: source, clone: cloneURL) }
                else { try ChromiumProfile.verifyRunning(pid: pid, source: source) }
            }.value
        } catch {
            notices[source.bundleID] = "独立数据目录尚未验证 · 查看诊断"
            throw error
        }
    }

    func copyDiagnostics() {
        let text = "双栖 TwinSpace 0.4.1 测试版\n系统：\(ProcessInfo.processInfo.operatingSystemVersionString)\n原版：\(source?.name ?? "无") \(source?.version ?? "") (\(source?.build ?? ""))\n标识：\(source?.bundleID ?? "无")\n状态：\(status)\n\(diagnostics)"
        let privacyFiltered = text.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(privacyFiltered, forType: .string)
    }
    private func report(_ error: Error) {
        errorText = error.localizedDescription
        diagnostics = (error as? SourceSignatureFailure)?.diagnostics ?? error.localizedDescription
    }
}
