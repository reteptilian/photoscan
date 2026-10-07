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
        let top = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 200, y: 600, width: 600, height: 40))
        let bottom = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 200, y: 160, width: 600, height: 40))
        let source = top.composited(over: bottom.composited(over: paper))
        let boundary = PrintBoundary(corners: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2),
                                              CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.2, y: 0.8)])
        let cropped = try PrintCrop.corrected(source, boundary: boundary)
        precondition(abs(cropped.extent.width - 600) < 2 && abs(cropped.extent.height - 480) < 2)
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
