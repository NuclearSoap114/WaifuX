import CryptoKit
import Darwin
import Foundation

struct MivoriOrganizerFile: Identifiable, Sendable {
    struct Stamp: Codable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let seconds: Int
        let nanoseconds: Int

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            seconds = info.st_mtimespec.tv_sec
            nanoseconds = info.st_mtimespec.tv_nsec
        }

        func matches(_ info: stat) -> Bool {
            device == info.st_dev && inode == info.st_ino && size == info.st_size
                && seconds == info.st_mtimespec.tv_sec
                && abs(nanoseconds - info.st_mtimespec.tv_nsec) <= 1_000
        }
    }

    let name: String
    let stamp: Stamp
    let directoryDevice: Int32
    let directoryInode: UInt64

    func belongs(to attributes: stat) -> Bool {
        directoryDevice == attributes.st_dev && directoryInode == attributes.st_ino
    }

    var id: String { name }
    var format: String { (name as NSString).pathExtension.lowercased() }
    var size: Int64 { stamp.size }
}

struct MivoriOrganizerInput: Identifiable, Sendable {
    let id: String
    let file: MivoriOrganizerFile
    let excerpt: String?
}

struct MivoriOrganizerSuggestion: Identifiable, Sendable {
    let id: String
    let file: MivoriOrganizerFile
    var folder: String
    let reason: String
    var selected = true
}

enum MivoriOrganizerFailure: LocalizedError {
    case folderUnavailable
    case nameInvalid
    case fileChanged(String)
    case noSelection

    var errorDescription: String? {
        switch self {
        case .folderUnavailable: "无法访问所选文件夹或整理目录。"
        case .nameInvalid: "目标必须是一个文件夹名称。请避开隐藏名称、路径分隔符和控制字符。"
        case .fileChanged(let file): "文件已发生变化：\(file)。请刷新后重新预览。"
        case .noSelection: "请先勾选要处理的文件。"
        }
    }
}

