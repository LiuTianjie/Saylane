import Foundation

@main struct AppDirectoriesMigrationTests {
    static func main() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory
            .appendingPathComponent("saylane-app-directories-tests.\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: sandbox) }
        let currentRoot = sandbox.appendingPathComponent("Saylane", isDirectory: true)
        let legacyRoot = sandbox.appendingPathComponent("RTranslate", isDirectory: true)

        let currentModel = currentRoot
            .appendingPathComponent("ASRModels/shared-model/current-revision/model.bin")
        let legacyModel = legacyRoot
            .appendingPathComponent("ASRModels/shared-model/legacy-revision/model.bin")
        let legacyComplete = legacyModel.deletingLastPathComponent().appendingPathComponent(".complete")
        let currentDiagnostic = currentRoot.appendingPathComponent("Diagnostics/current.log")
        let legacyDiagnostic = legacyRoot.appendingPathComponent("Diagnostics/legacy.log")
        let currentConflict = currentRoot.appendingPathComponent("Diagnostics/shared.log")
        let legacyConflict = legacyRoot.appendingPathComponent("Diagnostics/shared.log")
        let externalDirectory = sandbox.appendingPathComponent("outside", isDirectory: true)
        let legacySymlink = legacyRoot.appendingPathComponent("Diagnostics/external-link")
        let migratedSymlink = currentRoot.appendingPathComponent("Diagnostics/external-link")

        for url in [currentModel, legacyModel, currentDiagnostic, legacyDiagnostic, currentConflict, legacyConflict] {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        try Data("current-model".utf8).write(to: currentModel)
        try Data("legacy-model".utf8).write(to: legacyModel)
        try Data("legacy-revision".utf8).write(to: legacyComplete)
        try Data("current-diagnostic".utf8).write(to: currentDiagnostic)
        try Data("legacy-diagnostic".utf8).write(to: legacyDiagnostic)
        try Data("current-wins".utf8).write(to: currentConflict)
        try Data("legacy-must-not-overwrite".utf8).write(to: legacyConflict)
        try fm.createSymbolicLink(at: legacySymlink, withDestinationURL: externalDirectory)

        let moved = AppDirectories.migrateLegacyLayout(from: legacyRoot, to: currentRoot, fileManager: fm)

        let mergedModel = currentRoot
            .appendingPathComponent("ASRModels/shared-model/legacy-revision/model.bin")
        let mergedComplete = mergedModel.deletingLastPathComponent().appendingPathComponent(".complete")
        let mergedDiagnostic = currentRoot.appendingPathComponent("Diagnostics/legacy.log")
        precondition(Set(moved).isSuperset(of: ["ASRModels", "Diagnostics"]))
        precondition(fm.fileExists(atPath: currentModel.path), "existing current model data was lost")
        precondition(fm.fileExists(atPath: mergedModel.path),
                     "legacy model data was stranded when the current ASRModels target already existed")
        precondition(fm.fileExists(atPath: mergedComplete.path),
                     "hidden model completion markers must migrate with their revision")
        precondition(fm.fileExists(atPath: currentDiagnostic.path), "existing diagnostics were lost")
        precondition(fm.fileExists(atPath: mergedDiagnostic.path),
                     "legacy diagnostics were stranded when the current Diagnostics target already existed")
        let conflictAfterMigration = try String(contentsOf: currentConflict, encoding: .utf8)
        let legacyConflictAfterMigration = try String(contentsOf: legacyConflict, encoding: .utf8)
        precondition(conflictAfterMigration == "current-wins",
                     "migration overwrote a conflicting file in the current layout")
        precondition(legacyConflictAfterMigration == "legacy-must-not-overwrite")
        precondition(fm.fileExists(atPath: legacySymlink.path), "legacy symlink must remain untouched")
        precondition(!fm.fileExists(atPath: migratedSymlink.path), "legacy symlink must never be published")

        _ = AppDirectories.migrateLegacyLayout(from: legacyRoot, to: currentRoot, fileManager: fm)
        let currentModelAfterRetry = try String(contentsOf: currentModel, encoding: .utf8)
        let mergedModelAfterRetry = try String(contentsOf: mergedModel, encoding: .utf8)
        let conflictAfterRetry = try String(contentsOf: currentConflict, encoding: .utf8)
        precondition(currentModelAfterRetry == "current-model")
        precondition(mergedModelAfterRetry == "legacy-model")
        precondition(conflictAfterRetry == "current-wins")
        print("PASS: AppDirectories merges disjoint legacy data into existing targets, preserves conflicts and is idempotent")
    }
}
