import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@main
struct FinishedOutputSmoke {
    static func properties(_ url: URL) -> [String: Any] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]
    }
    static func main() throws {
        let folder = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { if CommandLine.arguments.count == 1 { try? FileManager.default.removeItem(at: folder) } }
        let image = CIImage(color: CIColor(red: 0.25, green: 0.5, blue: 0.75)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 80))
        let bytes = FlatField.context().jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])!
        precondition(ScanArchive.filename(document: DocumentMetadata(), index: 4_000_000_000) == "unknown-date_4000000000.heic")
        try DocumentMetadata(date: "2000-02-29").validate()
        do { try DocumentMetadata(date: "1900-02-29").validate(); fatalError("Invalid leap day") } catch ArchiveError.invalidDate {}
        let scanTime = Date(timeIntervalSince1970: 1_790_000_000)
        func capture(_ id: UUID = UUID()) -> CaptureInfo {
            CaptureInfo(request: CaptureRequest(assetID: id, side: .front), capturedAt: scanTime, fileExtension: "jpg", width: 100, height: 80, camera: "Main")
        }
        // Prototype archives lack required schema-2 fields. Reject their schema
        // explicitly before allocation, preserving the old record and counter.
        let legacyFolder = folder.appendingPathComponent("legacy")
        let legacyAsset = legacyFolder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: legacyAsset, withIntermediateDirectories: true)
        let legacyData = Data(#"{"schemaVersion":1,"captures":{}}"#.utf8)
        let legacyMetadata = legacyAsset.appendingPathComponent("metadata.json")
        try legacyData.write(to: legacyMetadata)
        do {
            _ = try ScanArchive.save(capture(), data: bytes, folder: legacyFolder, profile: nil)
            fatalError("Saved into an unsupported prototype archive")
        } catch ArchiveError.unsupportedSchema(let version) { precondition(version == 1) }
        let preservedLegacy = try Data(contentsOf: legacyMetadata)
        precondition(preservedLegacy == legacyData)
        precondition(!FileManager.default.fileExists(atPath: legacyFolder.appendingPathComponent(".next-index.json").path))
        let asset = try ScanArchive.save(capture(), data: bytes, folder: folder, profile: nil)
        if CommandLine.arguments.count > 1 {
            print(try ScanArchive.read(asset).index)
            return
        }
        var manifest = try ScanArchive.read(asset)
        precondition(manifest.index == 1 && manifest.finished == nil)
        do { _ = try ScanArchive.regenerate(asset: asset); fatalError("Published before review") } catch ArchiveError.pending {}
        manifest.recipe.cropReviewed = true
        var final = try ScanArchive.regenerate(asset: asset, recipe: manifest.recipe)
        precondition(final.lastPathComponent == "unknown-date_000001.heic")
        precondition(properties(final)[kCGImagePropertyHasAlpha as String] as? Bool != true,
            "Finished scans must be opaque")
        let original = try Data(contentsOf: asset.appendingPathComponent(manifest.sourceFile))
        precondition(original == bytes)
        var doc = DocumentMetadata(title: "Grandma's summer", notes: "Family picnic", labels: ["Family", "Summer"], people: ["Ada"], date: "1956", approximate: true)
        final = try ScanArchive.regenerate(asset: asset, document: doc)
        precondition(final.lastPathComponent == "1956_000001.heic")
        precondition(!FileManager.default.fileExists(atPath: asset.appendingPathComponent("unknown-date_000001.heic").path))
        var props = properties(final)
        precondition((props[kCGImagePropertyExifDictionary as String] as? [String: Any])?[kCGImagePropertyExifDateTimeOriginal as String] == nil)
        let iptc = props[kCGImagePropertyIPTCDictionary as String] as! [String: Any]
        precondition(iptc[kCGImagePropertyIPTCObjectName as String] as? String == doc.title)
        precondition(iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String == doc.notes)
        precondition(iptc[kCGImagePropertyIPTCKeywords as String] as? [String] == doc.labels)
        for date in ["1956-07", "1956-07-12", ""] {
            doc.date = date; doc.approximate = false
            final = try ScanArchive.regenerate(asset: asset, document: doc)
            precondition(final.lastPathComponent == (date.isEmpty ? "unknown-date" : date) + "_000001.heic")
        }
        doc.date = "1956-07-12"; doc.time = "14:05:06"
        final = try ScanArchive.regenerate(asset: asset, document: doc)
        props = properties(final)
        let exif = props[kCGImagePropertyExifDictionary as String] as! [String: Any]
        precondition(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String == "1956:07:12 14:05:06")
        manifest = try ScanArchive.read(asset)
        precondition(manifest.capture.capturedAt == scanTime && manifest.document.people == ["Ada"] && manifest.index == 1)
        let before = try Data(contentsOf: final)
        let beforeManifest = try Data(contentsOf: asset.appendingPathComponent("metadata.json"))
        for date in ["1956-02-30", "1956-13", "../bad", "0000", "1956-7"] {
            var bad = doc; bad.date = date
            do { _ = try ScanArchive.regenerate(asset: asset, document: bad); fatalError("Invalid date") } catch ArchiveError.invalidDate {}
        }
        // Exercise a render failure after staging has begun.
        var badRecipe = manifest.recipe
        badRecipe.crop = PrintBoundary(corners: [.zero])
        do { _ = try ScanArchive.regenerate(asset: asset, recipe: badRecipe); fatalError("Invalid recipe") } catch PrintCropError.invalidBoundary {}
        let after = try Data(contentsOf: final)
        let afterManifest = try Data(contentsOf: asset.appendingPathComponent("metadata.json"))
        precondition(before == after && beforeManifest == afterManifest)
        // A write/encode failure after a valid revision leaves both files unchanged.
        let obstruction = asset.appendingPathComponent(".render.heic")
        try FileManager.default.createDirectory(at: obstruction, withIntermediateDirectories: false)
        do { _ = try ScanArchive.regenerate(asset: asset); fatalError("Ignored blocked output path") } catch {}
        try FileManager.default.removeItem(at: obstruction)
        let failedWriteImage = try Data(contentsOf: final)
        let failedWriteManifest = try Data(contentsOf: asset.appendingPathComponent("metadata.json"))
        precondition(before == failedWriteImage && beforeManifest == failedWriteManifest)
        // Collision within the asset must not replace an unrelated file.
        var renamed = doc; renamed.date = "1960"; renamed.time = ""
        let occupied = asset.appendingPathComponent("1960_000001.heic")
        try Data("occupied".utf8).write(to: occupied)
        do { _ = try ScanArchive.regenerate(asset: asset, document: renamed); fatalError("Overwrote occupied name") } catch ArchiveError.collision {}
        try FileManager.default.removeItem(at: occupied)
        // Persisted counter survives a fresh call, and scanning imported manifests
        // prevents allocation of their indices even if the counter trails them.
        let second = try ScanArchive.save(capture(), data: bytes, folder: folder, profile: nil)
        var secondManifest = try ScanArchive.read(second)
        precondition(secondManifest.index == 2)
        secondManifest = ScanManifest(assetID: secondManifest.assetID, index: 42, capture: secondManifest.capture,
            sourceFile: secondManifest.sourceFile, recipe: secondManifest.recipe)
        try ScanArchive.writeJSON(secondManifest, to: second.appendingPathComponent("metadata.json"))
        let third = try ScanArchive.save(capture(), data: bytes, folder: folder, profile: nil)
        let thirdManifest = try ScanArchive.read(third)
        precondition(thirdManifest.index == 43)
        // Fresh processes concurrently open the same archive. The persisted counter
        // and archive lock must allocate distinct indices after restart.
        let processes = try (0..<3).map { _ -> (Process, Pipe) in
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = [folder.path]; process.standardOutput = pipe
            try process.run()
            return (process, pipe)
        }
        let indices = processes.map { process, pipe -> Int in
            process.waitUntilExit(); precondition(process.terminationStatus == 0)
            return Int(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines))!
        }
        precondition(indices.sorted() == [44, 45, 46])
        do { _ = try ScanArchive.save(capture(manifest.assetID), data: bytes, folder: folder, profile: nil); fatalError("Duplicate asset") } catch ArchiveError.collision {}
        // Imported duplicate index blocks subsequent edits before publication.
        let duplicate = ScanManifest(assetID: secondManifest.assetID, index: 1, capture: secondManifest.capture,
            sourceFile: secondManifest.sourceFile, recipe: secondManifest.recipe)
        try ScanArchive.writeJSON(duplicate, to: second.appendingPathComponent("metadata.json"))
        do { _ = try ScanArchive.regenerate(asset: asset); fatalError("Duplicate index") } catch ArchiveError.collision {}
        try FileManager.default.removeItem(at: second)
        var rotated = manifest.recipe; rotated.quarterTurns = 1
        final = try ScanArchive.regenerate(asset: asset, recipe: rotated)
        let rotatedManifest = try ScanArchive.read(asset)
        precondition(rotatedManifest.finished!.width == 80 && rotatedManifest.finished!.height == 100)
        // Clearing datetime metadata must not inherit camera or earlier final EXIF.
        doc = DocumentMetadata()
        final = try ScanArchive.regenerate(asset: asset, document: doc)
        precondition((properties(final)[kCGImagePropertyExifDictionary as String] as? [String: Any])?[kCGImagePropertyExifDateTimeOriginal as String] == nil)
        doc = DocumentMetadata(title: "Export title", notes: "Export notes", labels: ["label"], date: "1956-07-12", time: "14:05:06")
        final = try ScanArchive.regenerate(asset: asset, document: doc)
        for type in [UTType.jpeg, .tiff] {
            let exported = folder.appendingPathComponent("export." + type.preferredFilenameExtension!)
            try ScanArchive.export(asset: asset, to: exported, type: type)
            precondition(properties(exported)[kCGImagePropertyHasAlpha as String] as? Bool != true,
                "Exports must not contain an unnecessary alpha channel")
            if type == .tiff { precondition(properties(exported)[kCGImagePropertyDepth as String] as? Int == 16) }
            let exportBytes = try Data(contentsOf: exported)
            do { try ScanArchive.export(asset: asset, to: exported, type: type); fatalError("Overwrote export") } catch {}
            let unchanged = try Data(contentsOf: exported); precondition(unchanged == exportBytes)
        }
        final = try ScanArchive.regenerate(asset: asset, document: DocumentMetadata())
        // Actual HEIC source format is also preserved without transcoding.
        let heicBytes = try Data(contentsOf: final)
        let heicCapture = CaptureInfo(request: CaptureRequest(assetID: UUID(), side: .front), capturedAt: scanTime, fileExtension: "heic", width: 80, height: 100, camera: "Main")
        let heicAsset = try ScanArchive.save(heicCapture, data: heicBytes, folder: folder, profile: nil)
        let preservedHEIC = try Data(contentsOf: heicAsset.appendingPathComponent("sources/capture.heic"))
        precondition(preservedHEIC == heicBytes)
        let children = try FileManager.default.contentsOfDirectory(atPath: asset.path)
        precondition(children.sorted() == ["metadata.json", "sources", "unknown-date_000001.heic"].sorted())
        print("Finished HEIC depth: \(properties(final)[kCGImagePropertyDepth as String] ?? "unknown")")
        print("Finished outputs, metadata readback, partial dates, restart allocation, collisions, exports and failed revisions passed")
    }
}
