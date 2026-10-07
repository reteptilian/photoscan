import CoreImage
import Foundation

@main
struct GrayBalanceSmoke {
    static func mean(_ image: CIImage) -> [Double] {
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            FlatField.context().render(average, toBitmap: $0.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: FlatField.linear)
        }
        return pixel.prefix(3).map(Double.init)
    }
    static func main() throws {
        let bounds = CGRect(x: 0, y: 0, width: 128, height: 128)
        let gray = CIImage(color: CIColor(red: 0.18, green: 0.24, blue: 0.30, colorSpace: FlatField.linear)!).cropped(to: bounds)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0, colorSpace: FlatField.linear)!).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 64))
        let chart = red.composited(over: gray)
        let data = FlatField.context().jpegRepresentation(of: chart, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])!
        let settings = CameraSettings(locked: true, iso: 80, exposureSeconds: 1.0 / 60, focusPosition: 0.4,
            whiteBalanceTemperature: 5000, whiteBalanceTint: 2, redGain: 1.4, greenGain: 1, blueGain: 1.6, width: 128, height: 128)
        let info = CaptureInfo(request: CaptureRequest(assetID: UUID(), side: .front), capturedAt: Date(),
            fileExtension: "jpg", width: 128, height: 128, camera: "Main", settings: settings)
        let roi = CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.3)
        let profile = try GrayBalance.makeProfile(data: data, info: info, target: .gray18, selection: roi)
        let corrected = mean(try GrayBalance.corrected(gray, profile: profile))
        precondition(corrected.max()! - corrected.min()! < 0.005, "Gray sample should become neutral")
        let luminance = 0.18 * 0.2126 + 0.24 * 0.7152 + 0.30 * 0.0722
        precondition(abs(corrected[0] - luminance) < 0.005, "Preserve measured luminance rather than forcing 18%")
        let twelve = try GrayBalance.makeProfile(data: data, info: info, target: .gray12, selection: roi)
        precondition(twelve.gains == profile.gains, "Reflectance labels must not change white-balance gains")
        for selection in [CGRect(x: 0.2, y: 0.7, width: 0.3, height: 0.2), CGRect.zero,
                          CGRect(x: -0.1, y: 0.1, width: 0.3, height: 0.3)] {
            do {
                _ = try GrayBalance.makeProfile(data: data, info: info, target: .gray18, selection: selection)
                fatalError("Accepted an invalid sample")
            } catch GrayBalanceError.invalidSample {}
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stored = try ScanArchive.saveGrayReference(info, data: data, folder: folder, target: .gray18, selection: roi)
        let flat = FlatFieldProfile(id: UUID(), reference: info, gridWidth: 2, gridHeight: 2, gains: [1, 1, 1, 1])
        let original = try ScanArchive.save(info, data: data, folder: folder, profile: flat, grayBalance: stored)
        let bytes = try Data(contentsOf: original)
        precondition(bytes == data)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ScanManifest.self, from: Data(contentsOf: original.deletingLastPathComponent().appendingPathComponent("metadata.json")))
        precondition(manifest.grayBalanceID == stored.id && manifest.flatFieldID == flat.id)
        let output = try FlatField.image(Data(contentsOf: original.deletingLastPathComponent().appendingPathComponent("front-corrected.tiff")))
        let outputGray = mean(output.cropped(to: CGRect(x: 30, y: 90, width: 30, height: 20)))
        precondition(outputGray.max()! - outputGray.min()! < 0.005)
        var incompatible = info
        incompatible.settings = nil
        precondition(!profile.matches(incompatible))
        print("DKC-Pro gray-balance and combined archive tests passed")
    }
}
