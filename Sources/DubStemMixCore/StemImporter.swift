import Foundation

/// Repère les fichiers audio à importer et en déduit des noms de tranche lisibles.
public enum StemImporter {
    public static let audioExtensions: Set<String> = ["wav", "aif", "aiff", "flac", "mp3", "m4a", "caf"]

    /// Développe les dossiers (un niveau), ne garde que l'audio (les .asd d'Ableton, etc. sont ignorés), trie par nom.
    public static func audioFiles(in urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                result += children.filter(isAudio)
            } else if isAudio(url) {
                result.append(url)
            }
        }
        return result.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func isAudio(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// « Artiste - Titre (Basse)_1 », « Artiste - Titre (Chant)_1 » → « BASSE », « CHANT » :
    /// on retire le préfixe et le suffixe communs à tous les noms.
    public static func stripNames(for names: [String]) -> [String] {
        guard names.count > 1, let first = names.first else { return names.map(clean) }
        let prefix = names.dropFirst().reduce(first) { $0.commonPrefix(with: $1) }
        let reversedSuffix = names.dropFirst().reduce(String(first.reversed())) {
            $0.commonPrefix(with: String($1.reversed()))
        }
        return names.map { name in
            let core = name.dropFirst(prefix.count).dropLast(reversedSuffix.count)
            let cleaned = clean(String(core))
            return cleaned.isEmpty ? clean(name) : cleaned
        }
    }

    /// Titre de session : le préfixe commun des fichiers, sinon le nom du dossier.
    public static func sessionTitle(for urls: [URL]) -> String {
        let names = urls.map { $0.deletingPathExtension().lastPathComponent }
        if names.count > 1, let first = names.first {
            let prefix = clean(names.dropFirst().reduce(first) { $0.commonPrefix(with: $1) })
            if prefix.count >= 3 { return prefix }
        }
        return urls.first.map { clean($0.deletingLastPathComponent().lastPathComponent) } ?? ""
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " ()[]_-.")).uppercased()
    }
}
