import SwiftUI

struct MivoriDeepSeekSettingsView: View {
    @State private var key = ""
    @State private var hasSaved = false
    @State private var isTesting = false
    @State private var status = ""
    @State private var hasError = false
    @State private var asksToClear = false
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                LabeledContent("服务") {
                    Text(MivoriDeepSeek.requestHost).textSelection(.enabled)
                }
                LabeledContent("模型", value: MivoriDeepSeek.model)
            } header: {
                Text("DeepSeek")
            }
            Section {
                SecureField(hasSaved ? "输入新密钥以替换" : "输入 API 密钥", text: $key)
                    .accessibilityLabel("DeepSeek API 密钥")
                    .accessibilityIdentifier("mivori.deepseek.key")
                    .disabled(isTesting)
                HStack {
                    Button("保存密钥", action: save)
                        .disabled(key.isEmpty || isTesting)
                        .accessibilityIdentifier("mivori.deepseek.save")
                    Button("测试连接", action: test)
                        .disabled((key.isEmpty && !hasSaved) || isTesting)
                        .accessibilityIdentifier("mivori.deepseek.test")
                    if isTesting { ProgressView().controlSize(.small) }
                    Spacer()
                    if hasSaved {
                        Button("清除密钥", role: .destructive) { asksToClear = true }
                            .disabled(isTesting)
                            .accessibilityIdentifier("mivori.deepseek.clear")
                    }
                }
                if !status.isEmpty {
                    Label(status, systemImage: hasError ? "exclamationmark.circle" : "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(hasError ? Color.red : Color.secondary)
                        .accessibilityIdentifier("mivori.deepseek.status")
                }
            } header: {
                Text(hasSaved ? "Mivori 钥匙串 · 已保存密钥" : "Mivori 钥匙串")
            } footer: {
                Text("测试连接只发送一条测试消息。整理文件时，可先预览实际发送的内容。")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("清除保存的 DeepSeek 密钥？", isPresented: $asksToClear, titleVisibility: .visible) {
            Button("清除密钥", role: .destructive, action: clear)
            Button("取消", role: .cancel) {}
        }
        .onAppear(perform: reload)
        .onDisappear {
            testTask?.cancel()
            key = ""
        }
    }

    private func reload() {
        do {
            hasSaved = try MivoriDeepSeek.savedKey() != nil
        } catch {
            show(error)
        }
    }

    private func save() {
        do {
            try MivoriDeepSeek.saveKey(key)
            key = ""
            hasSaved = true
            hasError = false
            status = "已保存到 Mivori 钥匙串。"
        } catch {
            show(error)
        }
    }

    private func clear() {
        do {
            try MivoriDeepSeek.clearKey()
            key = ""
            hasSaved = false
            hasError = false
            status = "已清除保存的密钥。"
        } catch {
            show(error)
        }
    }

    private func test() {
        let provided = key
        isTesting = true
        status = ""
        testTask = Task { @MainActor in
            defer { isTesting = false }
            do {
                try await MivoriDeepSeek.test(entered: provided)
                try Task.checkCancellation()
                hasError = false
                status = "连接成功。"
            } catch is CancellationError {
                return
            } catch {
                show(error)
            }
        }
    }

    private func show(_ error: Error) {
        hasError = true
        status = error.localizedDescription
    }
}
