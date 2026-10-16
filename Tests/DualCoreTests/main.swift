import Foundation
import DualCore

final class DualCoreTests {
    var root: URL!
    func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AppDualTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func fixture(id: String = "test.vendor.chat", version: String = "1.0", build: String = "1", executable: String = "Chat") throws -> AppDescriptor {
        let url = root.appendingPathComponent("Original.app")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": executable, "CFBundleName": "Test Chat",
                                   "CFBundleShortVersionString": version, "CFBundleVersion": build]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        let exe = url.appendingPathComponent("Contents/MacOS/" + executable)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return try AppDescriptor.inspect(url)
    }

    func testDiscoveryReadsIdentityAndExecutable() throws {
        let app = try fixture()
        expectEqual(app.bundleID, "test.vendor.chat"); expectEqual(app.version, "1.0")
        expectEqual(app.executable, "Chat"); expectTrue(app.cloneID.hasPrefix("io.local.appdual.clone."))
    }
    func testDiscoveryRejectsMissingBundleAndClone() throws {
        expectThrows(try AppDescriptor.inspect(root.appendingPathComponent("Missing.app")))
        expectThrows(try fixture(id: "io.local.appdual.clone.test"))
    }
    func testDiscoveryRejectsExecutableTraversal() throws {
        let app = try fixture()
        let p = app.url.appendingPathComponent("Contents/Info.plist")
        var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: p), format: nil) as! [String: Any]
        info["CFBundleExecutable"] = "../../bin/sh"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: p)
        expectThrows(try AppDescriptor.inspect(app.url))
    }
    func testBuildChangeInvalidatesManifestButKeepsCloneIdentity() throws {
        let first = try fixture(); let manifest = CloneManifest(source: first)
        let next = try fixture(build: "2")
        expectNotEqual(first.fingerprint, next.fingerprint)
        expectEqual(first.cloneID, next.cloneID); expectFalse(manifest.isCurrent(for: next))
        expectTrue(manifest.isCurrent(for: first))
    }
    func testRegistryRoundTripAndInvalidPathRejection() throws {
        let record = AppRecord(app: try fixture())
        let registry = Registry(url: root.appendingPathComponent("config/apps.json"))
        expectTrue(try registry.load().isEmpty)
        try registry.save([record]); expectEqual(try registry.load(), [record])
        let data = try JSONSerialization.data(withJSONObject: ["bundleID":"x", "sourcePath":"/a", "name":"x", "cloneName":"../Original.app"])
        let invalid = try JSONDecoder().decode(AppRecord.self, from: data)
        expectThrows(try invalid.cloneURL(in: root))
    }
    func testEntitlementsKeepSandboxAndUseDistinctGroups() throws {
        let app = try fixture()
        let result = EntitlementPolicy.main([
            "com.apple.security.app-sandbox": true,
            "com.apple.application-identifier": "TEAM123456.test.vendor.chat",
            "com.apple.security.application-groups": ["TEAM123456.test.vendor.chat", "group.shared"],
            "keychain-access-groups": ["TEAM123456.shared"],
            "com.apple.developer.team-identifier": "TEAM123456",
            "com.apple.security.cs.allow-jit": true
        ], source: app)
        expectEqual(result["com.apple.application-identifier"] as? String, "TEAM123456." + app.cloneID)
        let groups = result["com.apple.security.application-groups"] as! [String]
        expectEqual(groups[0], "TEAM123456." + app.cloneID)
        expectTrue(groups.allSatisfy { !$0.contains(app.bundleID) && $0 != "group.shared" })
        expectNil(result["keychain-access-groups"]); expectNil(result["com.apple.developer.team-identifier"])
        expectEqual(result["com.apple.security.app-sandbox"] as? Bool, true)
        expectEqual(result["com.apple.security.cs.allow-jit"] as? Bool, true)
    }
    func testAtomicExchangeLeavesOldBundleAtStagingPath() throws {
        let stage = root.appendingPathComponent("Stage.app"), dest = root.appendingPathComponent("Copy.app")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: stage.appendingPathComponent("version"))
        try Data("old".utf8).write(to: dest.appendingPathComponent("version"))
        try AtomicInstaller.install(staged: stage, destination: dest)
        expectEqual(try String(contentsOf: dest.appendingPathComponent("version")), "new")
        expectEqual(try String(contentsOf: stage.appendingPathComponent("version")), "old")
    }
    func testAtomicInstallFailureDoesNotRemoveOldBundle() throws {
        let dest = root.appendingPathComponent("Copy.app")
        try Data("old".utf8).write(to: dest)
        expectThrows(try AtomicInstaller.install(staged: root.appendingPathComponent("missing"), destination: dest))
        expectEqual(try String(contentsOf: dest), "old")
    }
    func testBuildFailurePreservesOldBundleAndCleansStage() throws {
        let source = try fixture(); let dest = root.appendingPathComponent("Clones/Copy.app")
        let commands = MockCommands(source: source)
        let builder = CloneBuilder(commands: commands)
        _ = try builder.build(source: source, destination: dest)
        let old = try Data(contentsOf: dest.appendingPathComponent(CloneManifest.relativePath))
        commands.failSigning = true
        expectThrows(try builder.build(source: source, destination: dest))
        expectEqual(try Data(contentsOf: dest.appendingPathComponent(CloneManifest.relativePath)), old)
        expectFalse(try FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path).contains { $0.hasPrefix(".appdual-stage-") })
    }
    func testCopyInterruptionLeavesNoPartialInstalledBundle() throws {
        let source = try fixture(); let dest = root.appendingPathComponent("Clones/Copy.app")
        let commands = MockCommands(source: source); commands.failCopy = true
        expectThrows(try CloneBuilder(commands: commands).build(source: source, destination: dest))
        expectFalse(FileManager.default.fileExists(atPath: dest.path))
        expectFalse(try FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path).contains { $0.hasPrefix(".appdual-stage-") })
    }
    func testBuildRejectsRunningAndUnownedDestination() throws {
        let source = try fixture(); let dest = root.appendingPathComponent("Copy.app")
        let builder = CloneBuilder(commands: MockCommands(source: source))
        expectThrows(try builder.build(source: source, destination: dest, isRunning: { _ in true }))
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: dest.appendingPathComponent("user-file"))
        expectThrows(try builder.build(source: source, destination: dest))
        expectEqual(try String(contentsOf: dest.appendingPathComponent("user-file")), "keep")
    }
    func testBuildRefusesNonSandboxedSource() throws {
        let source = try fixture(); let commands = MockCommands(source: source); commands.sandboxed = false
        expectThrows(try CloneBuilder(commands: commands).build(source: source, destination: root.appendingPathComponent("Copy.app")))
        expectFalse(commands.copied)
    }
    func testDBXUsesSeparateSandboxAndExplicitDataDirectory() throws {
        let app = try fixture(id: "com.dbx.app", version: "0.6.21", executable: "dbx")
        let commands = MockCommands(source: app); commands.sandboxed = false
        let destination = root.appendingPathComponent("DBX Copy.app")
        let manifest = try CloneBuilder(commands: commands).build(source: app, destination: destination)
        expectEqual(manifest.mode, .dbxSandbox)
        expectEqual(manifest.profilePath, Compatibility.dbxDataDirectory(for: app).path)
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: destination.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
        expectEqual((info["LSEnvironment"] as? [String: String])?["DBX_DATA_DIR"], manifest.profilePath)
        expectTrue(manifest.profilePath!.contains("/Containers/" + app.cloneID + "/Data/"))
        let main = commands.entitlementsByPath.values.first { $0["com.apple.application-identifier"] != nil }
        expectEqual(main?["com.apple.security.app-sandbox"] as? Bool, true)
        expectEqual(main?["com.apple.security.network.client"] as? Bool, true)
    }
    func testUnverifiedDBXVersionIsNotSilentlyEnabled() throws {
        let app = try fixture(id: "com.dbx.app", version: "0.6.22", executable: "dbx")
        expectThrows(try Compatibility.mode(for: app, entitlements: [:]))
        expectEqual(try Compatibility.mode(for: app, entitlements: ["com.apple.security.app-sandbox": true]), .existingSandbox)
    }
    func testExistingWeChatManifestDoesNotRequireRebuild() throws {
        let app = try fixture(id: "com.tencent.xinWeChat")
        var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CloneManifest(source: app))) as! [String: Any]
        encoded.removeValue(forKey: "mode"); encoded.removeValue(forKey: "profilePath")
        encoded["recipe"] = 1
        let legacy = try JSONDecoder().decode(CloneManifest.self, from: JSONSerialization.data(withJSONObject: encoded))
        expectTrue(legacy.isCurrent(for: app))
    }
    func testSourceUpdateDuringCopyCancelsInstall() throws {
        let source = try fixture(); let dest = root.appendingPathComponent("Copy.app")
        let commands = MockCommands(source: source)
        commands.afterCopy = {
            let p = source.url.appendingPathComponent("Contents/Info.plist")
            var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: p), format: nil) as! [String: Any]
            info["CFBundleVersion"] = "updated-during-copy"
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: p)
        }
        expectThrows(try CloneBuilder(commands: commands).build(source: source, destination: dest))
        expectFalse(FileManager.default.fileExists(atPath: dest.path))
    }
    func testOpeningCopyDuringBuildPreventsReplacement() throws {
        let source = try fixture(); let dest = root.appendingPathComponent("Copy.app")
        let builder = CloneBuilder(commands: MockCommands(source: source))
        _ = try builder.build(source: source, destination: dest)
        let before = try Data(contentsOf: dest.appendingPathComponent(CloneManifest.relativePath))
        var calls = 0
        expectThrows(try builder.build(source: source, destination: dest, isRunning: { _ in
            calls += 1; return calls > 1
        }))
        expectEqual(try Data(contentsOf: dest.appendingPathComponent(CloneManifest.relativePath)), before)
    }
    func testExternalResourceSymlinkIsRejected() throws {
        let source = try fixture(); let commands = MockCommands(source: source)
        try FileManager.default.createSymbolicLink(at: source.url.appendingPathComponent("Contents/Resources/external"), withDestinationURL: root)
        expectThrows(try CloneBuilder(commands: commands).build(source: source, destination: root.appendingPathComponent("Copy.app")))
        expectFalse(commands.copied)
    }
    func testCloneIconHasAllRequiredRepresentations() throws {
        let source = try fixture(); let dest = root.appendingPathComponent("Copy.app")
        _ = try CloneBuilder(commands: MockCommands(source: source)).build(source: source, destination: dest)
        let icon = try Data(contentsOf: dest.appendingPathComponent("Contents/Resources/AppDualClone.icns"))
        expectEqual(String(data: icon.prefix(4), encoding: .utf8), "icns")
        expectTrue(icon.range(of: Data("ic10".utf8)) != nil)
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: dest.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
        expectEqual(info["CFBundleIconFile"] as? String, "AppDualClone.icns")
        expectEqual(info["CFBundleIdentifier"] as? String, source.cloneID)
    }
    func testProcessArgumentsAreNotInterpretedByShell() throws {
        let literal = "$(touch should-not-exist); `echo unsafe` with spaces"
        let result = try SystemCommands().run("/usr/bin/printf", ["%s", literal], timeout: 3)
        expectEqual(result.status, 0); expectEqual(result.output, literal)
    }
    func testProcessTimeoutTerminatesChild() throws {
        let start = Date()
        expectThrows(try SystemCommands().run("/bin/sleep", ["20"], timeout: 0.15))
        expectLessThan(Date().timeIntervalSince(start), 4)
    }

    private func dataFixture(browser: Bool = false) throws -> (app: AppDescriptor, home: URL, from: URL, to: URL, destination: URL, staged: URL) {
        let app = try fixture()
        let home = root.appendingPathComponent("home")
        let from = home.appendingPathComponent("Library/Containers/\(app.bundleID)/Data")
        let to = browser ? ChromiumProfile.directory(for: app, home: home) : home.appendingPathComponent("Library/Containers/\(app.cloneID)/Data")
        let destination = home.appendingPathComponent("Applications/Copy.app")
        let staged = root.appendingPathComponent("Prepared.app")
        for folder in [from, to, destination, staged] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("source-value".utf8).write(to: from.appendingPathComponent("config"))
        try Data("old-clone-value".utf8).write(to: to.appendingPathComponent("config"))
        try Data("old-program".utf8).write(to: destination.appendingPathComponent("version"))
        try Data("new-program".utf8).write(to: staged.appendingPathComponent("version"))
        return (app, home, from, to, destination, staged)
    }
    func testDataCopyCreatesIndependentFilesAndKeepsBackup() throws {
        let f = try dataFixture()
        let transaction = try DataCopyTransaction(source: f.app, appDestination: f.destination, home: f.home)
        try transaction.prepare(locations: [DataCopyLocation(source: f.from, destination: f.to, label: "配置")],
            stagedApp: f.staged, checkStopped: {}, progress: { _ in })
        try transaction.commit(checkStopped: {})
        expectEqual(try String(contentsOf: f.to.appendingPathComponent("config")), "source-value")
        expectEqual(try String(contentsOf: f.destination.appendingPathComponent("version")), "new-program")
        expectEqual(try String(contentsOf: transaction.folder.appendingPathComponent("old-0/config")), "old-clone-value")
        expectEqual(try String(contentsOf: transaction.folder.appendingPathComponent("old-1/version")), "old-program")
        try Data("independent-change".utf8).write(to: f.to.appendingPathComponent("config"))
        expectEqual(try String(contentsOf: f.from.appendingPathComponent("config")), "source-value")
    }
    func testInterruptedDataCommitRecoversBothDataAndProgram() throws { try checkInterruptedDataCommit(browser: false) }
    func testInterruptedBrowserImportRecoversProfileAndProgram() throws { try checkInterruptedDataCommit(browser: true) }
    private func checkInterruptedDataCommit(browser: Bool) throws {
        let f = try dataFixture(browser: browser)
        let transaction = try DataCopyTransaction(source: f.app, appDestination: f.destination, home: f.home)
        try transaction.prepare(locations: [DataCopyLocation(source: f.from, destination: f.to, label: "配置")],
            stagedApp: f.staged, checkStopped: {}, progress: { _ in })
        var count = 0
        expectThrows(try transaction.commit(checkStopped: {
            count += 1
            if count >= 3 { throw DualError.message("模拟提交中客户端重新打开") }
        }))
        let pending = DataCopyPaths.backupRoot(home: f.home).appendingPathComponent(f.app.cloneID + ".pending.json")
        expectTrue(FileManager.default.fileExists(atPath: pending.path))
        expectEqual(try String(contentsOf: f.to.appendingPathComponent("config")), "source-value")
        try DataCopyTransaction.recoverIfNeeded(source: f.app, appDestination: f.destination, home: f.home, isRunning: { _ in false })
        expectEqual(try String(contentsOf: f.to.appendingPathComponent("config")), "old-clone-value")
        expectEqual(try String(contentsOf: f.destination.appendingPathComponent("version")), "old-program")
        expectFalse(FileManager.default.fileExists(atPath: pending.path))
    }
    func testDataCopyRejectsDestinationOutsideClone() throws {
        let f = try dataFixture()
        let transaction = try DataCopyTransaction(source: f.app, appDestination: f.destination, home: f.home)
        expectThrows(try transaction.prepare(locations: [DataCopyLocation(source: f.from, destination: f.from, label: "无效")],
            stagedApp: f.staged, checkStopped: {}, progress: { _ in }))
        expectEqual(try String(contentsOf: f.from.appendingPathComponent("config")), "source-value")
    }
    func testChangedSourceAfterSnapshotPreventsCommit() throws {
        let f = try dataFixture()
        let transaction = try DataCopyTransaction(source: f.app, appDestination: f.destination, home: f.home)
        try transaction.prepare(locations: [DataCopyLocation(source: f.from, destination: f.to, label: "配置")],
            stagedApp: f.staged, checkStopped: {}, progress: { _ in })
        try Data("source-changed-after-snapshot".utf8).write(to: f.from.appendingPathComponent("config"))
        expectThrows(try transaction.commit(checkStopped: {}))
        expectEqual(try String(contentsOf: f.to.appendingPathComponent("config")), "old-clone-value")
    }
    func testDataCopyRejectsSymlinkDestination() throws {
        let f = try dataFixture()
        try FileManager.default.removeItem(at: f.to)
        try FileManager.default.createSymbolicLink(at: f.to, withDestinationURL: f.from)
        let transaction = try DataCopyTransaction(source: f.app, appDestination: f.destination, home: f.home)
        expectThrows(try transaction.prepare(locations: [DataCopyLocation(source: f.from, destination: f.to, label: "无效")],
            stagedApp: f.staged, checkStopped: {}, progress: { _ in }))
        expectEqual(try String(contentsOf: f.from.appendingPathComponent("config")), "source-value")
    }
    func testDataCopyRejectsSourceContainingItsBackupDirectory() throws {
        let f = try dataFixture()
        let transaction = try DataCopyTransaction(source: f.app, appDestination: f.destination, home: f.home)
        expectThrows(try transaction.prepare(locations: [DataCopyLocation(source: DataCopyPaths.backupRoot(home: f.home),
            destination: f.to, label: "递归源")], stagedApp: f.staged, checkStopped: {}, progress: { _ in }))
        expectEqual(try String(contentsOf: f.to.appendingPathComponent("config")), "old-clone-value")
    }
    func testGroupCopyPreservesContainerManagerMetadata() throws {
        let f = try dataFixture()
        let oldGroup = "TEAM123456." + f.app.bundleID, newGroup = "TEAM123456." + f.app.cloneID
        let sourceGroup = f.home.appendingPathComponent("Library/Group Containers/" + oldGroup)
        let targetGroup = f.home.appendingPathComponent("Library/Group Containers/" + newGroup)
        for folder in [sourceGroup, targetGroup] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let metadata = ".com.apple.containermanagerd.metadata.plist"
        try Data("original-metadata".utf8).write(to: sourceGroup.appendingPathComponent(metadata))
        try Data("clone-metadata".utf8).write(to: targetGroup.appendingPathComponent(metadata))
        try Data("source-settings".utf8).write(to: sourceGroup.appendingPathComponent("settings"))
        try Data("old-only".utf8).write(to: targetGroup.appendingPathComponent("old-only"))
        let locations = try DataCopyPaths.locations(source: f.app, mode: .existingSandbox,
            entitlements: ["com.apple.security.application-groups": [oldGroup]], home: f.home)
        let transaction = try DataCopyTransaction(source: f.app, appDestination: f.destination, home: f.home)
        try transaction.prepare(locations: locations, stagedApp: f.staged, checkStopped: {}, progress: { _ in })
        try transaction.commit(checkStopped: {})
        expectEqual(try String(contentsOf: targetGroup.appendingPathComponent(metadata)), "clone-metadata")
        expectEqual(try String(contentsOf: targetGroup.appendingPathComponent("settings")), "source-settings")
        expectFalse(FileManager.default.fileExists(atPath: targetGroup.appendingPathComponent("old-only").path))
    }
    func testApplicationOnlyBuildPreservesData() throws {
        let app = try fixture(); let home = root.appendingPathComponent("home")
        let data = home.appendingPathComponent("Library/Containers/\(app.cloneID)/Data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("keep-me".utf8).write(to: data.appendingPathComponent("config"))
        _ = try CloneBuilder(commands: MockCommands(source: app)).build(source: app, destination: home.appendingPathComponent("Applications/Copy.app"), dataHome: home)
        expectEqual(try String(contentsOf: data.appendingPathComponent("config")), "keep-me")
        expectFalse(FileManager.default.fileExists(atPath: DataCopyPaths.backupRoot(home: home).path))
    }
    func testCopyDataRequiresOriginalToBeStopped() throws {
        let app = try fixture(); let commands = MockCommands(source: app)
        expectThrows(try CloneBuilder(commands: commands).build(source: app, destination: root.appendingPathComponent("Copy.app"),
            dataPolicy: .includeExistingData, dataHome: root.appendingPathComponent("home"), isRunning: { $0 == app.url }))
        expectFalse(commands.copied)
    }
    func testDBXDataAndLocalKeyUseNonOverlappingDestinations() throws {
        let app = try fixture(id: "com.dbx.app", version: "0.6.21", executable: "dbx")
        let home = root.appendingPathComponent("home"), custom = root.appendingPathComponent("CustomDBX")
        try FileManager.default.createDirectory(at: custom.appendingPathComponent(".dbx"), withIntermediateDirectories: true)
        try Data("test-database".utf8).write(to: custom.appendingPathComponent("dbx.db"))
        try Data("test-key".utf8).write(to: custom.appendingPathComponent(".dbx/secret.key"))
        let locations = try DataCopyPaths.locations(source: app, mode: .dbxSandbox, entitlements: [:], home: home, dbxOverride: custom)
        expectEqual(locations.count, 2)
        expectFalse(locations[1].destination.path.lowercased().hasPrefix(locations[0].destination.path.lowercased() + "/"))
        expectEqual(locations[1].source, custom.appendingPathComponent(".dbx/secret.key"))
    }
    func testBuilderIncludesDataEndToEnd() throws {
        let app = try fixture(); let home = root.appendingPathComponent("home")
        let sourceData = home.appendingPathComponent("Library/Containers/\(app.bundleID)/Data")
        let targetData = home.appendingPathComponent("Library/Containers/\(app.cloneID)/Data")
        for directory in [sourceData, targetData] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("original-config".utf8).write(to: sourceData.appendingPathComponent("config"))
        try Data("prior-config".utf8).write(to: targetData.appendingPathComponent("config"))
        let destination = home.appendingPathComponent("Applications/Copy.app")
        let builder = CloneBuilder(commands: MockCommands(source: app))
        _ = try builder.build(source: app, destination: destination, dataHome: home)
        _ = try builder.build(source: app, destination: destination, dataPolicy: .includeExistingData, dataHome: home)
        expectEqual(try String(contentsOf: targetData.appendingPathComponent("config")), "original-config")
        expectEqual(try String(contentsOf: sourceData.appendingPathComponent("config")), "original-config")
        expectTrue(try CloneManifest.read(at: destination).isCurrent(for: app))
    }
    func testHeadlessAppWorkerIsDetected() throws {
        let app = try fixture()
        let binary = app.url.appendingPathComponent("Contents/MacOS/Chat")
        try FileManager.default.removeItem(at: binary)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: binary)
        let process = Process(); process.executableURL = binary; process.arguments = ["20"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let deadline = Date().addingTimeInterval(2)
        while !RunningApps.isRunning(at: app.url) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        expectTrue(RunningApps.isRunning(at: app.url))
    }
    func testFreshBundleURLDoesNotBecomeAFalseLocationMismatch() throws {
        let path = root.appendingPathComponent("New Clone.app").path
        let requestedBeforeCreation = URL(fileURLWithPath: path, isDirectory: false)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let registeredDirectoryURL = URL(fileURLWithPath: path, isDirectory: true)
        try LaunchValidation.validate(requested: requestedBeforeCreation, actual: registeredDirectoryURL, processID: 123, terminated: false)
    }
    func testLaunchRecognizesSymlinkAlias() throws {
        let real = root.appendingPathComponent("Real.app"), alias = root.appendingPathComponent("Alias.app")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        try LaunchValidation.validate(requested: alias, actual: real, processID: 123, terminated: false)
    }
    func testLaunchCrashIsNotReportedAsAnotherCopy() throws {
        do {
            try LaunchValidation.validate(requested: root.appendingPathComponent("Copy.app"), actual: nil, processID: -1, terminated: true)
            expectTrue(false)
        } catch { expectEqual(error as? LaunchFailure, .exited) }
    }
    func testLaunchWithoutIdentityHasItsOwnFailure() throws {
        do {
            try LaunchValidation.validate(requested: root.appendingPathComponent("Copy.app"), actual: nil, processID: 123, terminated: false)
            expectTrue(false)
        } catch { expectEqual(error as? LaunchFailure, .identityUnavailable) }
    }
    func testGenuineOtherApplicationIsStillRejected() throws {
        let expected = root.appendingPathComponent("Copy.app"), other = root.appendingPathComponent("Other.app")
        do {
            try LaunchValidation.validate(requested: expected, actual: other, processID: 123, terminated: false)
            expectTrue(false)
        } catch { expectEqual(error as? LaunchFailure, .differentApplication(expected: expected.path, actual: other.path)) }
    }
    func testInternalAndLocalizedNamesArePreservedForHelpers() throws {
        let app = try fixture()
        let localized = app.url.appendingPathComponent("Contents/Resources/zh_CN.lproj")
        try FileManager.default.createDirectory(at: localized, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Internal Helper Name", "CFBundleDisplayName": "Original Display"],
            format: .xml, options: 0).write(to: localized.appendingPathComponent("InfoPlist.strings"))
        let destination = root.appendingPathComponent("Copy.app")
        _ = try CloneBuilder(commands: MockCommands(source: app)).build(source: app, destination: destination)
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: destination.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
        let strings = try PropertyListSerialization.propertyList(from: Data(contentsOf: destination.appendingPathComponent("Contents/Resources/zh_CN.lproj/InfoPlist.strings")), format: nil) as! [String: Any]
        expectEqual(info["CFBundleName"] as? String, "Test Chat")
        expectEqual(info["CFBundleDisplayName"] as? String, "Test Chat副本")
        expectEqual(strings["CFBundleName"] as? String, "Internal Helper Name")
        expectEqual(strings["CFBundleDisplayName"] as? String, "Test Chat副本")
    }
    func testElectronIPCNamespaceKeepsExistingCloneDataGroups() throws {
        let original = try fixture(id: "com.tencent.qq")
        let entitlements: [String: Any] = ["com.apple.security.app-sandbox": true, "com.apple.security.application-groups": ["FN2V63AD2J.com.tencent"]]
        let oldGroups = EntitlementPolicy.main(entitlements, source: original)["com.apple.security.application-groups"] as! [String]
        let infoURL = original.url.appendingPathComponent("Contents/Info.plist")
        var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any]
        info["ElectronTeamID"] = "FN2V63AD2J"; info["NSPrincipalClass"] = "AtomApplication"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        let electron = try AppDescriptor.inspect(original.url)
        let updated = EntitlementPolicy.main(entitlements, source: electron)
        let identity = "FN2V63AD2J." + electron.cloneID
        expectEqual(updated["com.apple.application-identifier"] as? String, identity)
        expectEqual(updated["com.apple.security.application-groups"] as? [String], oldGroups + [identity])
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CloneManifest(source: electron))) as! [String: Any]
        legacy["recipe"] = 1
        let manifest = try JSONDecoder().decode(CloneManifest.self, from: JSONSerialization.data(withJSONObject: legacy))
        expectFalse(manifest.isCurrent(for: electron))
    }
    func browserFixture(marker: Bool = true) throws -> AppDescriptor {
        let app = try fixture(id: "net.unknown.browser")
        let plist = app.url.appendingPathComponent("Contents/Info.plist")
        var info = app.bundleInfo
        info["NSPrincipalClass"] = "BrowserCrApplication"
        info["KSProductID"] = "net.unknown.browser"
        info["CrProductDirName"] = "Unknown Browser"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        let framework = app.url.appendingPathComponent("Contents/Frameworks/Unknown Framework.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let binary = framework.appendingPathComponent("Unknown Framework")
        // Split the capability marker across the scanner's chunk boundary.
        var data = Data(repeating: 0, count: 1024 * 1024 - 5)
        data.append(Data((marker ? "CrProductDirName\0" : "UnrelatedFramework\0").utf8))
        try data.write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return try AppDescriptor.inspect(app.url)
    }
    func testUnknownChromiumBrandUsesCapabilityWithoutForcingSandbox() throws {
        let source = try browserFixture(); let commands = MockCommands(source: source); commands.sandboxed = false
        expectEqual(try Compatibility.mode(for: source, entitlements: [:]), .chromiumProfile)
        let destination = root.appendingPathComponent("Clones/Browser.app")
        let manifest = try CloneBuilder(commands: commands).build(source: source, destination: destination, dataHome: root)
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: destination.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
        expectEqual(info["CrProductDirName"] as? String, ChromiumProfile.relativeDirectory(for: source))
        expectEqual(info["CFBundleName"] as? String, source.bundleInfo["CFBundleName"] as? String)
        expectNil(info["KSProductID"])
        expectEqual(source.bundleInfo["CrProductDirName"] as? String, "Unknown Browser")
        expectEqual(manifest.profilePath, ChromiumProfile.directory(for: source, home: root).path)
        expectEqual(commands.entitlementsByPath.values.first { $0["com.apple.application-identifier"] != nil }?["com.apple.security.app-sandbox"] as? Bool, false)
    }
    func testChromiumWithoutCapabilityIsRejectedBeforeCopy() throws {
        let source = try browserFixture(marker: false); let commands = MockCommands(source: source); commands.sandboxed = false
        expectThrows(try CloneBuilder(commands: commands).build(source: source, destination: root.appendingPathComponent("Copy.app"), dataHome: root))
        expectFalse(commands.copied)
    }
    func testBrowserDataCopyExcludesLocksAndPreservesIndependentData() throws {
        let source = try browserFixture(); let commands = MockCommands(source: source); commands.sandboxed = false
        let origin = root.appendingPathComponent("Browser Data")
        try FileManager.default.createDirectory(at: origin.appendingPathComponent("Default"), withIntermediateDirectories: true)
        try Data("fixture state".utf8).write(to: origin.appendingPathComponent("Local State"))
        try Data("fixture bookmarks".utf8).write(to: origin.appendingPathComponent("Default/Bookmarks"))
        try FileManager.default.createSymbolicLink(atPath: origin.appendingPathComponent("SingletonLock").path, withDestinationPath: "host-123")
        try FileManager.default.createSymbolicLink(atPath: origin.appendingPathComponent("SingletonSocket").path, withDestinationPath: "/tmp/test-socket")
        let target = ChromiumProfile.directory(for: source, home: root)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old profile".utf8).write(to: target.appendingPathComponent("previous"))
        let destination = root.appendingPathComponent("Clones/Browser.app")
        _ = try CloneBuilder(commands: commands).build(source: source, destination: destination, dataPolicy: .includeExistingData,
            browserSourceDirectory: origin, dataHome: root)
        expectEqual(try String(contentsOf: target.appendingPathComponent("Default/Bookmarks")), "fixture bookmarks")
        expectFalse(try FileManager.default.contentsOfDirectory(atPath: target.path).contains("SingletonLock"))
        expectFalse(try FileManager.default.contentsOfDirectory(atPath: target.path).contains("SingletonSocket"))
        try Data("clone changed".utf8).write(to: target.appendingPathComponent("Default/Bookmarks"))
        expectEqual(try String(contentsOf: origin.appendingPathComponent("Default/Bookmarks")), "fixture bookmarks")
        let backups = try FileManager.default.contentsOfDirectory(at: DataCopyPaths.backupRoot(home: root), includingPropertiesForKeys: nil)
        expectTrue(backups.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("old-0/previous").path) })
        _ = try CloneBuilder(commands: commands).build(source: source, destination: destination, dataHome: root)
        expectEqual(try String(contentsOf: target.appendingPathComponent("Default/Bookmarks")), "clone changed")
    }
    func testBrowserDataCopyRejectsAbsoluteLinkToOriginal() throws {
        let source = try browserFixture()
        let origin = root.appendingPathComponent("Browser Data")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: origin.appendingPathComponent("Local State"))
        try FileManager.default.createSymbolicLink(at: origin.appendingPathComponent("alias"), withDestinationURL: origin.appendingPathComponent("Local State"))
        let locations = try DataCopyPaths.locations(source: source, mode: .chromiumProfile, entitlements: [:], home: root, browserOverride: origin)
        let tx = try DataCopyTransaction(source: source, appDestination: root.appendingPathComponent("Copy.app"), home: root)
        expectThrows(try tx.prepare(locations: locations, stagedApp: source.url, checkStopped: {}, progress: { _ in }))
    }
    func testBrowserProfileCannotPointToAnotherAppsDirectory() throws {
        let source = try browserFixture()
        let target = ChromiumProfile.directory(for: source, home: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source.url)
        expectThrows(try ChromiumProfile.ensureDirectory(for: source, home: root))
        let tx = try DataCopyTransaction(source: source, appDestination: root.appendingPathComponent("Copy.app"), home: root)
        let outside = target.deletingLastPathComponent().appendingPathComponent("other-clone")
        expectThrows(try tx.prepare(locations: [DataCopyLocation(source: source.url, destination: outside, label: "wrong clone")], stagedApp: source.url, checkStopped: {}, progress: { _ in }))
    }
    func testProfileRuntimeEvidenceRequiresOwnDirectory() throws {
        let expected = root.appendingPathComponent("profile"), original = root.appendingPathComponent("original")
        try ChromiumProfile.validateOpenFiles("p123\nn\(expected.path)/Default/History\n", expected: expected, original: original)
        expectThrows(try ChromiumProfile.validateOpenFiles("p123\nn\(original.path)/Default/History\n", expected: expected, original: original))
        expectThrows(try ChromiumProfile.validateOpenFiles("n\(expected.path)-other/Default/History\n", expected: expected, original: original))
        expectThrows(try ChromiumProfile.validateOpenFiles("n\(expected.path)/Default/History\nn\(original.path)/Default/Cookies\n", expected: expected, original: original))
    }
    func testElectronRequiresMetadataBeforeCopy() throws {
        let source = try fixture()
        var info = source.bundleInfo; info["NSPrincipalClass"] = "AtomApplication"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: source.url.appendingPathComponent("Contents/Info.plist"))
        let electron = try AppDescriptor.inspect(source.url)
        expectEqual(try Compatibility.mode(for: electron, entitlements: [:]), .electronProfile)
        let commands = MockCommands(source: electron); commands.sandboxed = false
        expectThrows(try CloneBuilder(commands: commands).build(source: electron, destination: root.appendingPathComponent("Copy.app"), dataHome: root))
        expectFalse(commands.copied)
        expectEqual(try Compatibility.mode(for: electron, entitlements: ["com.apple.security.app-sandbox": true]), .existingSandbox)
    }

    func testEveryEmbeddedFrameworkVersionIsSigned() throws {
        let source = try fixture()
        let framework = source.url.appendingPathComponent("Contents/Frameworks/Example.framework")
        for version in ["A", "B"] {
            let resources = framework.appendingPathComponent("Versions/" + version + "/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.framework"], format: .xml, options: 0).write(to: resources.appendingPathComponent("Info.plist"))
        }
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "B")
        let commands = MockCommands(source: source)
        _ = try CloneBuilder(commands: commands).build(source: source, destination: root.appendingPathComponent("Copy.app"))
        expectEqual(commands.signedFrameworkVersions, ["A", "B"])
        expectEqual(commands.frameworkRequirements, Array(repeating: "=designated => identifier \"test.framework\"", count: 2))
    }

    func testRealSigningOfVersionedFrameworkInsideApplication() throws {
        let original = try fixture()
        let fm = FileManager.default, commands = SystemCommands()
        let binary = original.url.appendingPathComponent("Contents/MacOS/Chat")
        try fm.removeItem(at: binary)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
        let code = root.appendingPathComponent("framework.c")
        try Data("int fixture_value(void) { return 42; }\n".utf8).write(to: code)
        let library = root.appendingPathComponent("Example")
        try commands.checked("/usr/bin/clang", ["-dynamiclib", code.path, "-o", library.path])
        let framework = original.url.appendingPathComponent("Contents/Frameworks/Example.framework")
        for version in ["A", "B"] {
            let folder = framework.appendingPathComponent("Versions/" + version)
            try fm.createDirectory(at: folder.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            try fm.copyItem(at: library, to: folder.appendingPathComponent("Example"))
            let info = ["CFBundleIdentifier": "test.framework", "CFBundleExecutable": "Example", "CFBundleVersion": version, "CFBundlePackageType": "FMWK"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: folder.appendingPathComponent("Resources/Info.plist"))
        }
        for (path, target) in [("Versions/Current", "B"), ("Resources", "Versions/Current/Resources"), ("Example", "Versions/Current/Example")] {
            try fm.createSymbolicLink(atPath: framework.appendingPathComponent(path).path, withDestinationPath: target)
        }
        for version in ["A", "B"] {
            try commands.checked("/usr/bin/codesign", ["--force", "--sign", "-", "--bundle-version", version,
                "--requirements", "=designated => identifier \"test.framework\"", framework.path])
        }
        let entitlements = root.appendingPathComponent("source-entitlements.plist")
        try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.app-sandbox": true], format: .xml, options: 0).write(to: entitlements)
        try commands.checked("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", entitlements.path, original.url.path])
        let source = try AppDescriptor.inspect(original.url), destination = root.appendingPathComponent("Signed Clone.app")
        _ = try CloneBuilder().build(source: source, destination: destination, dataHome: root)
        try CloneBuilder().verify(destination)
        expectTrue(try CloneManifest.read(at: destination).isCurrent(for: source))
    }

    func electronFixture() throws -> AppDescriptor {
        let original = try fixture(id: "test.vendor.electron." + UUID().uuidString)
        var info = original.bundleInfo; info["NSPrincipalClass"] = "AtomApplication"
        info["ElectronAsarIntegrity"] = ["Resources/app.asar": ["algorithm": "SHA256", "hash": "fixture-integrity"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: original.url.appendingPathComponent("Contents/Info.plist"))
        let directory = original.url.appendingPathComponent("Contents/Resources/app")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["name": "test-electron", "productName": "Test Electron", "main": "main.js"]).write(to: directory.appendingPathComponent("package.json"))
        try Data("// untouched business code\n".utf8).write(to: directory.appendingPathComponent("main.js"))
        return try AppDescriptor.inspect(original.url)
    }
    func testElectronBuildKeepsBusinessCodeAndIsolationIdentity() throws {
        let source = try electronFixture(), commands = MockCommands(source: try AppDescriptor.inspect(root.appendingPathComponent("Original.app")))
        commands.sandboxed = false
        let clone = root.appendingPathComponent("Copy.app")
        let manifest = try CloneBuilder(commands: commands).build(source: source, destination: clone, dataHome: root)
        expectEqual(manifest.mode, .electronProfile)
        let config = try ElectronProfile.configuration(at: clone)
        expectEqual(config.packageName, "Test Electron")
        expectTrue(config.profile.path.hasPrefix(ElectronProfile.root(for: source, home: root).path + "/"))
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: clone.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
        expectEqual(info["CFBundleExecutable"] as? String, source.executable)
        expectEqual(info["CFBundleName"] as? String, source.bundleInfo["CFBundleName"] as? String)
        expectEqual(info["ElectronAsarIntegrity"] as? [String: [String: String]], source.bundleInfo["ElectronAsarIntegrity"] as? [String: [String: String]])
        expectEqual(try Data(contentsOf: clone.appendingPathComponent("Contents/Resources/app/main.js")), try Data(contentsOf: source.url.appendingPathComponent("Contents/Resources/app/main.js")))
        expectEqual((info["LSEnvironment"] as? [String: String])?["CFFIXED_USER_HOME"], config.home.path)
    }
    func testElectronLaunchEnvironmentAndLiteralArguments() throws {
        let source = try electronFixture()
        let executable = source.url.appendingPathComponent("Contents/MacOS/Chat")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$HOME\" \"$CFFIXED_USER_HOME\" \"$@\"\n".utf8).write(to: executable)
        let app = try AppDescriptor.inspect(source.url), commands = MockCommands(source: try AppDescriptor.inspect(source.url))
        commands.sandboxed = false
        let clone = root.appendingPathComponent("Copy.app")
        _ = try CloneBuilder(commands: commands).build(source: app, destination: clone, dataHome: root)
        let config = try ElectronProfile.configuration(at: clone)
        let injected = "$(touch /tmp/twinspace-do-not-create)"
        let outputFile = root.appendingPathComponent("launch-output")
        FileManager.default.createFile(atPath: outputFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputFile)
        let process = Process()
        process.executableURL = clone.appendingPathComponent("Contents/MacOS/" + source.executable)
        process.arguments = config.arguments(preserving: ["--user-data-dir", "/original", "--disk-cache-dir=/original-cache", injected, "a b"])
        process.environment = config.environment
        process.standardOutput = handle; process.standardError = handle
        try process.run(); process.waitUntilExit(); try handle.close()
        expectEqual(process.terminationStatus, 0)
        let output = try String(contentsOf: outputFile)
        let lines = output.split(separator: "\n").map(String.init)
        expectEqual(Array(lines.prefix(2)), [config.home.path, config.home.path])
        expectTrue(lines.contains("--user-data-dir=" + config.profile.path))
        expectTrue(lines.contains("--disk-cache-dir=" + config.cache.path))
        expectFalse(lines.contains("/original")); expectFalse(lines.contains("--disk-cache-dir=/original-cache"))
        expectTrue(lines.contains(injected)); expectTrue(lines.contains("a b"))
        expectTrue(config.temporary.path.hasPrefix(root.path + "/"))
    }
    func testElectronPackageReadsBoundedAsarMetadata() throws {
        let source = try fixture()
        let package = try JSONSerialization.data(withJSONObject: ["name": "plain-name", "productName": "ASAR Name"])
        let header = try JSONSerialization.data(withJSONObject: ["files": ["package.json": ["offset": "0", "size": package.count]]])
        func u32(_ value: Int) -> Data { var n = UInt32(value).littleEndian; return withUnsafeBytes(of: &n) { Data($0) } }
        var payload = u32(header.count) + header
        while payload.count % 4 != 0 { payload.append(0) }
        let pickle = u32(payload.count) + payload
        let path = source.url.appendingPathComponent("Contents/Resources/app.asar")
        try (u32(4) + u32(pickle.count) + pickle + package).write(to: path)
        expectEqual(try ElectronPackage.name(for: source), "ASAR Name")
        try (u32(4) + u32(100) + u32(96) + u32(Int(UInt32.max))).write(to: path)
        expectThrows(try ElectronPackage.name(for: source))
    }
    func testElectronConfigurationRejectsPathEscapesAndSymlinks() throws {
        let source = try electronFixture(), configuration = try ElectronLaunchConfiguration(source: try AppDescriptor.inspect(root.appendingPathComponent("Original.app")), home: root)
        var data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as! [String: Any]
        data["executable"] = "../../bin/sh"
        let bad = try JSONDecoder().decode(ElectronLaunchConfiguration.self, from: JSONSerialization.data(withJSONObject: data))
        expectThrows(try bad.validate())
        try FileManager.default.createDirectory(at: configuration.root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: configuration.root, withDestinationURL: source.url)
        expectThrows(try configuration.prepareDirectories())
    }
    func testElectronImportKeepsIndependentDataAndRebuildPreservesIt() throws {
        let source = try electronFixture(), commands = MockCommands(source: try AppDescriptor.inspect(root.appendingPathComponent("Original.app")))
        commands.sandboxed = false
        let original = ElectronProfile.defaultSource(for: source, home: root)!
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try Data("source fixture".utf8).write(to: original.appendingPathComponent("settings"))
        try FileManager.default.createSymbolicLink(atPath: original.appendingPathComponent("SingletonLock").path, withDestinationPath: "host-123")
        let clone = root.appendingPathComponent("Copy.app")
        _ = try CloneBuilder(commands: commands).build(source: source, destination: clone, dataPolicy: .includeExistingData, dataHome: root)
        let profile = try ElectronProfile.configuration(at: clone).profile
        expectEqual(try String(contentsOf: profile.appendingPathComponent("settings")), "source fixture")
        expectFalse(try FileManager.default.contentsOfDirectory(atPath: profile.path).contains("SingletonLock"))
        try Data("clone changed".utf8).write(to: profile.appendingPathComponent("settings"))
        _ = try CloneBuilder(commands: commands).build(source: source, destination: clone, dataHome: root)
        expectEqual(try String(contentsOf: profile.appendingPathComponent("settings")), "clone changed")
        expectEqual(try String(contentsOf: original.appendingPathComponent("settings")), "source fixture")
    }
    func removalFixture() throws -> (AppDescriptor, AppRecord, URL, Registry, URL) {
        let app = try fixture(), directory = root.appendingPathComponent("Applications")
        let record = AppRecord(app: app), registry = Registry(url: root.appendingPathComponent("config/apps.json"))
        let clone = try record.cloneURL(in: directory)
        _ = try CloneBuilder(commands: MockCommands(source: app)).build(source: app, destination: clone)
        try registry.save([record])
        return (app, record, directory, registry, clone)
    }
    func testRemovalDirectlyDeletesOnlyOwnedProgramAndRecord() throws {
        let (app, record, directory, registry, clone) = try removalFixture()
        let profile = root.appendingPathComponent("Library/Containers/\(app.cloneID)/Data/keep-account-data")
        try FileManager.default.createDirectory(at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("account fixture".utf8).write(to: profile)
        let result = try CloneRemoval.remove(record: record, directory: directory, registry: registry, isRunning: { _ in false })
        expectTrue(result.isEmpty); expectTrue(try registry.load().isEmpty)
        expectFalse(FileManager.default.fileExists(atPath: clone.path))
        expectTrue(FileManager.default.fileExists(atPath: app.url.path))
        expectEqual(try String(contentsOf: profile), "account fixture")
    }
    func testRemovalFailureAndRunningCopyKeepRecord() throws {
        let (_, record, directory, registry, clone) = try removalFixture()
        expectThrows(try CloneRemoval.remove(record: record, directory: directory, registry: registry, isRunning: { _ in true }))
        expectThrows(try CloneRemoval.remove(record: record, directory: directory, registry: registry, isRunning: { _ in false }, delete: { _ in throw DualError.message("fixture permission denied") }))
        expectTrue(FileManager.default.fileExists(atPath: clone.path)); expectEqual(try registry.load(), [record])
    }
    func testRemovalRejectsUnownedBundleAndHandlesAlreadyMissingCopy() throws {
        let (_, record, directory, registry, clone) = try removalFixture()
        try FileManager.default.removeItem(at: clone.appendingPathComponent(CloneManifest.relativePath))
        expectThrows(try CloneRemoval.remove(record: record, directory: directory, registry: registry, isRunning: { _ in false }))
        expectEqual(try registry.load(), [record]); expectTrue(FileManager.default.fileExists(atPath: clone.path))
        try FileManager.default.removeItem(at: clone)
        expectTrue(try CloneRemoval.remove(record: record, directory: directory, registry: registry, isRunning: { _ in false }).isEmpty)
    }

    func testSourceSignatureFailureExplainsResourceChanges() throws {
        let source = try fixture()
        let output = "\(source.url.path): a sealed resource is missing or invalid\nfile added: \(source.url.path)/Contents/Resources/Added.dylib\nfile modified: \(source.url.path)/Contents/Frameworks/Test.framework\nfile missing: \(source.url.path)/Contents/Resources/Missing\n"
        let error = SourceSignatureFailure(name: source.name, sourceURL: source.url, status: 1, output: output)
        expectEqual(error.resourceIssues.map(\.kind), ["新增资源", "资源已变更", "缺少资源"])
        expectEqual(error.resourceIssues.map(\.path), ["Contents/Resources/Added.dylib", "Contents/Frameworks/Test.framework", "Contents/Resources/Missing"])
        expectTrue(error.localizedDescription.contains("应用文件与签名记录不一致"))
        expectFalse(error.localizedDescription.contains(source.url.path))
        expectTrue(error.diagnostics.contains(output))
        expectTrue(error.diagnostics.contains("复制前"))
    }
    func testSourceSignatureFailureDistinguishesUnsignedAndUnknownErrors() throws {
        let source = try fixture()
        let unsigned = SourceSignatureFailure(name: source.name, sourceURL: source.url, status: 1, output: "code object is not signed at all")
        expectTrue(unsigned.localizedDescription.contains("没有代码签名"))
        let unknown = SourceSignatureFailure(name: source.name, sourceURL: source.url, status: 1, output: "internal error")
        expectTrue(unknown.localizedDescription.contains("未通过签名完整性校验"))
        expectFalse(unknown.localizedDescription.contains("应用文件与签名记录不一致"))
        let many = SourceSignatureFailure(name: source.name, sourceURL: source.url, status: 1,
            output: (0..<9).map { "file modified: \(source.url.path)/Contents/Resources/file\($0)" }.joined(separator: "\n"))
        expectTrue(many.localizedDescription.contains("另有 3 项"))
        expectFalse(many.localizedDescription.contains("file8")); expectTrue(many.diagnostics.contains("file8"))
    }
    func testInvalidSourceStopsBeforeCopyAndKeepsExistingClone() throws {
        let source = try fixture(), destination = root.appendingPathComponent("Copies/Clone.app")
        let commands = MockCommands(source: source), builder = CloneBuilder(commands: MockCommands(source: source))
        _ = try builder.build(source: source, destination: destination)
        let before = try Data(contentsOf: destination.appendingPathComponent(CloneManifest.relativePath))
        commands.sourceVerificationOutput = "a sealed resource is missing or invalid\nfile modified: \(source.url.path)/Contents/Resources/entry"
        do {
            _ = try CloneBuilder(commands: commands).build(source: source, destination: destination)
            expectTrue(false)
        } catch is SourceSignatureFailure {} catch { expectTrue(false) }
        expectFalse(commands.copied); expectTrue(commands.entitlementsByPath.isEmpty)
        expectEqual(try Data(contentsOf: destination.appendingPathComponent(CloneManifest.relativePath)), before)
        expectFalse(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path).contains { $0.hasPrefix(".appdual-stage-") })
    }
    func testSignatureCheckCancellationIsNotReportedAsCorruptSource() throws {
        let source = try fixture(), commands = MockCommands(source: try AppDescriptor.inspect(root.appendingPathComponent("Original.app")))
        commands.cancelSourceVerification = true
        do { try SourceSignature.verify(source, commands: commands); expectTrue(false) }
        catch is CancellationError {} catch { expectTrue(false) }
        expectFalse(commands.copied)
    }
    func testRealSignedSourceReportsAddedModifiedAndMissingResources() throws {
        let original = try fixture(), fm = FileManager.default
        let binary = original.url.appendingPathComponent("Contents/MacOS/Chat")
        try fm.removeItem(at: binary); try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
        let modified = original.url.appendingPathComponent("Contents/Resources/modified.txt")
        let missing = original.url.appendingPathComponent("Contents/Resources/missing.txt")
        try Data("before".utf8).write(to: modified); try Data("before".utf8).write(to: missing)
        try SystemCommands().checked("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", original.url.path])
        let signed = try AppDescriptor.inspect(original.url)
        try SourceSignature.verify(signed)
        try Data("after".utf8).write(to: modified); try fm.removeItem(at: missing)
        try Data("extra".utf8).write(to: original.url.appendingPathComponent("Contents/Resources/added.txt"))
        do { try SourceSignature.verify(signed); expectTrue(false) }
        catch let error as SourceSignatureFailure {
            expectTrue(error.resourceIssues.contains { $0.kind == "新增资源" && $0.path == "Contents/Resources/added.txt" })
            expectTrue(error.resourceIssues.contains { $0.kind == "资源已变更" && $0.path == "Contents/Resources/modified.txt" })
            expectTrue(error.resourceIssues.contains { $0.kind == "缺少资源" && $0.path == "Contents/Resources/missing.txt" })
        }
        expectEqual(try String(contentsOf: modified), "after")
    }

}

