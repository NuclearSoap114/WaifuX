import Darwin
import Foundation
import PDFKit

enum MivoriFileExcerpt {
    static let maxCharacters = 1_200

    private static let textFormats: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "log", "text", "swift", "c", "h", "cpp",
        "hpp", "cs", "py", "rb", "go", "rs", "java", "kt", "js", "jsx", "mjs", "ts", "tsx",
        "json", "xml", "html", "css", "scss", "yaml", "yml", "toml", "sql", "sh", "zsh",
        "fish", "ini", "tex", "lua", "php", "r"
    ]

    static func supports(_ format: String) -> Bool {
        textFormats.contains(format) || ["pdf", "docx"].contains(format)
    }

    static func read(_ file: MivoriOrganizerFile, from root: Int32) -> String? {
        guard supports(file.format) else { return nil }
        let isDocument = file.format == "pdf" || file.format == "docx"
        let maxBytes = isDocument ? 16 * 1024 * 1024 : 16 * 1024
        if isDocument, file.size > maxBytes { return nil }
        let fd = openat(root, file.name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              file.stamp.matches(info), let data = try? handle.read(upToCount: maxBytes), !data.isEmpty,
              fstat(fd, &info) == 0, file.stamp.matches(info) else { return nil }

        let content: String?
        switch file.format {
        case "pdf":
            guard let pdf = PDFDocument(data: data), !pdf.isLocked else { return nil }
            content = (0..<min(pdf.pageCount, 3)).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        case "docx":
            content = readDOCX(data)
        default:
            if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
                content = String(data: data, encoding: .utf16)
            } else {
                content = String(decoding: data, as: UTF8.self)
            }
        }
        guard let content else { return nil }
        let excerpt = String(content.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
        return excerpt.isEmpty ? nil : excerpt
    }

    private static func readDOCX(_ contents: Data) -> String? {
        let storage = FileManager.default.temporaryDirectory
            .appending(path: "Mivori-docx-" + UUID().uuidString, directoryHint: .isDirectory)
        let archive = storage.appending(path: "document.docx")
        do {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        defer { try? FileManager.default.removeItem(at: storage) }
        do {
            try contents.write(to: archive, options: .withoutOverwriting)
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", archive.path, "word/document.xml"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let maxXMLBytes = 512 * 1024
            var document = Data()
            var overflow = false
            while let chunk = try output.fileHandleForReading.read(upToCount: 16 * 1024), !chunk.isEmpty {
                if document.count + chunk.count > maxXMLBytes {
                    overflow = true
                    if process.isRunning { process.terminate() }
                    break
                }
                document.append(chunk)
            }
            process.waitUntilExit()
            guard !overflow, process.terminationStatus == 0, !document.isEmpty else { return nil }
            let parser = XMLParser(data: document)
            let collector = WordText()
            parser.delegate = collector
            parser.shouldProcessNamespaces = true
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            guard parser.parse() || collector.reachedLimit else { return nil }
            return collector.text
        } catch { return nil }
    }

    private final class WordText: NSObject, XMLParserDelegate {
        var text = ""
        var reachedLimit = false
        private var isText = false

        private func isWord(_ uri: String?) -> Bool {
            uri == "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                || uri == "http://purl.oclc.org/ooxml/wordprocessingml/main"
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            guard isWord(namespaceURI) else { return }
            if name == "t" { isText = true }
            if name == "tab" { text.append("\t") }
            if name == "br" { text.append("\n") }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            guard isWord(namespaceURI) else { return }
            if name == "t" { isText = false }
            if name == "p" { text.append("\n") }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard isText else { return }
            text.append(contentsOf: string.prefix(max(0, maxCharacters - text.count)))
            if text.count >= maxCharacters {
                reachedLimit = true
                parser.abortParsing()
            }
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                    publicID: String?, systemID: String?) {
            parser.abortParsing()
        }
    }
}
