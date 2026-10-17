import SwiftUI
import DualCore

struct SourceSignatureConfirmationView: View {
    @ObservedObject var model: AppModel
    let confirmation: SourceSignatureConfirmation

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("原版完整性未通过", systemImage: "exclamationmark.triangle")
                .font(.title2.weight(.semibold)).foregroundStyle(.orange)
            Text("\(confirmation.source.name) · \(confirmation.source.version) (\(confirmation.source.build))")
                .font(.headline)
            Text(confirmation.source.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ScrollView {
                Text(confirmation.failure.summary)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.font(.system(size: 12)).frame(maxHeight: 160)
                .padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            Text("无法确认这些改动的来源。仅在你了解并信任这份应用时继续；副本可能仍无法启动或正常使用。")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text("本次方式：\(confirmation.dataPolicy.title)。确认仅用于本次创建；副本仍会重新签名并完成校验，原版应用保持原样。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("复制诊断", action: model.copyDiagnostics)
                Spacer()
                Button("取消", action: model.cancelSourceSignatureConfirmation).keyboardShortcut(.cancelAction)
                Button("确认后继续创建", action: model.confirmSourceSignatureAndContinue)
                    .buttonStyle(.borderedProminent).tint(.orange).disabled(model.busy)
            }
        }.padding(25).frame(width: 560)
    }
}