private final class MockCommands: CommandRunning {
    let source: AppDescriptor
    var failSigning = false, failCopy = false, sandboxed = true, copied = false
    var entitlementsByPath: [String: [String: Any]] = [:]
    var signedFrameworkVersions: [String] = []
    var frameworkRequirements: [String] = []
    var afterCopy: (() throws -> Void)?
    var sourceVerificationOutput: String?
    var cancelSourceVerification = false
    init(source: AppDescriptor) { self.source = source }
    func run(_ executable: String, _ args: [String], timeout: TimeInterval) throws -> CommandResult {
        if args.contains("--verify"), args.last == source.url.path {
            if cancelSourceVerification { throw CancellationError() }
            if let output = sourceVerificationOutput { return CommandResult(status: 1, output: output) }
        }
        if executable.hasSuffix("ditto") {
            let destination = URL(fileURLWithPath: args.last!)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: args[args.count - 2]), to: destination); copied = true
            if failCopy { throw DualError.message("模拟复制中断") }
            try afterCopy?()
        }
        if args.contains("--sign") {
            if let index = args.firstIndex(of: "--bundle-version") { signedFrameworkVersions.append(args[index + 1]) }
            if let index = args.firstIndex(of: "--requirements") { frameworkRequirements.append(args[index + 1]) }
            if failSigning { return CommandResult(status: 1, output: "模拟签名失败") }
            if let index = args.firstIndex(of: "--entitlements") {
                entitlementsByPath[args.last!] = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: args[index+1])), format: nil) as? [String: Any]
            }
        }
        if args.contains("-d") {
            let e: [String: Any] = args.last == source.url.path
                ? ["com.apple.security.app-sandbox": sandboxed, "com.apple.application-identifier": "TEAM123456." + source.bundleID]
                : entitlementsByPath[args.last!] ?? [:]
            return CommandResult(status: 0, output: String(decoding: try PropertyListSerialization.data(fromPropertyList: e, format: .xml, options: 0), as: UTF8.self))
        }
        return CommandResult(status: 0, output: "")
    }
}

