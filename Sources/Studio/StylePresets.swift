import Foundation
import Combine

struct StylePreset: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var style: Style
    var isBuiltIn: Bool { id.hasPrefix("builtin-") }

    static let builtIns: [StylePreset] = {
        let signature = Style()
        var clean = Style()
        clean.backgroundTop = "#E8EBF0"; clean.backgroundBottom = "#C8D0DD"
        clean.padding = 0.06; clean.cornerRadius = 10; clean.cursorScale = 1.25
        clean.clickEffectStyle = .press
        var midnight = Style()
        midnight.backgroundTop = "#111827"; midnight.backgroundBottom = "#334155"
        midnight.padding = 0.10; midnight.cornerRadius = 20; midnight.clickEffectStyle = .ring
        var warm = Style()
        warm.backgroundTop = "#FF8B7B"; warm.backgroundBottom = "#F8D9A0"
        warm.padding = 0.10; warm.cornerRadius = 24; warm.cursorScale = 1.4
        return [StylePreset(id: "builtin-signature", name: "Signature", style: signature),
                StylePreset(id: "builtin-clean", name: "Clean slate", style: clean),
                StylePreset(id: "builtin-midnight", name: "Midnight", style: midnight),
                StylePreset(id: "builtin-warm", name: "Warm studio", style: warm)]
    }()
}

/// Presets own copies of their image assets; applying one copies the image into the project.
/// Moving or deleting the original recording therefore cannot break another recording's style.
struct PresetLibrary {
    let root: URL
    static let standard = PresetLibrary(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Studio/Presets", isDirectory: true))

    func load() throws -> [StylePreset] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .compactMap { folder -> StylePreset? in
                guard let preset = try? readJSON(StylePreset.self, folder.appendingPathComponent("preset.json")),
                      preset.id == folder.lastPathComponent, UUID(uuidString: preset.id) != nil else { return nil }
                return preset
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(name: String, style: Style, projectFolder: URL) throws -> StylePreset {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else { throw StudioError("Choose a preset name between 1 and 60 characters.") }
        let existing = try load() + StylePreset.builtIns
        guard !existing.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw StudioError("A preset with that name already exists. Choose another name.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let staging = root.appendingPathComponent(".pending-" + id, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            var stored = style
            if let image = style.backgroundImage {
                let source = try asset(named: image, in: projectFolder)
                let name = "background." + (source.pathExtension.isEmpty ? "png" : source.pathExtension)
                try fm.copyItem(at: source, to: staging.appendingPathComponent(name))
                stored.backgroundImage = name
            }
            let preset = StylePreset(id: id, name: name, style: stored)
            try writeJSON(preset, staging.appendingPathComponent("preset.json"))
            try fm.moveItem(at: staging, to: root.appendingPathComponent(id, isDirectory: true))
            return preset
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    func appliedStyle(_ preset: StylePreset, projectFolder: URL) throws -> Style {
        var style = preset.style
        if let image = style.backgroundImage {
            guard !preset.isBuiltIn, UUID(uuidString: preset.id) != nil else { throw StudioError("This preset has an invalid background image.") }
            let source = try asset(named: image, in: root.appendingPathComponent(preset.id))
            let name = "preset-background-\(UUID().uuidString).\(source.pathExtension)"
            try FileManager.default.copyItem(at: source, to: projectFolder.appendingPathComponent(name))
            style.backgroundImage = name
        }
        return style
    }

    func delete(_ preset: StylePreset) throws {
        guard !preset.isBuiltIn, UUID(uuidString: preset.id) != nil else { throw StudioError("Built-in presets cannot be deleted.") }
        try FileManager.default.removeItem(at: root.appendingPathComponent(preset.id))
    }

    private func asset(named name: String, in folder: URL) throws -> URL {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent, name != ".", name != ".." else {
            throw StudioError("The background image path is invalid.")
        }
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw StudioError("The background image is missing. Choose a new image before saving or applying this preset.") }
        return url
    }
}

@MainActor
final class StylePresetStore: ObservableObject {
    static let shared = StylePresetStore()
    @Published private(set) var custom: [StylePreset] = []
    let library = PresetLibrary.standard
    var all: [StylePreset] { StylePreset.builtIns + custom }
    func reload() throws { custom = try library.load() }
    func save(name: String, style: Style, folder: URL) throws -> StylePreset {
        let preset = try library.save(name: name, style: style, projectFolder: folder)
        try reload()
        return preset
    }
    func delete(_ preset: StylePreset) throws { try library.delete(preset); try reload() }
}
