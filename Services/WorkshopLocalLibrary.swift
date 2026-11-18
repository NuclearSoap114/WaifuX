import Foundation

struct WorkshopLocalProject: Identifiable, Sendable {
    enum Source: String, Sendable {
        case mivori = "Mivori"
        case steam = "Steam"
        case waifuX = "WaifuX"
        case selectedFolder = "指定目录"
    }

    let id: String
    let title: String
    let description: String?
    let type: WorkshopWallpaper.WallpaperType
    let tags: [String]
    let projectURL: URL
    let previewURL: URL?
    let source: Source
}

enum WorkshopLocalLibrary {
    private static let appID = "431960"
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "avi"]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "bmp", "tiff"
    ]

    static func scan(
        mediaFolder: URL,
        applicationSupport: URL,
        selectedLibrary: URL? = nil,
        fileManager: FileManager = .default
    ) -> [WorkshopLocalProject] {
        var projects: [String: WorkshopLocalProject] = [:]

        func record(id: String, folder: URL, source: WorkshopLocalProject.Source) {
            guard projects[id] == nil, let project = readProject(
                id: id,
                folder: folder,
                source: source,
                fileManager: fileManager
            ) else { return }
            projects[id] = project
        }

        func scanAppMedia(_ folder: URL, source: WorkshopLocalProject.Source) {
            for child in children(of: folder, fileManager: fileManager) {
                let name = child.lastPathComponent
                guard name.hasPrefix("workshop_"), let id = workshopID(String(name.dropFirst("workshop_".count))) else {
                    continue
                }
                record(id: id, folder: steamContentRoot(child).appendingPathComponent(id, isDirectory: true), source: source)
                record(id: id, folder: child, source: source)
            }
        }

        func scanSteamContent(_ root: URL, source: WorkshopLocalProject.Source = .steam) {
            for folder in children(of: root, fileManager: fileManager) {
                guard let id = workshopID(folder.lastPathComponent) else { continue }
                record(id: id, folder: folder, source: source)
            }
        }

        if let selectedLibrary {
            scanSteamContent(selectedLibrary, source: .selectedFolder)
        } else {
            scanAppMedia(mediaFolder, source: .mivori)
            let steam = applicationSupport.appendingPathComponent("Steam", isDirectory: true)
            for library in steamLibraries(under: steam) {
                scanSteamContent(steamContentRoot(library))
            }
            scanAppMedia(applicationSupport.appendingPathComponent("WaifuX/Media", isDirectory: true), source: .waifuX)
        }
        return projects.values.sorted { lhs, rhs in
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    private static func readProject(
        id: String,
        folder: URL,
        source: WorkshopLocalProject.Source,
        fileManager: FileManager
    ) -> WorkshopLocalProject? {
        let root = folder.resolvingSymlinksInPath()
        let json = root.appendingPathComponent("project.json")
        guard isRegularProjectFile(json, within: root),
              let size = (try? fileManager.attributesOfItem(atPath: json.path))?[.size] as? NSNumber,
              (1...1_000_000).contains(size.intValue),
              let data = try? Data(contentsOf: json),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let files = children(of: root, fileManager: fileManager).filter { isRegularProjectFile($0, within: root) }
        let primary = relativeFile(manifest["file"] as? String, within: root)
        let primaryExtension = primary?.pathExtension.lowercased()
        let type: WorkshopWallpaper.WallpaperType
        switch (manifest["type"] as? String)?.lowercased() {
        case "scene":
            guard files.contains(where: { $0.pathExtension.lowercased() == "pkg" })
                    || (primary != nil && primaryExtension == "json") else { return nil }
            type = .scene
        case "video":
            guard primaryExtension.map(videoExtensions.contains) == true
                    || files.contains(where: { videoExtensions.contains($0.pathExtension.lowercased()) }) else { return nil }
            type = .video
        case "web":
            guard primaryExtension == "html" || primaryExtension == "htm" else { return nil }
            type = .web
        case "image":
            guard primaryExtension.map(imageExtensions.contains) == true else { return nil }
            type = .image
        default:
            guard files.contains(where: { $0.pathExtension.lowercased() == "pkg" }) else { return nil }
            type = .scene
        }

        var preview = relativeFile(manifest["preview"] as? String, within: root)
        if let ext = preview?.pathExtension.lowercased(), !imageExtensions.contains(ext) { preview = nil }
        if preview == nil {
            preview = files.first {
                $0.deletingPathExtension().lastPathComponent.lowercased().hasPrefix("preview")
                && imageExtensions.contains($0.pathExtension.lowercased())
            }
        }
        let title = (manifest["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkshopLocalProject(
            id: id, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? id,
            description: manifest["description"] as? String, type: type,
            tags: manifest["tags"] as? [String] ?? [],
            projectURL: root, previewURL: preview, source: source
        )
    }

    private static func relativeFile(_ path: String?, within folder: URL) -> URL? {
        guard let path, !path.isEmpty, !path.hasPrefix("/") else { return nil }
        let url = folder.appendingPathComponent(path.replacingOccurrences(of: "\\", with: "/"))
        return isRegularProjectFile(url, within: folder) ? url : nil
    }

    private static func isRegularProjectFile(_ url: URL, within folder: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        return resolved.path.hasPrefix(folder.standardizedFileURL.path + "/")
            && (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func children(of url: URL, fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
    }

    private static func workshopID(_ name: String) -> String? {
        guard let id = UInt64(name), id > 0, String(id) == name else { return nil }
        return name
    }

    private static func steamContentRoot(_ library: URL) -> URL {
        library.appendingPathComponent("steamapps/workshop/content/" + appID, isDirectory: true)
    }

    private static func steamLibraries(under steam: URL) -> [URL] {
        let config = steam.appendingPathComponent("steamapps/libraryfolders.vdf")
        guard let text = try? String(contentsOf: config, encoding: .utf8),
              let pattern = try? NSRegularExpression(pattern: #"(?m)^\s*"path"\s+"((?:\\.|[^"\\])+)""#) else {
            return [steam]
        }

        var paths = Set([steam.standardizedFileURL.path])
        var libraries = [steam]
        let fullRange = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: fullRange) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let path = String(text[range])
                .replacingOccurrences(of: #"\\""#, with: "\"")
                .replacingOccurrences(of: #"\\\\"#, with: "\\")
            guard path.hasPrefix("/") else { continue }
            let library = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            if paths.insert(library.path).inserted { libraries.append(library) }
        }
        return libraries
    }
}
