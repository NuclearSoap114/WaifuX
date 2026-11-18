import AppKit
import SwiftUI

struct MivoriFileOrganizerView: View {
    @Environment(\.mainTopBarContentPadding) private var topPadding
    @State private var folder: URL?
    @State private var files: [MivoriOrganizerFile] = []
    @State private var selectedNames: Set<String> = []
    @State private var suggestions: [MivoriOrganizerSuggestion] = []
    @State private var source: String?
    @State private var isDemo = false
    @State private var canUndo = false
    @State private var isWorking = false
    @State private var showsReview = false
    @State private var status = ""
    @State private var hasError = false

    private let store = MivoriOrganizerStore.shared

    private var checkedFiles: [MivoriOrganizerFile] { files.filter { selectedNames.contains($0.name) } }
    private var checkedSuggestions: [MivoriOrganizerSuggestion] { suggestions.filter(\.selected) }
    private var hasInvalidTargets: Bool {
        checkedSuggestions.contains { !MivoriOrganizerStore.validFolder($0.folder) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            title
            Divider()
            if folder == nil {
                ContentUnavailableView("选择要整理的文件夹", systemImage: "folder",
                                       description: Text("仅整理所选文件夹中的文件。移动前可勾选文件并修改目标。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !suggestions.isEmpty {
                suggestionList
            } else if files.isEmpty {
                ContentUnavailableView("没有可整理的文件", systemImage: "doc",
                                       description: Text("只列出文件夹顶层的普通文件。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileList
            }
            Divider()
            footer
        }
        .padding(24)
        .padding(.top, topPadding)
        .sheet(isPresented: $showsReview) {
            if let folder {
                MivoriOrganizerReview(folder: folder, files: checkedFiles) { plan in
                    suggestions = plan
                    source = "DeepSeek API · \(MivoriDeepSeek.model)"
                    status = "已收到 \(plan.count) 项建议。请确认目标后应用。"
                    hasError = false
                }
            }
        }
    }

    private var title: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("文件整理")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let folder {
                    Label(isDemo ? "Mivori 离线示例文件夹" : folder.path, systemImage: "folder")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(isDemo ? "文件位于独立临时目录。" : folder.path)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button {
                    chooseFolder()
                } label: {
                    Label("选择文件夹…", systemImage: "folder.badge.plus")
                }
                .accessibilityIdentifier("mivori.organizer.chooseFolder")
                Button("离线演示", action: openDemo)
                    .accessibilityIdentifier("mivori.organizer.demo")
                if let folder {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .help("在 Finder 中显示所选文件夹")
                    .accessibilityLabel("在 Finder 中显示所选文件夹")
                }
            }
            .disabled(isWorking)
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("文件")
                    .font(.headline)
                Spacer()
                Text("已选 \(selectedNames.count) 项")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button(files.count > MivoriOrganizerStore.maxRequestCount
                       ? "选前 \(MivoriOrganizerStore.maxRequestCount) 项" : "全选") {
                    selectedNames = Set(files.prefix(MivoriOrganizerStore.maxRequestCount).map(\.name))
                }
                .disabled(isWorking)
                Button("取消全选") { selectedNames.removeAll() }
                    .disabled(selectedNames.isEmpty || isWorking)
            }
            List(files) { file in
                HStack(spacing: 10) {
                    Toggle(isOn: selection(for: file)) {
                        Label(file.name, systemImage: "doc")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(isWorking || (!selectedNames.contains(file.name)
                        && selectedNames.count >= MivoriOrganizerStore.maxRequestCount))
                    Spacer()
                    Text(file.format.isEmpty ? "无扩展名" : file.format.uppercased())
                        .foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 76, alignment: .trailing)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
            .accessibilityIdentifier("mivori.organizer.files")
            if files.count == MivoriOrganizerStore.maxListedCount {
                Text("最多列出 \(MivoriOrganizerStore.maxListedCount) 个文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("整理建议").font(.headline)
                if let source {
                    Text(source)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("mivori.organizer.suggestionSource")
                }
                Spacer()
                Button("返回文件列表") {
                    suggestions.removeAll()
                    source = nil
                    status = ""
                }
                .disabled(isWorking)
            }
            Text("移动到所选文件夹内的「\(MivoriOrganizerStore.destinationName)」。可直接编辑每项的目标子文件夹。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            List($suggestions) { $suggestion in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Toggle(isOn: $suggestion.selected) {
                            Text(suggestion.file.name).lineLimit(1).truncationMode(.middle)
                        }
                        .toggleStyle(.checkbox)
                        Spacer(minLength: 12)
                        TextField("目标子文件夹", text: $suggestion.folder)
                            .textFieldStyle(.roundedBorder)
                            .frame(idealWidth: 185, maxWidth: 220)
                            .accessibilityLabel("目标子文件夹：\(suggestion.file.name)")
                    }
                    Text(verbatim: suggestion.reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 19)
                }
                .padding(.vertical, 5)
            }
            .listStyle(.inset)
            .disabled(isWorking)
            .accessibilityIdentifier("mivori.organizer.suggestions")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasInvalidTargets {
                Label("目标须为单个文件夹名称，不能以点开头或含路径分隔符。", systemImage: "exclamationmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            } else if !status.isEmpty {
                Label(status, systemImage: hasError ? "exclamationmark.circle" : "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(hasError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("mivori.organizer.status")
            }
            HStack(spacing: 8) {
                if let folder {
                    Button("刷新") { run { try await load(folder, demo: isDemo) } }
                        .disabled(isWorking)
                }
                if isWorking { ProgressView().controlSize(.small) }
                Spacer(minLength: 8)
                Button("撤销最近一批", action: undo)
                    .disabled(!canUndo || isWorking)
                    .accessibilityIdentifier("mivori.organizer.undo")
                if suggestions.isEmpty {
                    if isDemo && !checkedFiles.isEmpty {
                        Button("生成离线建议", action: repeatDemo)
                    }
                    Button("预览发送内容…") { showsReview = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(checkedFiles.isEmpty || isWorking)
                        .accessibilityIdentifier("mivori.organizer.preview")
                } else {
                    Button("应用勾选建议", action: apply)
                        .buttonStyle(.borderedProminent)
                        .disabled(checkedSuggestions.isEmpty || hasInvalidTargets || isWorking)
                        .accessibilityIdentifier("mivori.organizer.apply")
                }
            }
        }
    }

    private func selection(for file: MivoriOrganizerFile) -> Binding<Bool> {
        Binding {
            selectedNames.contains(file.name)
        } set: { checked in
            if checked && selectedNames.count < MivoriOrganizerStore.maxRequestCount {
                selectedNames.insert(file.name)
            } else if !checked {
                selectedNames.remove(file.name)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择要整理的文件夹"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            run { try await load(url, demo: false) }
        }
    }

    private func load(_ url: URL, demo: Bool) async throws {
        let listed = try await store.scan(url)
        let hasUndo = try await store.hasUndo(in: url)
        folder = url
        isDemo = demo
        canUndo = hasUndo
        files = listed
        selectedNames = demo ? Set(listed.prefix(MivoriOrganizerStore.maxRequestCount).map(\.name)) : []
        suggestions.removeAll()
        source = nil
        status = ""
    }

    private func openDemo() {
        run {
            let demo = try await store.demoFolder()
            try await load(demo, demo: true)
            try await makeDemo(in: demo)
        }
    }

    private func repeatDemo() {
        guard let folder else { return }
        run { try await makeDemo(in: folder) }
    }

    private func makeDemo(in folder: URL) async throws {
        let input = try await store.prepare(checkedFiles, in: folder, includeText: false)
        suggestions = MivoriOrganizerStore.example(input)
        source = "离线示例 · 未调用 DeepSeek API"
        status = "已生成 \(suggestions.count) 项示例建议。请确认目标后应用。"
    }

    private func apply() {
        guard let folder else { return }
        let plan = suggestions
        run {
            let result = try await store.apply(plan, in: folder)
            try await load(folder, demo: isDemo)
            showResult(result, verb: "已移动")
        }
    }

    private func undo() {
        guard let folder else { return }
        run {
            let result = try await store.undo(in: folder)
            try await load(folder, demo: isDemo)
            showResult(result, verb: "已还原")
        }
    }

    private func showResult(_ result: MivoriOrganizerStore.Result, verb: String) {
        status = "\(verb) \(result.count) 个文件。"
        hasError = !result.unresolved.isEmpty
        if hasError {
            let preview = result.unresolved.prefix(3).joined(separator: "、")
            status += " \(result.unresolved.count) 项未处理（文件可能已变化或目标被占用）：\(preview)"
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        status = ""
        hasError = false
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await operation()
            } catch {
                hasError = true
                status = error.localizedDescription
            }
        }
    }
}

private struct MivoriOrganizerReview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var includesText = false
    @State private var input: [MivoriOrganizerInput] = []
    @State private var preparedMode: Bool?
    @State private var choice: String?
    @State private var message = ""
    @State private var isLoading = true
    @State private var isSending = false
    @State private var sending: Task<Void, Never>?

    let folder: URL
    let files: [MivoriOrganizerFile]
    let receive: ([MivoriOrganizerSuggestion]) -> Void

    private var current: MivoriOrganizerInput? { input.first { $0.id == choice } ?? input.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("预览发送内容")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("将通过 HTTPS 发送到 \(MivoriDeepSeek.requestHost)。仅发送 \(files.count) 个勾选文件的名称、格式和大小，以及下方允许的摘要。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("包含支持格式的正文摘要（每个文件最多 \(MivoriFileExcerpt.maxCharacters) 字）", isOn: $includesText)
                .toggleStyle(.checkbox)
                .disabled(isSending)
                .accessibilityIdentifier("mivori.organizer.includeText")
            Divider()
            if isLoading {
                ProgressView("正在准备预览…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if preparedMode == includesText, let current {
                Picker("文件", selection: $choice) {
                    ForEach(input) { file in
                        Text(verbatim: file.file.name).tag(Optional(file.id))
                    }
                }
                Text("\(current.file.format.isEmpty ? "无扩展名" : current.file.format.uppercased()) · \(current.file.size) 字节")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(verbatim: current.excerpt ?? (includesText ? "此文件没有可发送的正文摘要。" : "仅发送上方文件信息。"))
                        .font(current.excerpt == nil ? .body : .system(.body, design: .monospaced))
                        .foregroundStyle(current.excerpt == nil ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("mivori.organizer.excerpt")
            } else {
                Spacer(minLength: 24)
            }
            if !message.isEmpty {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .font(.subheadline)
            }
            HStack {
                if isSending { ProgressView("正在获取建议…").controlSize(.small) }
                Spacer()
                Button("取消") {
                    sending?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("发送至 DeepSeek", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(preparedMode != includesText || input.count != files.count || isLoading || isSending)
                    .accessibilityIdentifier("mivori.organizer.send")
            }
        }
        .padding(22)
        .frame(minWidth: 520, idealWidth: 545, minHeight: 360, idealHeight: 400)
        .interactiveDismissDisabled(isSending)
        .onDisappear { sending?.cancel() }
        .task(id: includesText) {
            let mode = includesText
            isLoading = true
            input = []
            preparedMode = nil
            message = ""
            do {
                let prepared = try await MivoriOrganizerStore.shared.prepare(files, in: folder, includeText: mode)
                try Task.checkCancellation()
                input = prepared
                preparedMode = mode
                choice = prepared.first?.id
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func send() {
        guard preparedMode == includesText, input.count == files.count, !isSending, !isLoading else { return }
        let prepared = input
        isSending = true
        message = ""
        sending = Task { @MainActor in
            defer { isSending = false }
            do {
                let plan = try await MivoriDeepSeek.suggestions(prepared)
                try Task.checkCancellation()
                receive(plan)
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
