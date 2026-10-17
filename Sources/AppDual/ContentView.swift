import SwiftUI
import AppKit
import DualCore

private let accent = Color(red: 0.10, green: 0.47, blue: 0.43)
// Explicitly select the macOS 13 property wrapper when building with SDKs that also export a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ViewState private var showCopyOptions = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    header
                    if let record = model.selected {
                        detail(record)
                    } else {
                        VStack(spacing: 18) {
                            Image(systemName: "square.on.square.dashed").font(.system(size: 50)).foregroundStyle(accent)
                            Text("从选择一个应用开始").font(.title2.weight(.semibold))
                            Text("每个应用保留一个副本，随时在左侧切换。")
                                .foregroundStyle(.secondary)
                            Button("选择应用…", action: model.chooseApp).buttonStyle(.borderedProminent).tint(accent)
                        }.frame(maxWidth: .infinity, minHeight: 330)
                    }
                    footer
                }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(accent)
        .sheet(isPresented: $showCopyOptions) {
            if let source = model.source {
                CopyOptionsView(model: model, source: source) { policy, directory in
                    showCopyOptions = false
                    model.openClone(repair: true, dataPolicy: policy, sourceDataDirectory: directory)
                }
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
            Button("复制诊断") { model.copyDiagnostics(); model.errorText = nil }
            Button("知道了", role: .cancel) { model.errorText = nil }
        } message: { Text(model.errorText ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.on.square.fill").font(.system(size: 23)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("TwinSpace").font(.headline)
                    Text("APP DUPLICATOR").font(.system(size: 9, weight: .medium, design: .rounded)).tracking(2).foregroundStyle(.secondary)
                }
            }.padding(22)
            HStack {
                Text("我的应用").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.records.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 22).padding(.bottom, 8)
            List(selection: $model.selectedID) {
                ForEach(model.records) { record in
                    HStack(spacing: 11) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: record.sourcePath))
                            .resizable().frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text("原版 + 1 个副本").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8).tag(record.id)
                }
            }.listStyle(.sidebar).disabled(model.busy)
            VStack(spacing: 10) {
                Button(action: model.chooseApp) {
                    Label("添加应用…", systemImage: "plus").frame(maxWidth: .infinity)
                }.controlSize(.large).disabled(model.busy)
                if model.selected != nil {
                    Button("删除副本并移除", action: model.removeSelected)
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).disabled(model.busy)
                        .help("直接删除对应副本程序并移除列表记录，不进入废纸篓；原版和所有账号数据保留。")
                }
            }.padding(18)
            Divider()
            Text("\(AppModel.appVersion) · 测试版").font(.caption2).foregroundStyle(.tertiary).padding(18)
        }.background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("给常用应用，多一个空间。")
                .font(.system(size: 26, weight: .semibold))
            Text("选择原版应用，创建第二个独立使用空间。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }.padding(.top, 6)
    }

    private func detail(_ record: AppRecord) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(record.name).font(.title3.weight(.semibold))
                Spacer()
                Text(model.source.map { "版本 \($0.version)" } ?? "未找到原版")
                    .font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(accent.opacity(0.08), in: Capsule()).foregroundStyle(accent)
            }
            HStack(spacing: 16) {
                appCard(record: record, clone: false)
                Image(systemName: "arrow.right").font(.system(size: 14, weight: .medium)).foregroundStyle(.tertiary)
                appCard(record: record, clone: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    if model.busy {
                        ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 14, height: 16)
                    } else {
                        Image(systemName: model.outdated ? "arrow.triangle.2.circlepath" : "circle.inset.filled")
                            .foregroundStyle(model.outdated ? Color.orange : accent).font(.system(size: 13))
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.status).font(.system(size: 12, weight: .medium))
                        Text(model.busy ? "首次创建需要复制完整资源，请保持应用打开。" : "副本图标带蓝色“2”角标，账号需在副本中单独登录。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if model.busy { ProgressView(value: model.fraction).tint(accent) }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 12) {
                Button(action: {
                    if !model.exists || model.outdated { showCopyOptions = true }
                    else { model.openClone() }
                }) {
                    Label(model.exists ? "打开第二个\(record.name)" : "创建并打开副本", systemImage: "arrow.up.forward.app")
                        .frame(minWidth: 150)
                }.buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
                    .disabled(model.busy || model.source == nil)
                Button("重建副本…") { showCopyOptions = true }
                    .controlSize(.large).disabled(model.busy || model.source == nil || !model.exists)
                    .help("选择仅重建程序，或同时复制原版现有数据。")
                Spacer()
                if model.busy { Button("取消", action: model.cancel).buttonStyle(.link) }
            }
            HStack {
                Button("重试启动", action: model.retry).buttonStyle(.link).disabled(model.busy || !model.exists)
                Button("数据备份") {
                    NSWorkspace.shared.open(DataCopyPaths.backupRoot())
                }.buttonStyle(.link).disabled(!FileManager.default.fileExists(atPath: DataCopyPaths.backupRoot().path))
                Spacer()
                Button("在访达中显示副本") {
                    if let url = model.cloneURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }.buttonStyle(.link).disabled(!model.exists)
            }.font(.caption)
        }
    }

    private func appCard(record: AppRecord, clone: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: icon(record: record, clone: clone)).resizable().frame(width: 62, height: 62)
                    if clone && !model.exists {
                        Text("2").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 25, height: 25).background(Color.blue, in: Circle())
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    }
                }
                Spacer()
                Text(clone ? "02" : "01").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(clone ? "\(record.name)副本" : "原版\(record.name)").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill((clone ? model.cloneRunning : model.sourceRunning) ? accent : Color.secondary.opacity(0.35)).frame(width: 5, height: 5)
                    Text((clone ? model.cloneRunning : model.sourceRunning) ? "正在运行" : "未运行")
                }.font(.caption).foregroundStyle(.secondary)
            }
            if clone {
                Text("独立登录 · 角标区分").font(.caption).foregroundStyle(.secondary).frame(height: 24)
            } else {
                Button("打开原版", action: model.openOriginal)
                    .disabled(model.busy || model.source == nil).frame(height: 24)
            }
        }.padding(19).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.07)))
    }

    private func icon(record: AppRecord, clone: Bool) -> NSImage {
        if clone, let url = model.cloneURL,
           let image = NSImage(contentsOf: url.appendingPathComponent("Contents/Resources/AppDualClone.icns")) { return image }
        return NSWorkspace.shared.icon(forFile: record.sourcePath)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack {
                Text("仅复制程序时保留已有数据；替换数据前自动备份。")
                Spacer()
                Button("复制诊断", action: model.copyDiagnostics).buttonStyle(.link)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
