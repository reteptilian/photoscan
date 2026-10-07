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
    case invalidReference, incompatible, invalidImage
    var errorDescription: String? {
        switch self {
        case .invalidReference: "Reference is too dark, clipped, or uneven. Use a blank matte neutral sheet filling the frame, with settings locked."
        case .incompatible: "Flat-field settings or dimensions do not match. Capture a new reference or turn off correction."
        case .invalidImage: "Could not decode the captured image."
        }
    }
}

enum FlatField {
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
    static func makeProfile(data: Data, info: CaptureInfo) throws -> FlatFieldProfile {
        guard info.settings?.locked == true else { throw FlatFieldError.invalidReference }
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
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = Array(pixels[offset..<(offset + 3)])
            guard rgb.allSatisfy({ $0.isFinite && $0 > 0.015 && $0 < 0.95 }) else { throw FlatFieldError.invalidReference }
            luminance.append(rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722)
        }
        let mean = luminance.reduce(0, +) / Float(luminance.count)
        let gains = luminance.map { mean / $0 }
        guard gains.allSatisfy({ $0 >= 0.5 && $0 <= 2 }) else { throw FlatFieldError.invalidReference }
        return FlatFieldProfile(id: UUID(), reference: info, gridWidth: width, gridHeight: height, gains: gains)
    }
    static func corrected(_ source: CIImage, profile: FlatFieldProfile) throws -> CIImage {
        guard profile.version == 1, profile.gridWidth > 0, profile.gridHeight > 0,
              profile.gains.count == profile.gridWidth * profile.gridHeight,
              profile.gains.allSatisfy({ $0.isFinite && $0 >= 0.5 && $0 <= 2 }) else { throw FlatFieldError.invalidReference }
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
