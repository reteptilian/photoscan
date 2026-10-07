import CoreImage
import Foundation

@main
struct FlatFieldSmoke {
    static func pixels(_ image: CIImage) -> [Float] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var values = [Float](repeating: 0, count: width * height * 4)
        values.withUnsafeMutableBytes {
            FlatField.context().render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                bounds: image.extent, format: .RGBAf, colorSpace: FlatField.linear)
        }
        return values
    }
    static func main() throws {
        let width = 128, height = 96
        var values = [Float]()
        for y in 0..<height {
            for x in 0..<width {
                let brightness = Float(0.25 + 0.3 * Double(x) / Double(width - 1) + 0.08 * Double(y) / Double(height - 1))
                values += [brightness, brightness, brightness, 1]
            }
        }
        let data = values.withUnsafeBytes { Data($0) }
        let reference = CIImage(bitmapData: data, bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: FlatField.linear)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let encoded = FlatField.context().jpegRepresentation(of: reference, colorSpace: colorSpace, options: [:])!
        let settings = CameraSettings(locked: true, iso: 80, exposureSeconds: 1.0 / 60, focusPosition: 0.4,
            whiteBalanceTemperature: 5000, whiteBalanceTint: 2, redGain: 1.4, greenGain: 1, blueGain: 1.6, width: width, height: height)
        let info = CaptureInfo(request: CaptureRequest(assetID: UUID(), side: .front), capturedAt: Date(),
            fileExtension: "jpg", width: width, height: height, camera: "Main", settings: settings)
        let profile = try FlatField.makeProfile(data: encoded, info: info)
        let corrected = try FlatField.corrected(FlatField.image(encoded), profile: profile)
        let output = pixels(corrected)
        let red = stride(from: 0, to: output.count, by: 4).map { output[$0] }
        precondition(red.max()! - red.min()! < 0.05, "Correction should remove the synthetic illumination gradient")
        let tinted = reference.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.8, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.4, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.2, w: 0)])
        let tintedOutput = pixels(try FlatField.corrected(tinted, profile: profile))
        precondition(abs(tintedOutput[0] / tintedOutput[1] - 2) < 0.02, "Correction must preserve color ratios")
        var mismatch = CaptureInfo(request: CaptureRequest(assetID: UUID(), side: .front), capturedAt: Date(),
            fileExtension: "jpg", width: width + 1, height: height, camera: "Main", settings: settings)
        precondition(!profile.matches(mismatch))
        let dark = FlatField.context().jpegRepresentation(of: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: reference.extent), colorSpace: colorSpace, options: [:])!
        do {
            _ = try FlatField.makeProfile(data: dark, info: info)
            fatalError("Accepted a dark reference")
        } catch FlatFieldError.invalidReference {}
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let savedProfile = try ScanArchive.saveReference(info, data: encoded, folder: folder)
        let asset = try ScanArchive.save(info, data: encoded, folder: folder, profile: savedProfile)
        let originalBytes = try Data(contentsOf: asset.appendingPathComponent("sources/capture.jpg"))
        precondition(originalBytes == encoded)
        var manifest = try ScanArchive.read(asset)
        precondition(manifest.recipe.flatField?.id == savedProfile.id && manifest.finished == nil)
        manifest.recipe.cropReviewed = true
        let finishedURL = try ScanArchive.regenerate(asset: asset, recipe: manifest.recipe)
        precondition(FileManager.default.fileExists(atPath: finishedURL.path))
        mismatch = CaptureInfo(request: CaptureRequest(assetID: UUID(), side: .front), capturedAt: Date(),
            fileExtension: "jpg", width: width + 1, height: height, camera: "Main", settings: settings)
        let pending = try ScanArchive.save(mismatch, data: encoded, folder: folder, profile: savedProfile)
        var recipe = try ScanArchive.read(pending).recipe; recipe.cropReviewed = true
        do {
            _ = try ScanArchive.regenerate(asset: pending, recipe: recipe)
            fatalError("Accepted an incompatible reference")
        } catch FlatFieldError.incompatible {}
        let preserved = try Data(contentsOf: pending.appendingPathComponent("sources/capture.jpg"))
        precondition(preserved == encoded)
        let failed = try ScanArchive.read(pending)
        precondition(failed.finished == nil)
        print("Flat-field correction and archive tests passed")
    }
}
