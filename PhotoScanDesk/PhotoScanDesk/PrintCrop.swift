import CoreImage
import Foundation
import ImageIO
import Vision

struct PrintBoundary: Codable, Equatable, Sendable {
    var corners: [CGPoint]
    static let manual = PrintBoundary(corners: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1),
                                               CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.1, y: 0.9)])
    var valid: Bool {
        guard corners.count == 4, corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }) else { return false }
        let crosses = (0..<4).map { i in
            let a = corners[i], b = corners[(i + 1) % 4], c = corners[(i + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        return crosses.allSatisfy { $0 > 0.001 }
    }
}
enum PrintCropError: LocalizedError {
    case invalidBoundary, missingImage
    var errorDescription: String? {
        switch self {
        case .invalidBoundary: "Crop corners must form a non-crossing rectangle inside the image."
        case .missingImage: "The saved image or its archive metadata could not be read."
        }
    }
}
enum PrintCrop {
    // Trim inside the rectified boundary to remove background, edge shadows,
    // and interpolation pixels. Scale with the print, not the full camera frame.
    static let edgeTrimFraction: CGFloat = 0.025
    static func image(url: URL) throws -> CIImage {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { throw PrintCropError.missingImage }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
    static func reviewPreview(url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let context = CGContext(data: nil, width: thumbnail.width, height: thumbnail.height,
                bitsPerComponent: 8, bytesPerRow: thumbnail.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PrintCropError.missingImage }
        // Decode once into a conventional RGBA bitmap, avoiding TIFF/HDR conversion
        // and disk reads whenever SwiftUI updates the corner overlay.
        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
        guard let image = context.makeImage() else { throw PrintCropError.missingImage }
        return image
    }
    static func detect(_ source: CIImage) throws -> [PrintBoundary] {
        let scale = min(1, 1600 / max(source.extent.width, source.extent.height))
        let reduced = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = FlatField.context().createCGImage(reduced, from: reduced.extent,
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw PrintCropError.missingImage }
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        let document = VNDetectDocumentSegmentationRequest()
        // Document segmentation handles prints whose edges don't produce a strong
        // enough rectangle response. Rectangle candidates remain available below.
        var candidates: [PrintBoundary] = []
        if (try? handler.perform([document])) != nil {
            candidates = (document.results ?? []).filter { $0.confidence >= 0.6 }
                .map(boundary).filter(\.valid)
        }
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 8
        request.minimumConfidence = 0.6
        request.minimumSize = 0.15
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1
        request.quadratureTolerance = 30
        do { try handler.perform([request]) }
        catch { if candidates.isEmpty { throw error } }
        for candidate in (request.results ?? []).map(boundary).filter(\.valid) {
            let duplicate = candidates.contains { existing in
                zip(existing.corners, candidate.corners).allSatisfy { a, b in hypot(a.x - b.x, a.y - b.y) < 0.02 }
            }
            if !duplicate { candidates.append(candidate) }
        }
        return Array(candidates.prefix(8))
    }
    private static func boundary(_ observation: VNRectangleObservation) -> PrintBoundary {
        PrintBoundary(corners: [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
            .map { CGPoint(x: $0.x, y: 1 - $0.y) })
    }
    static func corrected(_ source: CIImage, boundary: PrintBoundary) throws -> CIImage {
        guard boundary.valid else { throw PrintCropError.invalidBoundary }
        let points = boundary.corners.map { CGPoint(x: $0.x * source.extent.width, y: (1 - $0.y) * source.extent.height) }
        let result = source.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": CIVector(cgPoint: points[0]), "inputTopRight": CIVector(cgPoint: points[1]),
            "inputBottomRight": CIVector(cgPoint: points[2]), "inputBottomLeft": CIVector(cgPoint: points[3])])
        guard !result.extent.isEmpty, !result.extent.isInfinite else { throw PrintCropError.invalidBoundary }
        let inset = ceil(min(result.extent.width, result.extent.height) * edgeTrimFraction)
        // Round inward so TIFF rasterization cannot reintroduce an outside pixel.
        let trimmed = result.extent.insetBy(dx: inset, dy: inset)
        let bounds = CGRect(x: ceil(trimmed.minX), y: ceil(trimmed.minY),
                            width: floor(trimmed.maxX) - ceil(trimmed.minX),
                            height: floor(trimmed.maxY) - ceil(trimmed.minY))
        guard bounds.width >= 1, bounds.height >= 1 else { throw PrintCropError.invalidBoundary }
        return result.cropped(to: bounds)
            .transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
    }
    static func save(originalURL: URL, sourceURL: URL, boundary: PrintBoundary) throws -> URL {
        let folder = originalURL.deletingLastPathComponent()
        guard sourceURL.deletingLastPathComponent() == folder,
              let side = ScanSide(rawValue: originalURL.deletingPathExtension().lastPathComponent) else { throw PrintCropError.missingImage }
        let metadataURL = folder.appendingPathComponent("metadata.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(ScanManifest.self, from: Data(contentsOf: metadataURL))
        let output = try corrected(image(url: sourceURL), boundary: boundary)
        let name = side.rawValue + "-cropped-" + UUID().uuidString + ".tiff"
        let destination = folder.appendingPathComponent(name)
        do {
            try FlatField.context().writeTIFFRepresentation(of: output, to: destination, format: .RGBA16,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
            guard let image = CGImageSourceCreateWithURL(destination as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? Int else { throw PrintCropError.missingImage }
            if manifest.crops == nil { manifest.crops = [:] }
            manifest.crops?[side.rawValue] = CropRecord(sourceFile: sourceURL.lastPathComponent, outputFile: name,
                corners: boundary.corners, width: width, height: height)
            try ScanArchive.writeJSON(manifest, to: metadataURL)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
