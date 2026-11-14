import Foundation
import CoreImage

// Relative camera measurements, not an absolute Kelvin or perceptual Delta E meter.
struct LightReading: Equatable, Sendable {
    let rgb: [Double] // Linear sRGB, independent of display gamma.
    var brightness: Double { rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722 }
    var chroma: [Double] { let sum = rgb.reduce(0, +); return rgb.map { $0 / sum } }
    func difference(from reference: LightReading) -> Double {
        sqrt(zip(chroma, reference.chroma).reduce(0) { $0 + pow($1.0 - $1.1, 2) }) * 100
    }
    func warmth(from reference: LightReading) -> Double {
        log(rgb[0] / rgb[2]) - log(reference.rgb[0] / reference.rgb[2])
    }
    func tint(from reference: LightReading) -> Double {
        log(rgb[1] / sqrt(rgb[0] * rgb[2])) - log(reference.rgb[1] / sqrt(reference.rgb[0] * reference.rgb[2]))
    }
    static func measure(data: Data, selection: CGRect) throws -> LightReading {
        guard selection.width >= 0.02, selection.height >= 0.02,
              selection.minX >= 0, selection.minY >= 0, selection.maxX <= 1, selection.maxY <= 1,
              let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw LightMeasurementError.message("Select an area inside the gray card.")
        }
        let e = image.extent
        let rect = CGRect(x: e.minX + selection.minX * e.width, y: e.minY + (1 - selection.maxY) * e.height,
                          width: selection.width * e.width, height: selection.height * e.height)
        guard rect.width >= 8, rect.height >= 8 else { throw LightMeasurementError.message("Select a larger gray area.") }
        let patch = image.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .transformed(by: CGAffineTransform(scaleX: 32 / rect.width, y: 32 / rect.height))
        var pixels = [Float](repeating: 0, count: 32 * 32 * 4)
        pixels.withUnsafeMutableBytes {
            context.render(patch, toBitmap: $0.baseAddress!, rowBytes: 32 * 16,
                           bounds: CGRect(x: 0, y: 0, width: 32, height: 32), format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
        }
        var means: [Double] = []
        for channel in 0..<3 {
            let values = stride(from: channel, to: pixels.count, by: 4).map { Double(pixels[$0]) }
            guard values.allSatisfy({ $0.isFinite && $0 > 0.008 }) else {
                throw LightMeasurementError.message("Sample is too dark. Check the active light or restart with more exposure.")
            }
            guard values.allSatisfy({ $0 < 0.92 }) else {
                throw LightMeasurementError.message("Sample is near clipping. Restart with less exposure or dimmer lights.")
            }
            let mean = values.reduce(0, +) / Double(values.count)
            let deviation = sqrt(values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count))
            guard deviation / mean < 0.10 else {
                throw LightMeasurementError.message("Sample is uneven. Select a uniform area away from edges, shadows, and glare.")
            }
            means.append(mean)
        }
        return LightReading(rgb: means)
    }
    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])
}
enum LightMeasurementError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct LightReadingWindow {
    private var entries: [(Date, LightReading)] = []
    mutating func reset() { entries.removeAll() }
    mutating func add(_ reading: LightReading, at time: Date) {
        if let last = entries.last, time.timeIntervalSince(last.0) > 1 { reset() }
        entries.append((time, reading))
        entries = entries.filter { time.timeIntervalSince($0.0) <= 2.5 }
    }
    var average: LightReading? {
        guard entries.count >= 5, let first = entries.first, let last = entries.last,
              last.0.timeIntervalSince(first.0) >= 1.2 else { return nil }
        let mean = LightReading(rgb: (0..<3).map { channel in entries.reduce(0) { $0 + $1.1.rgb[channel] } / Double(entries.count) })
        guard entries.allSatisfy({ $0.1.difference(from: mean) < 0.6 && abs($0.1.brightness / mean.brightness - 1) < 0.05 }) else { return nil }
        return mean
    }
}
