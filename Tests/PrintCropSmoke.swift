import CoreImage
import Foundation

@main
struct PrintCropSmoke {
    static func color(_ image: CIImage, region: CGRect) -> [Float] {
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: region)])
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            FlatField.context().render(average, toBitmap: $0.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: FlatField.linear)
        }
        return pixel
    }
    static func main() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let background = CIImage(color: .black).cropped(to: bounds)
        let printRect = CGRect(x: 200, y: 160, width: 600, height: 480)
        let paper = CIImage(color: .white).cropped(to: printRect).composited(over: background)
        let detected = try PrintCrop.detect(paper)
        precondition(detected.contains { boundary in
            abs(boundary.corners[0].x - 0.2) < 0.03 && abs(boundary.corners[0].y - 0.2) < 0.03
                && abs(boundary.corners[2].x - 0.8) < 0.03 && abs(boundary.corners[2].y - 0.8) < 0.03
        }, "Detect the paper's outer boundary in normalized top-left coordinates")
        let angle: CGFloat = 0.07
        let rotation = CGAffineTransform(a: cos(angle), b: sin(angle), c: -sin(angle), d: cos(angle),
            tx: 500 - cos(angle) * 500 + sin(angle) * 400,
            ty: 400 - sin(angle) * 500 - cos(angle) * 400)
        let rotatedPaper = CIImage(color: .white).cropped(to: printRect).transformed(by: rotation)
            .composited(over: CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: bounds))
            .cropped(to: bounds)
        let expectedCorners = [CGPoint(x: 200, y: 640), CGPoint(x: 800, y: 640),
                               CGPoint(x: 800, y: 160), CGPoint(x: 200, y: 160)].map {
            let point = $0.applying(rotation)
            return CGPoint(x: point.x / bounds.width, y: 1 - point.y / bounds.height)
        }
        let rotatedCandidates = try PrintCrop.detect(rotatedPaper)
        precondition(rotatedCandidates.contains { candidate in
            zip(candidate.corners, expectedCorners).allSatisfy { actual, expected in
                hypot(actual.x - expected.x, actual.y - expected.y) < 0.03
            }
        }, "Detect all four corners of a rotated print on gray")
        let top = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 200, y: 600, width: 600, height: 40))
        let bottom = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 200, y: 160, width: 600, height: 40))
        let source = top.composited(over: bottom.composited(over: paper))
        let boundary = PrintBoundary(corners: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2),
                                              CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.2, y: 0.8)])
        let cropped = try PrintCrop.corrected(source, boundary: boundary)
        precondition(abs(cropped.extent.width - 576) < 2 && abs(cropped.extent.height - 456) < 2)
        precondition(cropped.extent.origin == .zero)
        // Simulate a detector selecting ten pixels of gray background on every edge.
        let gray = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: bounds)
        let insetPaper = CIImage(color: .white).cropped(to: printRect.insetBy(dx: 10, dy: 10)).composited(over: gray)
        let clean = try PrintCrop.corrected(insetPaper, boundary: boundary)
        let edgeRegions = [CGRect(x: 0, y: 0, width: 1, height: clean.extent.height),
                           CGRect(x: clean.extent.width - 1, y: 0, width: 1, height: clean.extent.height),
                           CGRect(x: 0, y: 0, width: clean.extent.width, height: 1),
                           CGRect(x: 0, y: clean.extent.height - 1, width: clean.extent.width, height: 1)]
        for region in edgeRegions {
            precondition(color(clean, region: region).prefix(3).allSatisfy { $0 > 0.99 }, "Trim gray background from every edge")
        }
        let topColor = color(cropped, region: CGRect(x: 100, y: cropped.extent.height - 20, width: 100, height: 10))
        let bottomColor = color(cropped, region: CGRect(x: 100, y: 10, width: 100, height: 10))
        precondition(topColor[0] > 0.9 && topColor[2] < 0.1 && bottomColor[2] > 0.9 && bottomColor[0] < 0.1, "Crop must not flip orientation")
        let crossed = PrintBoundary(corners: [boundary.corners[0], boundary.corners[2], boundary.corners[1], boundary.corners[3]])
        precondition(!crossed.valid)
        precondition(!PrintBoundary(corners: [CGPoint(x: -1, y: 0)]).valid)
        let trapezoid = PrintBoundary(corners: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.15),
                                               CGPoint(x: 0.75, y: 0.85), CGPoint(x: 0.25, y: 0.8)])
        let rectified = try PrintCrop.corrected(source, boundary: trapezoid)
        precondition(rectified.extent.width > 100 && rectified.extent.height > 100)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = FlatField.context().jpegRepresentation(of: source, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])!
        let info = CaptureInfo(request: CaptureRequest(assetID: UUID(), side: .front), capturedAt: Date(), fileExtension: "jpg", width: 1000, height: 800, camera: "Main")
        let original = try ScanArchive.save(info, data: data, folder: folder, profile: nil)
        let correctedURL = original.deletingLastPathComponent().appendingPathComponent("front-corrected.tiff")
        try FlatField.context().writeTIFFRepresentation(of: source, to: correctedURL, format: .RGBA16,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
        let preview = try PrintCrop.reviewPreview(url: correctedURL)
        precondition(preview.width == 1000 && preview.height == 800)
        precondition(preview.bitsPerComponent == 8 && preview.bitsPerPixel == 32)
        precondition(preview.alphaInfo == .premultipliedLast, "Review uses an already decoded RGBA bitmap")
        let previewTop = color(CIImage(cgImage: preview), region: CGRect(x: 300, y: 610, width: 100, height: 10))
        let previewBottom = color(CIImage(cgImage: preview), region: CGRect(x: 300, y: 170, width: 100, height: 10))
        precondition(previewTop[0] > 0.9 && previewBottom[2] > 0.9, "Review preserves source orientation")
        let output = try PrintCrop.save(originalURL: original, sourceURL: correctedURL, boundary: boundary)
        let originalBytes = try Data(contentsOf: original)
        precondition(originalBytes == data)
        precondition(FileManager.default.fileExists(atPath: correctedURL.path))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let metadataURL = original.deletingLastPathComponent().appendingPathComponent("metadata.json")
        let manifest = try decoder.decode(ScanManifest.self, from: Data(contentsOf: metadataURL))
        precondition(manifest.crops?["front"]?.outputFile == output.lastPathComponent)
        precondition(manifest.crops?["front"]?.sourceFile == correctedURL.lastPathComponent)
        precondition(manifest.captures["front"]?.request == info.request)
        let before = try Data(contentsOf: metadataURL)
        do {
            _ = try PrintCrop.save(originalURL: original, sourceURL: correctedURL, boundary: crossed)
            fatalError("Accepted a crossed boundary")
        } catch PrintCropError.invalidBoundary {}
        let after = try Data(contentsOf: metadataURL)
        precondition(before == after, "Invalid crop must not alter metadata")
        print("Print detection, perspective, orientation and archive tests passed")
    }
}
