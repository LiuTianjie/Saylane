import Foundation

/// One home for everything Saylane writes: `~/Library/Application Support/Saylane/…`.
/// Older builds used `RTranslate/`; those directories are moved once at startup and
/// read from their old place if the move is not possible.
enum AppDirectories {
    static let productName = "Saylane"
    static let legacyProductName = "RTranslate"

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    static var root: URL { applicationSupport.appendingPathComponent(productName, isDirectory: true) }
    static var legacyRoot: URL { applicationSupport.appendingPathComponent(legacyProductName, isDirectory: true) }

    static var asrModels: URL { resolve("ASRModels") }
    static var diagnostics: URL { resolve("Diagnostics") }
    static var rime: URL { root.appendingPathComponent("Rime", isDirectory: true) }
    static var glossary: URL { root.appendingPathComponent("Glossary", isDirectory: true) }
    static var glossaryFile: URL {
        let new = glossary.appendingPathComponent("dictation-glossary.json")
        let old = legacyRoot.appendingPathComponent("dictation-glossary.json")
        return FileManager.default.fileExists(atPath: new.path) || !FileManager.default.fileExists(atPath: old.path) ? new : old
    }

    /// Prefer the new location; fall back to the legacy directory only while it
    /// still exists and the new one does not (a failed or not-yet-run migration).
    private static func resolve(_ name: String) -> URL {
        let new = root.appendingPathComponent(name, isDirectory: true)
        let old = legacyRoot.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: new.path) { return new }
        if fm.fileExists(atPath: old.path) { return old }
        return new
    }

    /// Move (never copy) legacy data into the new layout. Safe to call every launch.
    @discardableResult
    static func migrateLegacyLayout(fileManager fm: FileManager = .default) -> [String] {
        migrateLegacyLayout(from: legacyRoot, to: root, fileManager: fm)
    }

    /// Testable migration core. Directory trees are merged recursively so an
    /// existing Saylane directory does not hide models or diagnostics left in
    /// RTranslate. A destination entry always wins a file conflict; the legacy
    /// entry is left in place instead of being overwritten or discarded.
    @discardableResult
    static func migrateLegacyLayout(from legacyRoot: URL, to root: URL,
                                    fileManager fm: FileManager = .default) -> [String] {
        var moved: [String] = []
        guard fm.fileExists(atPath: legacyRoot.path) else { return moved }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let directoryPairs: [(URL, URL)] = [
            (legacyRoot.appendingPathComponent("ASRModels", isDirectory: true), root.appendingPathComponent("ASRModels", isDirectory: true)),
            (legacyRoot.appendingPathComponent("Diagnostics", isDirectory: true), root.appendingPathComponent("Diagnostics", isDirectory: true))
        ]
        for (old, new) in directoryPairs {
            guard fm.fileExists(atPath: old.path) else { continue }
            do {
                if try mergeDirectory(at: old, into: new, fileManager: fm) {
                    moved.append(new.lastPathComponent)
                }
            } catch {
                // Preserve any entry that could not be moved. A later launch can retry.
            }
        }

        let oldGlossary = legacyRoot.appendingPathComponent("dictation-glossary.json")
        let newGlossary = root.appendingPathComponent("Glossary", isDirectory: true)
            .appendingPathComponent("dictation-glossary.json")
        if fm.fileExists(atPath: oldGlossary.path), !fm.fileExists(atPath: newGlossary.path) {
            do {
                try fm.createDirectory(at: newGlossary.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: oldGlossary, to: newGlossary)
                moved.append(newGlossary.lastPathComponent)
            } catch {
                // Preserve the legacy glossary so `glossaryFile` can still read it.
            }
        }
        if let remaining = try? fm.contentsOfDirectory(atPath: legacyRoot.path), remaining.isEmpty {
            try? fm.removeItem(at: legacyRoot)
        }
        return moved
    }

    /// Returns whether at least one entry moved. Symlinks are deliberately left
    /// in the legacy tree; following or publishing them would escape the app's
    /// data directory. Existing destination files are never replaced.
    private static func mergeDirectory(at source: URL, into destination: URL,
                                       fileManager fm: FileManager) throws -> Bool {
        let sourceValues = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true else { return false }

        if fm.fileExists(atPath: destination.path) {
            let destinationValues = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard destinationValues.isDirectory == true, destinationValues.isSymbolicLink != true else { return false }
        } else {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        }

        var movedAny = false
        let children = try fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { continue }
            let target = destination.appendingPathComponent(child.lastPathComponent,
                                                             isDirectory: values.isDirectory == true)
            if !fm.fileExists(atPath: target.path) {
                try fm.moveItem(at: child, to: target)
                movedAny = true
            } else if values.isDirectory == true {
                movedAny = try mergeDirectory(at: child, into: target, fileManager: fm) || movedAny
            }
        }
        if let remaining = try? fm.contentsOfDirectory(atPath: source.path), remaining.isEmpty {
            try fm.removeItem(at: source)
        }
        return movedAny
    }
}