// Standalone checks work with Apple's Command Line Tools, which do not ship XCTest.
private var failures = [String]()
private func record(_ message: String, _ file: StaticString, _ line: UInt) { failures.append("\(file):\(line): \(message)") }
private func expectTrue(_ expression: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try !expression() { record("expected true", file, line) } } catch { record(error.localizedDescription, file, line) }
}
private func expectFalse(_ expression: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try expression() { record("expected false", file, line) } } catch { record(error.localizedDescription, file, line) }
}
private func expectEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { if try a() != b() { record("values differ", file, line) } } catch { record(error.localizedDescription, file, line) }
}
private func expectNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { if try a() == b() { record("values unexpectedly equal", file, line) } } catch { record(error.localizedDescription, file, line) }
}
private func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { if value != nil { record("expected nil", file, line) } }
private func expectLessThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if a >= b { record("expected less than", file, line) } }
private func expectThrows<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression(); record("expected error", file, line) } catch { }
}

let checks: [(String, (DualCoreTests) -> () throws -> Void)] = [
    ("testSourceSignatureFailureExplainsResourceChanges", DualCoreTests.testSourceSignatureFailureExplainsResourceChanges),
    ("testSourceSignatureFailureDistinguishesUnsignedAndUnknownErrors", DualCoreTests.testSourceSignatureFailureDistinguishesUnsignedAndUnknownErrors),
    ("testInvalidSourceStopsBeforeCopyAndKeepsExistingClone", DualCoreTests.testInvalidSourceStopsBeforeCopyAndKeepsExistingClone),
    ("testSignatureCheckCancellationIsNotReportedAsCorruptSource", DualCoreTests.testSignatureCheckCancellationIsNotReportedAsCorruptSource),
    ("testRealSignedSourceReportsAddedModifiedAndMissingResources", DualCoreTests.testRealSignedSourceReportsAddedModifiedAndMissingResources),
    ("testElectronBuildKeepsBusinessCodeAndIsolationIdentity", DualCoreTests.testElectronBuildKeepsBusinessCodeAndIsolationIdentity),
    ("testElectronLaunchEnvironmentAndLiteralArguments", DualCoreTests.testElectronLaunchEnvironmentAndLiteralArguments),
    ("testElectronPackageReadsBoundedAsarMetadata", DualCoreTests.testElectronPackageReadsBoundedAsarMetadata),
    ("testElectronConfigurationRejectsPathEscapesAndSymlinks", DualCoreTests.testElectronConfigurationRejectsPathEscapesAndSymlinks),
    ("testElectronImportKeepsIndependentDataAndRebuildPreservesIt", DualCoreTests.testElectronImportKeepsIndependentDataAndRebuildPreservesIt),
    ("testRemovalDirectlyDeletesOnlyOwnedProgramAndRecord", DualCoreTests.testRemovalDirectlyDeletesOnlyOwnedProgramAndRecord),
    ("testRemovalFailureAndRunningCopyKeepRecord", DualCoreTests.testRemovalFailureAndRunningCopyKeepRecord),
    ("testRemovalRejectsUnownedBundleAndHandlesAlreadyMissingCopy", DualCoreTests.testRemovalRejectsUnownedBundleAndHandlesAlreadyMissingCopy),
    ("testRealSigningOfVersionedFrameworkInsideApplication", DualCoreTests.testRealSigningOfVersionedFrameworkInsideApplication),
    ("testEveryEmbeddedFrameworkVersionIsSigned", DualCoreTests.testEveryEmbeddedFrameworkVersionIsSigned),
    ("testInterruptedBrowserImportRecoversProfileAndProgram", DualCoreTests.testInterruptedBrowserImportRecoversProfileAndProgram),
    ("testUnknownChromiumBrandUsesCapabilityWithoutForcingSandbox", DualCoreTests.testUnknownChromiumBrandUsesCapabilityWithoutForcingSandbox),
    ("testChromiumWithoutCapabilityIsRejectedBeforeCopy", DualCoreTests.testChromiumWithoutCapabilityIsRejectedBeforeCopy),
    ("testBrowserDataCopyExcludesLocksAndPreservesIndependentData", DualCoreTests.testBrowserDataCopyExcludesLocksAndPreservesIndependentData),
    ("testBrowserDataCopyRejectsAbsoluteLinkToOriginal", DualCoreTests.testBrowserDataCopyRejectsAbsoluteLinkToOriginal),
    ("testBrowserProfileCannotPointToAnotherAppsDirectory", DualCoreTests.testBrowserProfileCannotPointToAnotherAppsDirectory),
    ("testProfileRuntimeEvidenceRequiresOwnDirectory", DualCoreTests.testProfileRuntimeEvidenceRequiresOwnDirectory),
    ("testElectronRequiresMetadataBeforeCopy", DualCoreTests.testElectronRequiresMetadataBeforeCopy),
    ("testDiscoveryReadsIdentityAndExecutable", DualCoreTests.testDiscoveryReadsIdentityAndExecutable),
    ("testDiscoveryRejectsMissingBundleAndClone", DualCoreTests.testDiscoveryRejectsMissingBundleAndClone),
    ("testDiscoveryRejectsExecutableTraversal", DualCoreTests.testDiscoveryRejectsExecutableTraversal),
    ("testBuildChangeInvalidatesManifestButKeepsCloneIdentity", DualCoreTests.testBuildChangeInvalidatesManifestButKeepsCloneIdentity),
    ("testRegistryRoundTripAndInvalidPathRejection", DualCoreTests.testRegistryRoundTripAndInvalidPathRejection),
    ("testEntitlementsKeepSandboxAndUseDistinctGroups", DualCoreTests.testEntitlementsKeepSandboxAndUseDistinctGroups),
    ("testAtomicExchangeLeavesOldBundleAtStagingPath", DualCoreTests.testAtomicExchangeLeavesOldBundleAtStagingPath),
    ("testAtomicInstallFailureDoesNotRemoveOldBundle", DualCoreTests.testAtomicInstallFailureDoesNotRemoveOldBundle),
    ("testBuildFailurePreservesOldBundleAndCleansStage", DualCoreTests.testBuildFailurePreservesOldBundleAndCleansStage),
    ("testCopyInterruptionLeavesNoPartialInstalledBundle", DualCoreTests.testCopyInterruptionLeavesNoPartialInstalledBundle),
    ("testBuildRejectsRunningAndUnownedDestination", DualCoreTests.testBuildRejectsRunningAndUnownedDestination),
    ("testBuildRefusesNonSandboxedSource", DualCoreTests.testBuildRefusesNonSandboxedSource),
    ("testDBXUsesSeparateSandboxAndExplicitDataDirectory", DualCoreTests.testDBXUsesSeparateSandboxAndExplicitDataDirectory),
    ("testUnverifiedDBXVersionIsNotSilentlyEnabled", DualCoreTests.testUnverifiedDBXVersionIsNotSilentlyEnabled),
    ("testExistingWeChatManifestDoesNotRequireRebuild", DualCoreTests.testExistingWeChatManifestDoesNotRequireRebuild),
    ("testSourceUpdateDuringCopyCancelsInstall", DualCoreTests.testSourceUpdateDuringCopyCancelsInstall),
    ("testOpeningCopyDuringBuildPreventsReplacement", DualCoreTests.testOpeningCopyDuringBuildPreventsReplacement),
    ("testExternalResourceSymlinkIsRejected", DualCoreTests.testExternalResourceSymlinkIsRejected),
    ("testCloneIconHasAllRequiredRepresentations", DualCoreTests.testCloneIconHasAllRequiredRepresentations),
    ("testProcessArgumentsAreNotInterpretedByShell", DualCoreTests.testProcessArgumentsAreNotInterpretedByShell),
    ("testProcessTimeoutTerminatesChild", DualCoreTests.testProcessTimeoutTerminatesChild),
    ("testDataCopyCreatesIndependentFilesAndKeepsBackup", DualCoreTests.testDataCopyCreatesIndependentFilesAndKeepsBackup),
    ("testInterruptedDataCommitRecoversBothDataAndProgram", DualCoreTests.testInterruptedDataCommitRecoversBothDataAndProgram),
    ("testDataCopyRejectsDestinationOutsideClone", DualCoreTests.testDataCopyRejectsDestinationOutsideClone),
    ("testChangedSourceAfterSnapshotPreventsCommit", DualCoreTests.testChangedSourceAfterSnapshotPreventsCommit),
    ("testDataCopyRejectsSymlinkDestination", DualCoreTests.testDataCopyRejectsSymlinkDestination),
    ("testDataCopyRejectsSourceContainingItsBackupDirectory", DualCoreTests.testDataCopyRejectsSourceContainingItsBackupDirectory),
    ("testGroupCopyPreservesContainerManagerMetadata", DualCoreTests.testGroupCopyPreservesContainerManagerMetadata),
    ("testApplicationOnlyBuildPreservesData", DualCoreTests.testApplicationOnlyBuildPreservesData),
    ("testCopyDataRequiresOriginalToBeStopped", DualCoreTests.testCopyDataRequiresOriginalToBeStopped),
    ("testDBXDataAndLocalKeyUseNonOverlappingDestinations", DualCoreTests.testDBXDataAndLocalKeyUseNonOverlappingDestinations),
    ("testBuilderIncludesDataEndToEnd", DualCoreTests.testBuilderIncludesDataEndToEnd),
    ("testHeadlessAppWorkerIsDetected", DualCoreTests.testHeadlessAppWorkerIsDetected),
    ("testFreshBundleURLDoesNotBecomeAFalseLocationMismatch", DualCoreTests.testFreshBundleURLDoesNotBecomeAFalseLocationMismatch),
    ("testLaunchRecognizesSymlinkAlias", DualCoreTests.testLaunchRecognizesSymlinkAlias),
    ("testLaunchCrashIsNotReportedAsAnotherCopy", DualCoreTests.testLaunchCrashIsNotReportedAsAnotherCopy),
    ("testLaunchWithoutIdentityHasItsOwnFailure", DualCoreTests.testLaunchWithoutIdentityHasItsOwnFailure),
    ("testGenuineOtherApplicationIsStillRejected", DualCoreTests.testGenuineOtherApplicationIsStillRejected),
    ("testInternalAndLocalizedNamesArePreservedForHelpers", DualCoreTests.testInternalAndLocalizedNamesArePreservedForHelpers),
    ("testElectronIPCNamespaceKeepsExistingCloneDataGroups", DualCoreTests.testElectronIPCNamespaceKeepsExistingCloneDataGroups)
]

for (name, run) in checks {
    let suite = DualCoreTests(); let previous = failures.count
    do { try suite.setUpWithError(); try run(suite)() } catch { failures.append("\(name): \(error.localizedDescription)") }
    do { try suite.tearDownWithError() } catch { failures.append("cleanup: \(error.localizedDescription)") }
    print("\(failures.count == previous ? "PASS" : "FAIL") \(name)")
}
for failure in failures { fputs(failure + "\n", stderr) }
print("\(checks.count) checks, \(failures.count) failures")
exit(failures.isEmpty ? 0 : 1)
