import CoreImage
import Foundation

struct FlatFieldProfile: Codable, Sendable {
    var version = 1
    let id: UUID
    let reference: CaptureInfo
    let gridWidth: Int
    let gridHeight: Int
    let gains: [Float]

    func matches(_ info: CaptureInfo) -> Bool {
        info.hasSameLockedSetup(as: reference)
    }
}

enum FlatFieldError: LocalizedError {
    case invalidReference(reason: String? = nil), incompatible, invalidImage
    var errorDescription: String? {
        switch self {
        case .invalidReference(let reason):
            if let reason {
                "Reference is too dark, clipped, or uneven.\n" + reason + "\nUse a blank matte neutral sheet filling the frame, with settings locked."
            } else {
                "Reference is too dark, clipped, or uneven. Use a blank matte neutral sheet filling the frame, with settings locked."
            }
        case .incompatible: "Flat-field settings or dimensions do not match. Capture a new reference or turn off correction."
        case .invalidImage: "Could not decode the captured image."
        }
    }
}

enum FlatField {
    static let allowedGains: ClosedRange<Float> = 0.25...4
    static var linear: CGColorSpace { CGColorSpace(name: CGColorSpace.extendedLinearSRGB)! }
    static func context() -> CIContext {
        CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf])
    }
    static func image(_ data: Data) throws -> CIImage {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]), !image.extent.isEmpty else {
            throw FlatFieldError.invalidImage
        }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
    static func format(_ value: Float) -> String {
        String(format: "%.3f", value)
    }
    static func invalidReference(_ reason: String) -> FlatFieldError {
        .invalidReference(reason: reason)
    }
    static func makeProfile(data: Data, info: CaptureInfo) throws -> FlatFieldProfile {
        guard info.settings?.locked == true else {
            throw invalidReference("Diagnostics: camera settings were not locked for this capture.")
        }
        let source = try image(data)
        let width = 64
        let height = max(2, Int((Double(width) * source.extent.height / source.extent.width).rounded()))
        let reduced = source.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / source.extent.width,
                                                              y: CGFloat(height) / source.extent.height))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let smooth = reduced.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.0]).cropped(to: bounds)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            context().render(smooth, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: bounds, format: .RGBAf, colorSpace: linear)
        }
        var luminance = [Float]()
        var minChannel = Float.greatestFiniteMagnitude
        var maxChannel = -Float.greatestFiniteMagnitude
        var minLuminance = Float.greatestFiniteMagnitude
        var maxLuminance = -Float.greatestFiniteMagnitude
        var nonFinite = 0
        var dark = 0
        var clipped = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = pixels[offset]
            let green = pixels[offset + 1]
            let blue = pixels[offset + 2]
            for channel in [red, green, blue] {
                if channel.isFinite {
                    minChannel = min(minChannel, channel)
                    maxChannel = max(maxChannel, channel)
                    if channel <= 0.015 { dark += 1 }
                    if channel >= 0.95 { clipped += 1 }
                } else {
                    nonFinite += 1
                }
            }
            let value = red * 0.2126 + green * 0.7152 + blue * 0.0722
            if value.isFinite {
                minLuminance = min(minLuminance, value)
                maxLuminance = max(maxLuminance, value)
                luminance.append(value)
            } else {
                nonFinite += 1
            }
        }
        guard nonFinite == 0, dark == 0, clipped == 0 else {
            throw invalidReference("Diagnostics: grid \(width)x\(height); RGB range \(format(minChannel))...\(format(maxChannel)); dark channel samples \(dark); clipped channel samples \(clipped); non-finite samples \(nonFinite).")
        }
        let mean = luminance.reduce(0, +) / Float(luminance.count)
        let gains = luminance.map { mean / $0 }
        let minGain = gains.min() ?? .nan
        let maxGain = gains.max() ?? .nan
        guard gains.allSatisfy({ allowedGains.contains($0) }) else {
            throw invalidReference("Diagnostics: grid \(width)x\(height); luminance range \(format(minLuminance))...\(format(maxLuminance)); mean \(format(mean)); correction gain range \(format(minGain))...\(format(maxGain)) (allowed \(format(allowedGains.lowerBound))...\(format(allowedGains.upperBound))).")
        }
        return FlatFieldProfile(id: UUID(), reference: info, gridWidth: width, gridHeight: height, gains: gains)
    }
    static func corrected(_ source: CIImage, profile: FlatFieldProfile) throws -> CIImage {
        guard profile.version == 1, profile.gridWidth > 0, profile.gridHeight > 0,
              profile.gains.count == profile.gridWidth * profile.gridHeight,
              profile.gains.allSatisfy({ $0.isFinite && allowedGains.contains($0) }) else { throw FlatFieldError.invalidReference() }
        let pixels = profile.gains.flatMap { [$0, $0, $0, Float(1)] }
        let data = pixels.withUnsafeBytes { Data($0) }
        let field = CIImage(bitmapData: data, bytesPerRow: profile.gridWidth * 16,
            size: CGSize(width: profile.gridWidth, height: profile.gridHeight), format: .RGBAf, colorSpace: linear)
        let scaled = field.clampedToExtent().transformed(by: CGAffineTransform(
            scaleX: source.extent.width / CGFloat(profile.gridWidth), y: source.extent.height / CGFloat(profile.gridHeight)))
            .cropped(to: source.extent)
        return source.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: scaled]).cropped(to: source.extent)
    }
    static func writeCorrection(data: Data, info: CaptureInfo, profile: FlatFieldProfile, to url: URL) throws {
        guard profile.matches(info) else { throw FlatFieldError.incompatible }
        let output = try corrected(image(data), profile: profile)
        try context().writeTIFFRepresentation(of: output, to: url, format: .RGBA16,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
    }
}
