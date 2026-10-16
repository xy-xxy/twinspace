import SwiftUI
import AppKit
import DualCore

struct CopyOptionsView: View {
    @ObservedObject var model: AppModel
    let source: AppDescriptor
    let confirm: (DataCopyPolicy, URL?) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var policy: DataCopyPolicy = .applicationOnly
    @ViewState private var dataDirectory: URL?
    @ViewState private var nonSandboxElectron = false
    private var needsDirectory: Bool { Compatibility.isAdaptedDBX(source) || source.isChromiumBrowser || nonSandboxElectron }

    private var needsQuit: Bool {
        model.cloneRunning || (policy == .includeExistingData && model.sourceRunning)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            Text(model.exists ? "重建\(source.name)副本" : "创建\(source.name)副本").font(.title2.weight(.semibold))
            Picker("复制方式", selection: $policy) {
                ForEach(DataCopyPolicy.allCases) { option in Text(option.title).tag(option) }
            }.pickerStyle(.radioGroup)
            Group {
                if policy == .applicationOnly {
                    Text("只复制程序文件。已有副本的数据保持原样；首次使用从空白空间开始。")
                } else {
                    Text("把原版本机配置和记录复制一份，之后各自独立使用。若副本已有数据，会先保留备份，再替换。")
                    Text("外部数据库、外部文件和云端内容不会被克隆。系统钥匙串不在复制范围内，密码和登录状态可能需要重新验证。")
                    if needsDirectory {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("原版数据目录").font(.caption.weight(.semibold))
                            HStack {
                                Text(dataDirectory?.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") ?? "请选择原版实际使用的数据目录")
                                    .font(.caption).lineLimit(2).textSelection(.enabled)
                                Spacer()
                                Button("选择…") { chooseDirectory() }
                            }
                        }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                        if source.isChromiumBrowser {
                            Text("若原版使用了自定义目录，请重新选择。浏览器版本页中的“个人资料路径”的上一级目录即为数据目录。")
                        }
                    }
                }
            }.font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if needsQuit {
                Label(policy == .includeExistingData
                      ? "请先完全退出原版和副本，包括相关后台任务。"
                      : "请先从副本的菜单退出应用。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(policy == .includeExistingData ? "复制程序和数据" : "仅复制程序") {
                    confirm(policy, needsDirectory ? dataDirectory : nil)
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(needsQuit || (policy == .includeExistingData && needsDirectory && dataDirectory == nil))
            }
        }.padding(25).frame(width: 510).onAppear {
            if source.isElectron {
                nonSandboxElectron = (try? CloneBuilder().entitlements(at: source.url)["com.apple.security.app-sandbox"] as? Bool) != true
            }
            dataDirectory = Compatibility.isAdaptedDBX(source) ? DataCopyPaths.defaultDBXSource()
                : (nonSandboxElectron ? ElectronProfile.defaultSource(for: source) : ChromiumProfile.defaultSource(for: source))
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = source.isChromiumBrowser ? "选择包含 Local State 的浏览器数据目录"
            : (nonSandboxElectron ? "选择原版应用的资料目录" : "选择包含 dbx.db 的原版数据目录")
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.directoryURL = dataDirectory
        panel.begin { response in
            if response == .OK, let selected = panel.url { dataDirectory = selected }
        }
    }
}
