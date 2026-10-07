import CoreImage
import Foundation
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
    case invalidBoundary, missingImage, emptySelection, overlapping
    var errorDescription: String? {
        switch self {
        case .invalidBoundary: "Crop corners must form a non-crossing rectangle inside the image."
        case .emptySelection: "Add at least one print boundary before extraction."
        case .overlapping: "Print boundaries overlap. Adjust or remove overlapping suggestions before extraction."
        case .missingImage: "The saved image or its archive metadata could not be read."
        }
    }
}
enum PrintCrop {
    // Trim inside the rectified boundary to remove background, edge shadows,
    // and interpolation pixels. Scale with the print, not the full camera frame.
    static let edgeTrimFraction: CGFloat = 0.025
    static func validateSelection(_ boundaries: [PrintBoundary]) throws {
        guard !boundaries.isEmpty else { throw PrintCropError.emptySelection }
        guard boundaries.allSatisfy(\.valid) else { throw PrintCropError.invalidBoundary }
        for i in boundaries.indices {
            for j in boundaries.indices where j > i {
                // Separating axis theorem for convex quadrilaterals; touching edges are allowed.
                let a = boundaries[i].corners, b = boundaries[j].corners
                let separated = [a, b].contains { polygon in
                    (0..<4).contains { k in
                        let p = polygon[k], q = polygon[(k + 1) % 4]
                        let axis = CGPoint(x: -(q.y - p.y), y: q.x - p.x)
                        let ap = a.map { $0.x * axis.x + $0.y * axis.y }
                        let bp = b.map { $0.x * axis.x + $0.y * axis.y }
                        return ap.max()! <= bp.min()! + 1e-9 || bp.max()! <= ap.min()! + 1e-9
                    }
                }
                if !separated { throw PrintCropError.overlapping }
            }
        }
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
        candidates.append(contentsOf: (request.results ?? []).map(boundary).filter(\.valid))
        return Array(consolidated(candidates).prefix(8))
    }
    static func area(_ polygon: [CGPoint]) -> CGFloat {
        guard polygon.count >= 3 else { return 0 }
        return abs(polygon.indices.reduce(CGFloat.zero) { sum, i in
            let p = polygon[i], q = polygon[(i + 1) % polygon.count]
            return sum + p.x * q.y - q.x * p.y
        }) / 2
    }
    static func intersectionArea(_ a: PrintBoundary, _ b: PrintBoundary) -> CGFloat {
        // Clip a convex polygon by each clockwise edge in top-left image coordinates.
        var polygon = a.corners
        for i in 0..<4 {
            let p = b.corners[i], q = b.corners[(i + 1) % 4]
            func distance(_ r: CGPoint) -> CGFloat { (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) }
            let input = polygon; polygon = []
            guard !input.isEmpty else { return 0 }
            var previous = input.last!, previousDistance = distance(previous)
            for current in input {
                let currentDistance = distance(current)
                if (currentDistance >= 0) != (previousDistance >= 0) {
                    let t = previousDistance / (previousDistance - currentDistance)
                    polygon.append(CGPoint(x: previous.x + t * (current.x - previous.x),
                                           y: previous.y + t * (current.y - previous.y)))
                }
                if currentDistance >= 0 { polygon.append(current) }
                previous = current; previousDistance = currentDistance
            }
        }
        return area(polygon)
    }
    static func consolidated(_ candidates: [PrintBoundary]) -> [PrintBoundary] {
        // Prefer the outer print boundary over a slightly inset duplicate or a
        // rectangle formed by details inside the photograph. Partial overlaps
        // remain visible for review, rather than guessing which print to discard.
        let ordered = candidates.filter(\.valid).enumerated().sorted {
            let a = area($0.element.corners), b = area($1.element.corners)
            return a == b ? $0.offset < $1.offset : a > b
        }
        var retained: [(Int, PrintBoundary)] = []
        for (index, candidate) in ordered {
            let candidateArea = area(candidate.corners)
            let duplicate = retained.contains { _, existing in
                let intersection = intersectionArea(candidate, existing)
                let union = candidateArea + area(existing.corners) - intersection
                return intersection / candidateArea >= 0.9 || intersection / union >= 0.75
            }
            if !duplicate { retained.append((index, candidate)) }
        }
        // Keep detector ordering stable for numbered review and archive indices.
        return retained.sorted { $0.0 < $1.0 }.map { $0.1 }
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
        // Round inward so rasterization cannot reintroduce an outside pixel.
        let trimmed = result.extent.insetBy(dx: inset, dy: inset)
        let bounds = CGRect(x: ceil(trimmed.minX), y: ceil(trimmed.minY),
                            width: floor(trimmed.maxX) - ceil(trimmed.minX),
                            height: floor(trimmed.maxY) - ceil(trimmed.minY))
        guard bounds.width >= 1, bounds.height >= 1 else { throw PrintCropError.invalidBoundary }
        return result.cropped(to: bounds)
            .transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
    }
}
