import Foundation
import Darwin

public enum CloneRemoval {
    /// Delete only the owned .app. Profiles, containers and data backups are retained.
    public static func remove(record: AppRecord, directory: URL, registry: Registry,
                              isRunning: (URL) -> Bool = RunningApps.isRunning,
                              delete: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws -> [AppRecord] {
        let fm = FileManager.default
        let clone = try record.cloneURL(in: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = open(directory.appendingPathComponent(".appdual-build.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw DualError.message("无法锁定副本目录，请检查权限。") }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw DualError.message("有副本正在构建或恢复，请完成后再移除。") }
        var records = try registry.load()
        guard records.contains(where: { $0.id == record.id }) else { return records }
        guard !isRunning(clone) else { throw DualError.message("请先从副本菜单完全退出应用，再移除。原版和账号数据都会保留。") }
        if fm.fileExists(atPath: clone.path) {
            let attrs = try fm.attributesOfItem(atPath: clone.path)
            guard attrs[.type] as? FileAttributeType != .typeSymbolicLink,
                  let manifest = try? CloneManifest.read(at: clone), manifest.sourceID == record.bundleID,
                  manifest.cloneID == "io.local.appdual.clone." + digest(record.bundleID).prefix(20),
                  clone.resolvingSymlinksInPath().path != URL(fileURLWithPath: record.sourcePath).resolvingSymlinksInPath().path else {
                throw DualError.message("目标位置不是TwinSpace创建的对应副本，已停止移除。请先在访达中检查该文件。")
            }
            guard !isRunning(clone) else { throw DualError.message("副本刚被打开，请先退出后再移除。") }
            try delete(clone)
            guard !fm.fileExists(atPath: clone.path) else { throw DualError.message("副本程序尚未删除，已保留列表记录。") }
        }
        records.removeAll { $0.id == record.id }
        do { try registry.save(records) }
        catch {
            throw DualError.message("副本程序已删除，但列表保存失败，请重试移除。账号数据已保留。\n\(error.localizedDescription)")
        }
        return records
    }
}
