import Foundation

@main
struct ArchiveFolderSmoke {
    static func main() throws {
        if CommandLine.arguments.count == 3 {
            let selection = ArchiveFolderSelection(defaults: UserDefaults(suiteName: CommandLine.arguments[1])!)
            let restored = try selection.restore()!
            precondition(restored.standardizedFileURL.path == CommandLine.arguments[2])
            try Data("Capture after relaunch".utf8).write(to: restored.appendingPathComponent("capture.txt"))
            return
        }
        let suite = "PhotoScanArchiveSmoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First")
        let second = root.appendingPathComponent("Second")
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let empty = try ArchiveFolderSelection(defaults: defaults).restore()
        precondition(empty == nil)
        // Drop the selecting object, then resolve the persisted bookmark in a fresh instance.
        try ArchiveFolderSelection(defaults: defaults).select(first)
        defaults.synchronize()
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        relaunch.arguments = [suite, first.standardizedFileURL.path]
        try relaunch.run()
        relaunch.waitUntilExit()
        precondition(relaunch.terminationStatus == 0, "A fresh process must restore the saved folder")
        let capture = try String(contentsOf: first.appendingPathComponent("capture.txt"), encoding: .utf8)
        precondition(capture == "Capture after relaunch")
        let restored = try ArchiveFolderSelection(defaults: defaults).restore()!
        precondition(restored.standardizedFileURL == first.standardizedFileURL)
        try Data("Capture".utf8).write(to: restored.appendingPathComponent("capture.txt"))
        try ArchiveFolderSelection(defaults: defaults).select(second)
        let switched = try ArchiveFolderSelection(defaults: defaults).restore()!
        precondition(switched.standardizedFileURL == second.standardizedFileURL)

        let bookmark = defaults.data(forKey: ArchiveFolderSelection.bookmarkKey)!
        let file = root.appendingPathComponent("Not a folder")
        try Data().write(to: file)
        expectFailure { try ArchiveFolderSelection(defaults: defaults).select(file) }
        precondition(defaults.data(forKey: ArchiveFolderSelection.bookmarkKey) == bookmark,
                     "Failed selection must preserve the previous choice")
        try FileManager.default.removeItem(at: second)
        expectFailure { _ = try ArchiveFolderSelection(defaults: defaults).restore() }
        precondition(defaults.data(forKey: ArchiveFolderSelection.bookmarkKey) == bookmark,
                     "An unplugged drive must not erase the saved choice")
        defaults.set(Data("Invalid bookmark".utf8), forKey: ArchiveFolderSelection.bookmarkKey)
        expectFailure { _ = try ArchiveFolderSelection(defaults: defaults).restore() }
        try ArchiveFolderSelection(defaults: defaults).select(first)
        let recovered = try ArchiveFolderSelection(defaults: defaults).restore()
        precondition(recovered != nil)
        print("Archive bookmark relaunch, restoration, switching, failed selection, missing folder, corruption and recovery passed")
    }

    static func expectFailure(_ body: () throws -> Void) {
        do {
            try body()
            preconditionFailure("Expected an unavailable archive to fail")
        } catch { }
    }
}