actor MivoriOrganizerStore {
    static let shared = MivoriOrganizerStore()
    static let destinationName = "Mivori 整理"
    static let maxRequestCount = 24
    static let maxListedCount = 500

    struct Result: Sendable {
        var count = 0
        var unresolved: [String] = []
    }

    private struct Move: Codable {
        let source: String
        let category: String
        let destination: String
        let stamp: MivoriOrganizerFile.Stamp
    }

    private struct Journal: Codable {
        let device: Int32
        let inode: UInt64
        var batches: [[Move]]
    }

    private let journalDirectory: URL

    init(journalDirectory: URL? = nil) {
        self.journalDirectory = journalDirectory ?? URL.applicationSupportDirectory
            .appending(path: "Mivori", directoryHint: .isDirectory)
            .appending(path: "FileOrganizer", directoryHint: .isDirectory)
    }

    nonisolated static func validFolder(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 160 && !name.hasPrefix(".")
            && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            && name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)) == nil
    }

    func scan(_ folder: URL) throws -> [MivoriOrganizerFile] {
        try withRoot(folder) { root, rootInfo, path in
            let urls = try FileManager.default.contentsOfDirectory(
                at: path, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
            return urls.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }.lazy.compactMap { url in
                let name = url.lastPathComponent
                guard Self.validSource(name), let info = self.info(root, name), self.regular(info) else { return nil }
                return MivoriOrganizerFile(name: name, stamp: .init(info),
                                           directoryDevice: rootInfo.st_dev, directoryInode: rootInfo.st_ino)
            }.prefix(Self.maxListedCount).map { $0 }
        }
    }

    func prepare(_ files: [MivoriOrganizerFile], in folder: URL, includeText: Bool) throws -> [MivoriOrganizerInput] {
        guard !files.isEmpty, files.count <= Self.maxRequestCount else { throw MivoriOrganizerFailure.noSelection }
        return try withRoot(folder) { root, rootInfo, _ in
            try files.enumerated().map { index, file in
                try Task.checkCancellation()
                guard file.belongs(to: rootInfo), Self.validSource(file.name), let info = self.info(root, file.name),
                      self.regular(info), file.stamp.matches(info) else {
                    throw MivoriOrganizerFailure.fileChanged(file.name)
                }
                let content = includeText ? MivoriFileExcerpt.read(file, from: root) : nil
                return MivoriOrganizerInput(id: String(index + 1), file: file, excerpt: content)
            }
        }
    }

    func demoFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Mivori 离线演示", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let examples = [
            "Swift 课程笔记.txt": "课程记录\n整理 SwiftUI 状态管理与原生桌面窗口的实验步骤。",
            "产品计划.md": "# 项目计划\n本周完成桌面助手交互设计、录制和测试。",
            "词汇复习.csv": "词汇,释义\norganize,整理\npreview,预览",
            "示例.swift": "import Foundation\n\nprint(\"Mivori 离线文件整理示例\")"
        ]
        for (name, text) in examples {
            try Data(text.utf8).write(to: folder.appending(path: name), options: .withoutOverwriting)
        }
        return folder
    }

    func hasUndo(in folder: URL) throws -> Bool {
        try withRoot(folder) { _, stat, path in
            try !readJournal(path, stat).batches.isEmpty
        }
    }

    func apply(_ suggestions: [MivoriOrganizerSuggestion], in folder: URL) throws -> Result {
        let selected = suggestions.filter(\.selected)
        guard !selected.isEmpty else { throw MivoriOrganizerFailure.noSelection }
        guard selected.allSatisfy({ Self.validFolder($0.folder) && Self.validSource($0.file.name) }) else {
            throw MivoriOrganizerFailure.nameInvalid
        }
        return try withMutationLock(in: folder) { root, rootInfo, path in
            guard selected.allSatisfy({ $0.file.belongs(to: rootInfo) }) else {
                throw MivoriOrganizerFailure.folderUnavailable
            }
            var journal = try readJournal(path, rootInfo)
            let destination = try openDirectory(root, Self.destinationName, create: true)
            defer { close(destination) }
            journal.batches.append([])
            var result = Result()

            for item in selected {
                guard let source = self.info(root, item.file.name), self.regular(source),
                      item.file.stamp.matches(source),
                      self.sameDirectory(destination, under: root, named: Self.destinationName) else {
                    result.unresolved.append(item.file.name)
                    continue
                }
                do {
                    let category = try openDirectory(destination, item.folder, create: true)
                    defer { close(category) }
                    var applied = false
                    for suffix in 0..<10_000 {
                        let name = Self.name(item.file.name, collision: suffix)
                        guard let source = self.info(root, item.file.name), self.regular(source),
                              item.file.stamp.matches(source),
                              self.sameDirectory(destination, under: root, named: Self.destinationName),
                              self.sameDirectory(category, under: destination, named: item.folder) else { break }
                        if self.info(category, name) != nil { continue }
                        let move = Move(source: item.file.name, category: item.folder,
                                        destination: name, stamp: item.file.stamp)
                        journal.batches[journal.batches.count - 1].append(move)
                        try writeJournal(journal, path)
                        let renamed = renameatx_np(root, item.file.name, category, name, UInt32(RENAME_EXCL))
                        if renamed == 0 {
                            result.count += 1
                            applied = true
                            break
                        }
                        let code = errno
                        journal.batches[journal.batches.count - 1].removeLast()
                        try writeJournal(journal, path)
                        if code != EEXIST { break }
                    }
                    if !applied { result.unresolved.append(item.file.name) }
                } catch {
                    result.unresolved.append(item.file.name)
                }
            }
            if journal.batches.last?.isEmpty == true { journal.batches.removeLast() }
            try writeJournal(journal, path)
            return result
        }
    }

    func undo(in folder: URL) throws -> Result {
        try withMutationLock(in: folder) { root, rootInfo, path in
            var journal = try readJournal(path, rootInfo)
            guard let latest = journal.batches.popLast() else { return Result() }
            let destination = try? openDirectory(root, Self.destinationName, create: false)
            defer { if let destination { close(destination) } }
            var remaining = [Move]()
            var result = Result()

            for move in latest.reversed() {
                guard Self.validSource(move.source), Self.validSource(move.destination),
                      Self.validFolder(move.category) else {
                    remaining.append(move)
                    result.unresolved.append(move.source)
                    continue
                }
                let original = self.info(root, move.source)
                let category = destination.flatMap { try? openDirectory($0, move.category, create: false) }
                defer { if let category { close(category) } }
                let current = category.flatMap { self.info($0, move.destination) }
                let originalMatches = original.map { self.regular($0) && move.stamp.matches($0) } ?? false
                let destinationMatches = current.map { self.regular($0) && move.stamp.matches($0) } ?? false
                if originalMatches && !destinationMatches { continue }
                if let destination, let category, destinationMatches, original == nil,
                   self.sameDirectory(destination, under: root, named: Self.destinationName),
                   self.sameDirectory(category, under: destination, named: move.category),
                   renameatx_np(category, move.destination, root, move.source, UInt32(RENAME_EXCL)) == 0 {
                    result.count += 1
                } else {
                    remaining.append(move)
                    result.unresolved.append(move.source)
                }
            }

            if !remaining.isEmpty { journal.batches.append(Array(remaining.reversed())) }
            try writeJournal(journal, path)
            return result
        }
    }

    nonisolated static func example(_ inputs: [MivoriOrganizerInput]) -> [MivoriOrganizerSuggestion] {
        inputs.map { input in
            let classification: (String, String)
            switch input.file.format {
            case "swift", "c", "cpp", "h", "py", "js", "ts", "rs", "java", "sh":
                classification = ("源代码", "文件扩展名属于常见源代码。")
            case "csv", "tsv", "xlsx", "numbers":
                classification = ("表格资料", "文件扩展名属于表格资料。")
            case "png", "jpg", "jpeg", "heic", "gif", "webp":
                classification = ("图片素材", "文件扩展名属于图片。")
            case "md", "txt", "pdf", "docx", "rtf", "pages":
                classification = ("文档笔记", "文件扩展名属于文档。")
            default:
                classification = ("待确认", "此格式需要人工确认。")
            }
            return MivoriOrganizerSuggestion(id: input.id, file: input.file, folder: classification.0,
                                            reason: classification.1, selected: classification.0 != "待确认")
        }
    }

    private func withRoot<T>(_ folder: URL, perform: (Int32, stat, URL) throws -> T) throws -> T {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let path = folder.resolvingSymlinksInPath().standardizedFileURL
        let descriptor = open(path.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw MivoriOrganizerFailure.folderUnavailable }
        defer { close(descriptor) }
        var root = stat()
        guard fstat(descriptor, &root) == 0 else { throw MivoriOrganizerFailure.folderUnavailable }
        return try perform(descriptor, root, path)
    }

    private func withMutationLock<T>(
        in folder: URL, perform: (Int32, stat, URL) throws -> T
    ) throws -> T {
        try withRoot(folder) { root, attributes, path in
            try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let lockURL = journalURL(path).deletingPathExtension().appendingPathExtension("lock")
            let descriptor = open(lockURL.path, O_CLOEXEC | O_CREAT | O_NOFOLLOW | O_RDWR, 0o600)
            guard descriptor >= 0 else { throw MivoriOrganizerFailure.folderUnavailable }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw MivoriOrganizerFailure.folderUnavailable }
            return try perform(root, attributes, path)
        }
    }

    private func info(_ fd: Int32, _ name: String) -> stat? {
        var found = stat()
        return fstatat(fd, name, &found, AT_SYMLINK_NOFOLLOW) == 0 ? found : nil
    }

    private func regular(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG
    }

    private func openDirectory(_ parent: Int32, _ name: String, create: Bool) throws -> Int32 {
        if create, mkdirat(parent, name, 0o755) != 0, errno != EEXIST {
            throw MivoriOrganizerFailure.folderUnavailable
        }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MivoriOrganizerFailure.folderUnavailable }
        return fd
    }

    private func sameDirectory(_ fd: Int32, under parent: Int32, named name: String) -> Bool {
        var opened = stat()
        guard fstat(fd, &opened) == 0, let current = info(parent, name) else { return false }
        return opened.st_ino == current.st_ino && opened.st_dev == current.st_dev
            && current.st_mode & S_IFMT == S_IFDIR
    }

    private func journalURL(_ root: URL) -> URL {
        let digest = SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return journalDirectory.appending(path: digest + ".json")
    }

    private func readJournal(_ path: URL, _ root: stat) throws -> Journal {
        let url = journalURL(path)
        if FileManager.default.fileExists(atPath: url.path) {
            let stored = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
            if stored.device == root.st_dev && stored.inode == root.st_ino { return stored }
        }
        return Journal(device: root.st_dev, inode: root.st_ino, batches: [])
    }

    private func writeJournal(_ journal: Journal, _ path: URL) throws {
        try JSONEncoder().encode(journal).write(to: journalURL(path), options: .atomic)
    }

    private nonisolated static func validSource(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && name.utf8.count <= Int(NAME_MAX)
            && !name.contains("/") && !name.contains("\u{0}")
    }

    private nonisolated static func name(_ original: String, collision: Int) -> String {
        guard collision > 0 else { return original }
        let ext = (original as NSString).pathExtension
        var stem = (original as NSString).deletingPathExtension
        let suffix = " (\(collision))" + (ext.isEmpty ? "" : "." + ext)
        while !stem.isEmpty && stem.utf8.count + suffix.utf8.count > Int(NAME_MAX) { stem.removeLast() }
        if !stem.isEmpty { return stem + suffix }
        return "整理文件 (\(collision))"
    }
}
