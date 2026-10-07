import CoreImage
import Foundation
import UniformTypeIdentifiers

@main
struct MultiPrintSmoke {
    static func check(_ value: Bool, _ message: String = "Check failed") { precondition(value, message) }
    static func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> PrintBoundary {
        PrintBoundary(corners: [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y),
                                CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)])
    }
    static func consolidate(_ boundaries: [PrintBoundary]) -> [PrintBoundary] {
        PrintCrop.consolidated(boundaries.map { PrintCandidate(boundary: $0, confidence: 0.8, detector: "test") }).map(\.boundary)
    }
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let paper = CIImage(color: .white).cropped(to: CGRect(x: 100, y: 240, width: 300, height: 400))
            .composited(over: CIImage(color: .white).cropped(to: CGRect(x: 600, y: 240, width: 300, height: 400)))
            .composited(over: CIImage(color: .black).cropped(to: bounds))
        let bytes = FlatField.context().jpegRepresentation(of: paper, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])!
        let left = box(0.1, 0.2, 0.3, 0.5), right = box(0.6, 0.2, 0.3, 0.5)
        let insetLeft = box(0.12, 0.23, 0.27, 0.46)
        let interiorRight = box(0.62, 0.5, 0.25, 0.17)
        let suggestions = consolidate([left, insetLeft, right, interiorRight, left])
        check(suggestions == [left, right], "Keep outer boundaries; suppress inset and interior rectangles")
        check(consolidate([left, right]) == [left, right], "Keep separated prints")
        let partial = box(0.3, 0.4, 0.3, 0.5)
        check(consolidate([left, partial]) == [left, partial], "Keep ambiguous partial overlaps for review")
        let rotated = PrintBoundary(corners: [CGPoint(x: 0.6, y: 0.1), CGPoint(x: 0.92, y: 0.14),
            CGPoint(x: 0.85, y: 0.8), CGPoint(x: 0.53, y: 0.75)])
        check(consolidate([box(0.64, 0.4, 0.15, 0.2), rotated]) == [rotated], "Suppress an interior rectangle in a rotated print")
        check(abs(PrintCrop.intersectionArea(left, left) - PrintCrop.area(left.corners)) < 1e-8)
        check(PrintCrop.intersectionArea(left, right) == 0)
        let preferred = PrintCrop.consolidated([
            PrintCandidate(boundary: left, confidence: 0.7, detector: "rectangle"),
            PrintCandidate(boundary: insetLeft, confidence: 0.95, detector: "rectangle"),
            PrintCandidate(boundary: right, confidence: 0.6, detector: "document"),
            PrintCandidate(boundary: interiorRight, confidence: 1, detector: "rectangle")])
        check(preferred.map(\.boundary) == [insetLeft, right], "Prefer confident near duplicates, but reject confident interior rectangles")
        let ties = consolidate([insetLeft, left])
        check(ties == [insetLeft], "Confidence ties retain detector ordering")
        let detected = try PrintCrop.detect(paper)
        for expected in [left, right] {
            check(detected.contains { candidate in
                zip(candidate.corners, expected.corners).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.03 }
            }, "Detect both separated prints")
        }
        do { try PrintCrop.validateSelection([]); fatalError("Empty selection") } catch PrintCropError.emptySelection {}
        for selection in [[left, left], [left, box(0.2, 0.3, 0.3, 0.3)], [left, box(0.15, 0.25, 0.1, 0.1)]] {
            do { try PrintCrop.validateSelection(selection); fatalError("Overlap accepted") } catch PrintCropError.overlapping {}
        }
        try PrintCrop.validateSelection([left, box(0.4, 0.2, 0.3, 0.5)]) // touching
        let settings = CameraSettings(locked: true, iso: 80, exposureSeconds: 1.0 / 60, focusPosition: 0.4,
            whiteBalanceTemperature: 5000, whiteBalanceTint: 2, redGain: 1.4, greenGain: 1, blueGain: 1.6, width: 1000, height: 800)
        let info = CaptureInfo(request: CaptureRequest(assetID: UUID(), side: .front), capturedAt: Date(),
            fileExtension: "jpg", width: 1000, height: 800, camera: "Main", settings: settings)
        let flat = FlatFieldProfile(id: UUID(), reference: info, gridWidth: 2, gridHeight: 2, gains: [1, 1, 1, 1])
        let gray = GrayBalanceProfile(id: UUID(), reference: info, target: .gray18,
            selection: CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.1), measuredRGB: [0.3, 0.3, 0.3], gains: [1, 1, 1])
        let frame = try ScanArchive.save(info, data: bytes, folder: folder, profile: flat, grayBalance: gray)
        let before = try Data(contentsOf: frame.appendingPathComponent("metadata.json"))
        do { _ = try ScanArchive.extract(frame: frame, boundaries: [left, left]); fatalError("Overlap saved") }
        catch PrintCropError.overlapping {}
        check(try ScanArchive.assets(folder).count == 1)
        check(try Data(contentsOf: frame.appendingPathComponent("metadata.json")) == before)
        // A missed detection is supplied manually; removing extras simply omits them from this list.
        let children = try ScanArchive.extract(frame: frame, boundaries: [left, right])
        check(children.count == 2)
        let parent = try ScanArchive.read(frame)
        check(parent.extractedAssetIDs == children.map { UUID(uuidString: $0.lastPathComponent)! })
        check(parent.finished == nil)
        for (index, child) in children.enumerated() {
            let manifest = try ScanArchive.read(child)
            check(manifest.assetID != info.request.assetID && manifest.sourceAssetID == info.request.assetID)
            check(manifest.capture.request == info.request && manifest.recipe.crop == [left, right][index])
            check(manifest.recipe.flatField?.id == flat.id && manifest.recipe.grayBalance?.id == gray.id)
            check(manifest.finished!.width > 270 && manifest.finished!.width < 310)
            check(!FileManager.default.fileExists(atPath: child.appendingPathComponent("sources").path))
            check(try Data(contentsOf: ScanArchive.sourceURL(manifest, asset: child)) == bytes)
            let output = try ScanArchive.regenerate(asset: child, document: DocumentMetadata(title: "Print", date: "1956"))
            check(output.lastPathComponent.hasPrefix("1956_"))
            try ScanArchive.export(asset: child, to: folder.appendingPathComponent("print-\(index).tiff"), type: .tiff)
        }
        check(try ScanArchive.read(children[0]).index != ScanArchive.read(children[1]).index)
        do { _ = try ScanArchive.extract(frame: frame, boundaries: [left]); fatalError("Repeated extraction") }
        catch ArchiveError.alreadyExtracted {}
        check(try Data(contentsOf: ScanArchive.sourceURL(parent, asset: frame)) == bytes)
        // First output renders, second fails: no child is published, and retry works.
        let tiny = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))
        let tinyBytes = FlatField.context().jpegRepresentation(of: tiny, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])!
        let tinyInfo = CaptureInfo(request: CaptureRequest(assetID: UUID(), side: .front), capturedAt: Date(),
            fileExtension: "jpg", width: 20, height: 20, camera: "Main")
        let tinyFrame = try ScanArchive.save(tinyInfo, data: tinyBytes, folder: folder, profile: nil)
        let tinyMetadata = try Data(contentsOf: tinyFrame.appendingPathComponent("metadata.json"))
        let count = try ScanArchive.assets(folder).count
        do { _ = try ScanArchive.extract(frame: tinyFrame, boundaries: [box(0, 0, 0.5, 0.5), box(0.8, 0.8, 0.04, 0.04)]); fatalError("Tiny crop") }
        catch PrintCropError.invalidBoundary {}
        check(try ScanArchive.assets(folder).count == count)
        check(try Data(contentsOf: tinyFrame.appendingPathComponent("metadata.json")) == tinyMetadata)
        check(try Data(contentsOf: ScanArchive.sourceURL(ScanArchive.read(tinyFrame), asset: tinyFrame)) == tinyBytes)
        _ = try ScanArchive.extract(frame: tinyFrame, boundaries: [.manual])
        check(before != (try Data(contentsOf: frame.appendingPathComponent("metadata.json"))))
        print("Multi-print detection, shared sources, provenance, regeneration, overlap rejection, failure and retry passed")
    }
}
