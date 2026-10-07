import Foundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import Darwin

struct DocumentMetadata: Codable, Equatable, Sendable {
    var title = ""
    var notes = ""
    var labels: [String] = []
    var people: [String] = []
    // Gregorian local date, with only the precision known. No implied timezone.
    var date = ""
    var time = "" // HH:mm:ss, permitted only with an exact day.
    var approximate = false

    func validate() throws {
        guard date.isEmpty || date.range(of: #"^\d{4}(-\d{2})?(-\d{2})?$"#, options: .regularExpression) != nil else { throw ArchiveError.invalidDate }
        if !date.isEmpty {
            let parts = date.split(separator: "-").compactMap { Int($0) }
            guard let year = parts.first, year > 0 else { throw ArchiveError.invalidDate }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = DateComponents(year: year, month: parts.count > 1 ? parts[1] : 1, day: parts.count > 2 ? parts[2] : 1)
            guard let value = calendar.date(from: components) else { throw ArchiveError.invalidDate }
            let actual = calendar.dateComponents([.year, .month, .day], from: value)
            guard actual.year == components.year, actual.month == components.month, actual.day == components.day else { throw ArchiveError.invalidDate }
        }
        if !time.isEmpty {
            guard date.count == 10, !approximate,
                  time.range(of: #"^([01]\d|2[0-3]):[0-5]\d:[0-5]\d$"#, options: .regularExpression) != nil else { throw ArchiveError.invalidDate }
        }
    }
    var exifDate: String? {
        // EXIF requires a complete datetime; do not invent midnight for a date-only record.
        guard date.count == 10, !time.isEmpty, !approximate else { return nil }
        return date.replacingOccurrences(of: "-", with: ":") + " " + time
    }
}
struct ProcessingRecipe: Codable, Sendable {
    var flatField: FlatFieldProfile?
    var grayBalance: GrayBalanceProfile?
    var crop: PrintBoundary?
    var cropReviewed = false
    var quarterTurns = 0
}
struct FinishedImage: Codable, Sendable {
    let filename: String
    let width: Int
    let height: Int
    let revision: Int
}
struct ScanManifest: Codable, Sendable {
    var schemaVersion = 2
    let assetID: UUID
    let index: Int
    let capture: CaptureInfo
    let sourceFile: String
    var document = DocumentMetadata()
    var recipe: ProcessingRecipe
    var finished: FinishedImage?
}
enum ArchiveError: LocalizedError {
    case invalidDate, collision, invalidArchive, encoding, pending
    var errorDescription: String? {
        switch self {
        case .invalidDate: "Use a valid YYYY, YYYY-MM, or YYYY-MM-DD date. Time requires an exact day and HH:mm:ss."
        case .collision: "That asset, index, or filename already exists. No files were overwritten."
        case .invalidArchive: "The archive metadata or source is invalid or unsupported."
        case .encoding: "The finished image could not be encoded or verified. The previous revision is preserved."
        case .pending: "Accept or explicitly skip crop review before publishing."
        }
    }
}

enum ScanArchive {
    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    static func read(_ asset: URL) throws -> ScanManifest {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ScanManifest.self, from: Data(contentsOf: asset.appendingPathComponent("metadata.json")))
        guard manifest.schemaVersion == 2, manifest.assetID.uuidString == asset.lastPathComponent,
              manifest.index > 0, ["sources/capture.heic", "sources/capture.jpg"].contains(manifest.sourceFile) else { throw ArchiveError.invalidArchive }
        try manifest.document.validate()
        if let final = manifest.finished {
            guard final.filename == filename(document: manifest.document, index: manifest.index) else { throw ArchiveError.invalidArchive }
        }
        return manifest
    }
    // Advisory archive-wide process lock covers allocation and publication.
    static func locked<T>(_ folder: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.appendingPathComponent(".archive.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
    static func commit(folder: URL, name: String, contents: (URL) throws -> Void) throws -> URL {
        let staging = folder.appendingPathComponent(".pending-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try contents(staging)
        let destination = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
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
    static func saveGrayReference(_ info: CaptureInfo, data: Data, folder: URL, target: DKCGrayTarget, selection: CGRect) throws -> GrayBalanceProfile {
        guard ["heic", "jpg"].contains(info.fileExtension) else { throw FlatFieldError.invalidImage }
        let profile = try GrayBalance.makeProfile(data: data, info: info, target: target, selection: selection)
        _ = try commit(folder: folder.appendingPathComponent("_calibrations", isDirectory: true), name: profile.id.uuidString) { staging in
            try data.write(to: staging.appendingPathComponent("reference." + info.fileExtension), options: .atomic)
            try writeJSON(profile, to: staging.appendingPathComponent("gray-balance.json"))
        }
        return profile
    }
    static func filename(document: DocumentMetadata, index: Int) -> String {
        (document.date.isEmpty ? "unknown-date" : document.date) + "_" + String(format: "%06lld", Int64(index)) + ".heic"
    }
    static func assets(_ folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
    }
    static func checkCollision(folder: URL, index: Int, name: String, excluding: URL? = nil) throws {
        for asset in try assets(folder) where asset.standardizedFileURL.path != excluding?.standardizedFileURL.path {
            let manifest = try read(asset)
            if manifest.index == index || manifest.finished?.filename == name || FileManager.default.fileExists(atPath: asset.appendingPathComponent(name).path) {
                throw ArchiveError.collision
            }
        }
    }
    static func allocate(_ folder: URL) throws -> Int {
        let counter = folder.appendingPathComponent(".next-index.json")
        var next = 1
        if FileManager.default.fileExists(atPath: counter.path) {
            next = try JSONDecoder().decode(Int.self, from: Data(contentsOf: counter))
            guard next > 0 else { throw ArchiveError.invalidArchive }
        }
        for asset in try assets(folder) {
            let existing = try read(asset).index
            guard existing < Int.max else { throw ArchiveError.invalidArchive }
            next = max(next, existing + 1)
        }
        guard next < Int.max else { throw ArchiveError.invalidArchive }
        try checkCollision(folder: folder, index: next, name: filename(document: DocumentMetadata(), index: next))
        // Reserve first: a failed capture may leave a gap, but an allocated index is never reused.
        try writeJSON(next + 1, to: counter)
        return next
    }
    static func save(_ info: CaptureInfo, data: Data, folder: URL, profile: FlatFieldProfile?, grayBalance: GrayBalanceProfile? = nil) throws -> URL {
        guard ["heic", "jpg"].contains(info.fileExtension), !data.isEmpty,
              let image = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else { throw FlatFieldError.invalidImage }
        let actualType = CGImageSourceGetType(image) as String?
        guard actualType == (info.fileExtension == "jpg" ? UTType.jpeg.identifier : UTType.heic.identifier) else { throw FlatFieldError.invalidImage }
        return try locked(folder) {
            guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent(info.request.assetID.uuidString).path) else { throw ArchiveError.collision }
            let index = try allocate(folder)
            return try commit(folder: folder, name: info.request.assetID.uuidString) { staging in
                let sources = staging.appendingPathComponent("sources")
                try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
                let source = "sources/capture." + info.fileExtension
                try data.write(to: staging.appendingPathComponent(source), options: .atomic)
                let manifest = ScanManifest(assetID: info.request.assetID, index: index, capture: info,
                    sourceFile: source, recipe: ProcessingRecipe(flatField: profile, grayBalance: grayBalance))
                try writeJSON(manifest, to: staging.appendingPathComponent("metadata.json"))
            }
        }
    }
    static func rendered(_ manifest: ScanManifest, asset: URL) throws -> CIImage {
        var output = try FlatField.image(Data(contentsOf: asset.appendingPathComponent(manifest.sourceFile)))
        if let profile = manifest.recipe.flatField {
            guard profile.matches(manifest.capture) else { throw FlatFieldError.incompatible }
            output = try FlatField.corrected(output, profile: profile)
        }
        if let balance = manifest.recipe.grayBalance {
            guard balance.matches(manifest.capture) else { throw GrayBalanceError.incompatible }
            output = try GrayBalance.corrected(output, profile: balance)
        }
        if let crop = manifest.recipe.crop { output = try PrintCrop.corrected(output, boundary: crop) }
        let turns = ((manifest.recipe.quarterTurns % 4) + 4) % 4
        if turns != 0 { output = output.oriented([.up, .right, .down, .left][turns]) }
        return output.transformed(by: CGAffineTransform(translationX: -output.extent.minX, y: -output.extent.minY))
    }
    static func previewImage(_ manifest: ScanManifest, asset: URL) throws -> CGImage {
        // Review always shows the full frame with accepted calibration, before crop/rotation.
        var full = manifest; full.recipe.crop = nil; full.recipe.quarterTurns = 0
        let image = try rendered(full, asset: asset)
        let scale = min(1, 1600 / max(image.extent.width, image.extent.height))
        let reduced = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = FlatField.context().createCGImage(reduced, from: reduced.extent,
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw ArchiveError.encoding }
        return cg
    }
    static func properties(_ document: DocumentMetadata) -> [String: Any] {
        var iptc: [String: Any] = [:]
        if !document.title.isEmpty { iptc[kCGImagePropertyIPTCObjectName as String] = document.title }
        if !document.notes.isEmpty { iptc[kCGImagePropertyIPTCCaptionAbstract as String] = document.notes }
        if !document.labels.isEmpty { iptc[kCGImagePropertyIPTCKeywords as String] = document.labels }
        var exif: [String: Any] = [:]
        if let date = document.exifDate { exif[kCGImagePropertyExifDateTimeOriginal as String] = date }
        return [kCGImagePropertyOrientation as String: 1,
                kCGImagePropertyIPTCDictionary as String: iptc,
                kCGImagePropertyExifDictionary as String: exif,
                kCGImageDestinationLossyCompressionQuality as String: 0.95]
    }
    static func encode(_ image: CIImage, document: DocumentMetadata, to url: URL, type: UTType = .heic) throws -> (Int, Int) {
        try document.validate()
        // All filters work in floating-point linear light. Rasterize only once, at 16 bits,
        // then let the selected format's encoder choose its supported storage precision.
        guard let cg = FlatField.context().createCGImage(image, from: image.extent,
            format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw ArchiveError.encoding }
        CGImageDestinationAddImage(destination, cg, properties(document) as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
              decoded.width == cg.width, decoded.height == cg.height,
              let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { throw ArchiveError.encoding }
        let iptc = values[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        let exif = values[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        guard (document.title.isEmpty || iptc[kCGImagePropertyIPTCObjectName as String] as? String == document.title),
              (document.notes.isEmpty || iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String == document.notes),
              (document.labels.isEmpty || iptc[kCGImagePropertyIPTCKeywords as String] as? [String] == document.labels),
              exif[kCGImagePropertyExifDateTimeOriginal as String] as? String == document.exifDate else { throw ArchiveError.encoding }
        return (cg.width, cg.height)
    }
    static func regenerate(asset: URL, document: DocumentMetadata? = nil, recipe: ProcessingRecipe? = nil) throws -> URL {
        try locked(asset.deletingLastPathComponent()) {
            var manifest = try read(asset)
            let old = manifest.finished
            if let document { manifest.document = document }
            if let recipe { manifest.recipe = recipe }
            try manifest.document.validate()
            guard manifest.recipe.cropReviewed else { throw ArchiveError.pending }
            let name = filename(document: manifest.document, index: manifest.index)
            try checkCollision(folder: asset.deletingLastPathComponent(), index: manifest.index, name: name, excluding: asset)
            if name != old?.filename && FileManager.default.fileExists(atPath: asset.appendingPathComponent(name).path) { throw ArchiveError.collision }
            let staging = asset.deletingLastPathComponent().appendingPathComponent(".pending-" + UUID().uuidString)
            try FileManager.default.copyItem(at: asset, to: staging)
            defer { try? FileManager.default.removeItem(at: staging) }
            let image = try rendered(manifest, asset: asset)
            let temp = staging.appendingPathComponent(".render.heic")
            let (width, height) = try encode(image, document: manifest.document, to: temp)
            if let old { try FileManager.default.removeItem(at: staging.appendingPathComponent(old.filename)) }
            try FileManager.default.moveItem(at: temp, to: staging.appendingPathComponent(name))
            manifest.finished = FinishedImage(filename: name, width: width, height: height, revision: (old?.revision ?? 0) + 1)
            try writeJSON(manifest, to: staging.appendingPathComponent("metadata.json"))
            // macOS atomically exchanges entire directories: readers observe a complete
            // old or new revision, and a crash cannot separate the image from its manifest.
            guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, asset.path, UInt32(RENAME_SWAP)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return asset.appendingPathComponent(name)
        }
    }
    static func export(asset: URL, to destination: URL, type: UTType) throws {
        guard [.jpeg, .tiff].contains(type) else { throw ArchiveError.encoding }
        try locked(asset.deletingLastPathComponent()) {
            let manifest = try read(asset)
            guard manifest.finished != nil else { throw ArchiveError.pending }
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".export-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staging) }
            _ = try encode(rendered(manifest, asset: asset), document: manifest.document, to: staging, type: type)
            // moveItem refuses an existing destination, including a race with another writer.
            try FileManager.default.moveItem(at: staging, to: destination)
        }
    }
}
