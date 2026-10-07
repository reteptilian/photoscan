import CoreImage
import Foundation

enum DKCGrayTarget: String, Codable, CaseIterable, Sendable {
    case gray12 = "DKC-Pro 12% gray"
    case gray18 = "DKC-Pro 18% gray"
}

struct GrayBalanceProfile: Codable, Sendable {
    var version = 1
    let id: UUID
    let reference: CaptureInfo
    let target: DKCGrayTarget
    let selection: CGRect
    let measuredRGB: [Double]
    let gains: [Double]
    func matches(_ info: CaptureInfo) -> Bool { info.hasSameLockedSetup(as: reference) }
}

enum GrayBalanceError: LocalizedError {
    case invalidSample, incompatible
    var errorDescription: String? {
        switch self {
        case .invalidSample: "Select a uniform interior area of a neutral gray patch, away from labels, edges and glare. Settings must be locked."
        case .incompatible: "Gray-balance settings do not match. Capture a new chart or turn off gray balance."
        }
    }
}

enum GrayBalance {
    // Selection uses normalized top-left coordinates, matching the displayed oriented image.
    static func makeProfile(data: Data, info: CaptureInfo, target: DKCGrayTarget, selection: CGRect) throws -> GrayBalanceProfile {
        guard info.settings?.locked == true, selection.width >= 0.005, selection.height >= 0.005,
              selection.minX >= 0, selection.minY >= 0, selection.maxX <= 1, selection.maxY <= 1 else {
            throw GrayBalanceError.invalidSample
        }
        let source = try FlatField.image(data)
        let extent = source.extent
        let region = CGRect(x: selection.minX * extent.width, y: (1 - selection.maxY) * extent.height,
                            width: selection.width * extent.width, height: selection.height * extent.height)
        guard region.width >= 8, region.height >= 8 else { throw GrayBalanceError.invalidSample }
        let sample = source.cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .transformed(by: CGAffineTransform(scaleX: 32 / region.width, y: 32 / region.height))
        var pixels = [Float](repeating: 0, count: 32 * 32 * 4)
        pixels.withUnsafeMutableBytes {
            FlatField.context().render(sample, toBitmap: $0.baseAddress!, rowBytes: 32 * 16,
                bounds: CGRect(x: 0, y: 0, width: 32, height: 32), format: .RGBAf, colorSpace: FlatField.linear)
        }
        var means = [Double](repeating: 0, count: 3)
        for channel in 0..<3 {
            let values = stride(from: channel, to: pixels.count, by: 4).map { Double(pixels[$0]) }
            guard values.allSatisfy({ $0.isFinite && $0 > 0.01 && $0 < 0.95 }) else { throw GrayBalanceError.invalidSample }
            let mean = values.reduce(0, +) / Double(values.count)
            let deviation = sqrt(values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count))
            guard deviation / mean < 0.08 else { throw GrayBalanceError.invalidSample }
            means[channel] = mean
        }
        let luminance = means[0] * 0.2126 + means[1] * 0.7152 + means[2] * 0.0722
        let gains = means.map { luminance / $0 }
        guard gains.allSatisfy({ $0 >= 0.5 && $0 <= 2 }) else { throw GrayBalanceError.invalidSample }
        return GrayBalanceProfile(id: UUID(), reference: info, target: target, selection: selection, measuredRGB: means, gains: gains)
    }
    static func corrected(_ source: CIImage, profile: GrayBalanceProfile) throws -> CIImage {
        guard profile.version == 1, profile.gains.count == 3,
              profile.gains.allSatisfy({ $0.isFinite && $0 >= 0.5 && $0 <= 2 }) else { throw GrayBalanceError.invalidSample }
        return source.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: profile.gains[0], y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: profile.gains[1], z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: profile.gains[2], w: 0)])
    }
}
