import Foundation
import AppKit
import DualCore

setbuf(stdout, nil)
// CLI uses the same engine as the app. It never signs into accounts or reads app data.
let args = CommandLine.arguments
do {
    if args.count == 3, args[1] == "--make-icon" {
        try Icons.writeToolIcon(to: URL(fileURLWithPath: args[2]))
        exit(0)
    }
    guard args.count >= 3, ["inspect", "check-source", "build", "verify", "observe"].contains(args[1]) else {
        print("DualProbe inspect|check-source|build|verify|observe <original.app> [destination.app] [seconds]\ncheck-source verifies the original without changing files; observe checks an already running copy.")
        exit(2)
    }
    let source = try AppDescriptor.inspect(URL(fileURLWithPath: args[2]))
    let destination = args.count > 3 ? URL(fileURLWithPath: args[3]) : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/" + source.defaultCloneName)
    let builder = CloneBuilder()
    switch args[1] {
    case "check-source":
        try SourceSignature.verify(source)
        print("原版签名完整性校验通过；双开运行及账号功能仍需另行验证。")
    case "inspect":
        print("应用：\(source.name) \(source.version) (\(source.build))\n原版：\(source.bundleID)\n副本：\(source.cloneID)\n沙盒：\(try builder.entitlements(at: source.url)["com.apple.security.app-sandbox"] as? Bool == true)")
        print("隔离方式：\(try Compatibility.mode(for: source, entitlements: builder.entitlements(at: source.url)).rawValue)")
    case "build":
        _ = try builder.build(source: source, destination: destination, isRunning: RunningApps.isRunning) { value, label in
            print("\(Int(value * 100))% \(label)")
        }
        print("副本：\(destination.path)\n仅完成构建，尚未验证双账号登录。")
    case "verify":
        try builder.verify(destination)
        let manifest = try CloneManifest.read(at: destination)
        guard manifest.isCurrent(for: source) else { throw DualError.message("副本与原版版本或构建配方不同。") }
        print("签名和版本校验通过。\n\(source.cloneID)")
    case "observe":
        let seconds = args.count > 4 ? Double(args[4]) ?? 90 : 90
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            guard let original = RunningApps.observed(at: source.url), let clone = RunningApps.observed(at: destination),
                  !original.isTerminated, !clone.isTerminated else {
                throw DualError.message("原版与副本未同时运行。")
            }
            print("原版 PID \(original.processIdentifier)，副本 PID \(clone.processIdentifier)；持续观察中")
            RunLoop.current.run(until: Date().addingTimeInterval(min(10, max(0, deadline.timeIntervalSinceNow))))
        } while Date() < deadline
        print("并存观察通过（\(Int(seconds)) 秒）；扫码登录、消息和重开保持仍需手动验收。")
        if try CloneManifest.read(at: destination).mode == .chromiumProfile, let clone = RunningApps.primary(at: destination) {
            try ChromiumProfile.verifyRunning(pid: clone.processIdentifier, source: source)
            print("独立浏览器数据目录检查通过。")
        }
        if try CloneManifest.read(at: destination).mode == .electronProfile {
            try ElectronProfile.verifyRunning(source: source, clone: destination)
            print("Electron 独立资料及缓存目录检查通过。")
        }
    default: break
    }
} catch {
    fputs("\((error as? SourceSignatureFailure)?.diagnostics ?? error.localizedDescription)\n", stderr)
    exit(1)
}
