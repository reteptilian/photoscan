import Foundation
import ImageIO

struct ScanManifest: Codable {
    var schemaVersion = 1
    let assetID: UUID
    var captures: [ScanSide.RawValue: CaptureInfo]
    var flatFieldID: UUID?
    var correctedFiles: [ScanSide.RawValue: String]?
}

enum ScanArchive {
    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    static func commit(folder: URL, name: String, contents: (URL) throws -> Void) throws -> URL {
        let staging = folder.appendingPathComponent(".pending-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try contents(staging)
            let destination = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.moveItem(at: staging, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
    static func saveReference(_ info: CaptureInfo, data: Data, folder: URL) throws -> FlatFieldProfile {
        guard ["heic", "jpg"].contains(info.fileExtension) else { throw FlatFieldError.invalidImage }
        let profile = try FlatField.makeProfile(data: data, info: info)
        let root = folder.appendingPathComponent("_calibrations", isDirectory: true)
        _ = try commit(folder: root, name: profile.id.uuidString) { staging in
            try data.write(to: staging.appendingPathComponent("reference." + info.fileExtension), options: .atomic)
            try writeJSON(profile, to: staging.appendingPathComponent("profile.json"))
        }
        return profile
    }
    static func save(_ info: CaptureInfo, data: Data, folder: URL, profile: FlatFieldProfile?) throws -> URL {
        guard ["heic", "jpg"].contains(info.fileExtension), !data.isEmpty,
              CGImageSourceCreateWithData(data as CFData, nil) != nil else { throw FlatFieldError.invalidImage }
        let side = info.request.side.rawValue
        let filename = side + "." + info.fileExtension
        let corrected = side + "-corrected.tiff"
        // Commit the original even if correction fails, so a received scan is never lost.
        var correctionError: Error?
        let destination = try commit(folder: folder, name: info.request.assetID.uuidString) { staging in
            try data.write(to: staging.appendingPathComponent(filename), options: .atomic)
            var manifest = ScanManifest(assetID: info.request.assetID, captures: [side: info])
            if let profile {
                do {
                    try FlatField.writeCorrection(data: data, info: info, profile: profile, to: staging.appendingPathComponent(corrected))
                    manifest.flatFieldID = profile.id
                    manifest.correctedFiles = [side: corrected]
                } catch {
                    correctionError = error
                    try? FileManager.default.removeItem(at: staging.appendingPathComponent(corrected))
                }
            }
            try writeJSON(manifest, to: staging.appendingPathComponent("metadata.json"))
        }
        if let correctionError { throw SavedOriginalError(url: destination.appendingPathComponent(filename), reason: correctionError.localizedDescription) }
        return destination.appendingPathComponent(filename)
    }
}
struct SavedOriginalError: LocalizedError {
    let url: URL
    let reason: String
    var errorDescription: String? { "Original saved; correction failed: " + reason }
}
