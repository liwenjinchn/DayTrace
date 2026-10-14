import SwiftUI
import UniformTypeIdentifiers

struct BackupView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var password = ""
    @State private var exported: URL?
    @State private var importing = false
    @State private var pending: URL?
    @State private var confirm = false
    @State private var message = ""
    var body: some View {
        Form {
            Section {
                FeatureLabel(title: "为记录留一份备份", subtitle: "本地加密，由你选择保存位置", symbol: "lock.fill", color: .green)
            }
            Section { SecureField("至少 12 个字符", text: $password) }
                header: { Text("备份密码") } footer: { Text("密码无法找回，请妥善保管。") }
            Section {
            Button {
                do {
                    guard store.archiveHealthy, !store.recording, !store.processing, !store.preparingAudio, !store.automaticReviewRunner.busy, store.manualInFlight == 0 else { throw BackupFailure(message: "请等待所有处理结束") }
                    try ArchiveDisk.save(store.clips, to: store.root)
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("DayTrace-\(UUID()).daytrace")
                    try EncryptedBackup.export(root: store.root, destination: url, password: password)
                    exported = url; message = "加密备份已生成，请保存到你选择的位置。"
                } catch { store.error = error.localizedDescription }
            } label: { PrimaryActionLabel(title: "生成加密备份", symbol: "lock.doc") }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(password.count < 12)
            if let exported { ShareLink("保存加密备份", item: exported) }
            if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
            Button("选择加密备份恢复") { importing = true }.disabled(password.count < 12)
            } header: { Text("恢复已有备份") } footer: { Text("恢复会替换当前库，建议先导出当前库。") }
            Section {
                DisclosureGroup("备份与恢复说明") {
                    Text("包含本地音频、原文、引用、记忆和上下文，不含 API 密钥。使用 AES-GCM 加密和 PBKDF2 密码派生，不会自动上传。")
                    Text("恢复前验证密码、文件摘要与关联，失败不修改当前库。恢复后暂停自动外发授权；包含本机已主动删除记录的旧备份会被拒绝。")
                }.font(.subheadline)
            }
        }.navigationTitle("加密备份").navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            do { pending = try result.get(); confirm = true } catch { store.error = error.localizedDescription }
        }
        .confirmationDialog("验证通过后将替换当前本地库。建议先导出当前库。", isPresented: $confirm, titleVisibility: .visible) {
            Button("验证并恢复", role: .destructive) {
                guard let pending else { return }
                let access = pending.startAccessingSecurityScopedResource(); defer { if access { pending.stopAccessingSecurityScopedResource() } }
                do { try store.restoreBackup(pending, password: password); message = "恢复完成，自动授权已暂停；请核对内容后重新启用。" }
                catch { store.error = error.localizedDescription }
            }
        }
    }
}
