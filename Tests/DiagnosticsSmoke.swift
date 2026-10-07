import Foundation

@main
struct DiagnosticsSmoke {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = ScanDiagnostics(directory: folder, limit: 256)
        for index in 0..<20 { log.record("Event \(index): camera → Mac\nsecond line") }
        let data = try Data(contentsOf: log.url)
        let previous = try Data(contentsOf: folder.appendingPathComponent("diagnostics.previous.log"))
        precondition(data.count <= 256 && previous.count <= 256)
        let text = String(decoding: data, as: UTF8.self)
        precondition(text.contains("Event 19") && text.contains(" | second line"))
        let snapshot = try log.shareSnapshot()
        defer { try? FileManager.default.removeItem(at: snapshot) }
        log.record("Event after snapshot")
        let snapshotData = try Data(contentsOf: snapshot)
        precondition(snapshotData == data, "Shared snapshot must not change during later logging")
        precondition(log.recent().contains("Event after snapshot"))
        // Failure to write diagnostics must not break capture or networking.
        let blocked = folder.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let unavailable = ScanDiagnostics(directory: blocked)
        unavailable.record("Unavailable destination")
        precondition(unavailable.recent().isEmpty)
        try FileManager.default.removeItem(at: blocked)
        unavailable.record("Recovered destination")
        precondition(unavailable.recent().contains("Recovered destination"))
        print("Diagnostic persistence, rotation, snapshots, write failure and recovery passed")
    }
}
