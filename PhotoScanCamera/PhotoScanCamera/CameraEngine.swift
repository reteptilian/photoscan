import AVFoundation
import Foundation
import ImageIO

struct CameraPhoto: Sendable {
    let data: Data
    let width: Int
    let height: Int
    let fileExtension: String
    let settings: CameraSettings?
    let iso: Double?
    let exposureSeconds: Double?
}

final class CameraEngine: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "photoscan.camera")
    private let output = AVCapturePhotoOutput()
    private var completion: (@Sendable (Result<CameraPhoto, Error>) -> Void)?
    private var result: Result<CameraPhoto, Error>?
    private var device: AVCaptureDevice?
    private var changingSettings = false
    private var captureSettings: CameraSettings?
    private var fileExtension = "heic"

    func start(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async {
            do {
                self.session.beginConfiguration()
                defer { self.session.commitConfiguration() }
                self.session.sessionPreset = .photo
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                    throw CameraError.unavailable
                }
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input), self.session.canAddOutput(self.output) else {
                    throw CameraError.unavailable
                }
                self.session.addInput(input)
                self.session.addOutput(self.output)
                self.device = device
                if let dimensions = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
                    Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
                }) { self.output.maxPhotoDimensions = dimensions }
                self.output.maxPhotoQualityPrioritization = .quality
            } catch { completion(.failure(error)); return }
            self.session.startRunning()
            completion(.success(()))
        }
    }
    func readSettings(completion: @escaping @Sendable (CameraSettings?) -> Void) {
        queue.async { completion(self.snapshot()) }
    }

    private func snapshot() -> CameraSettings? {
        guard let device else { return nil }
        let gains = device.deviceWhiteBalanceGains
        let balance = device.temperatureAndTintValues(for: gains)
        let dimensions = output.maxPhotoDimensions
        return CameraSettings(
            locked: device.focusMode == .locked && device.exposureMode == .locked && device.whiteBalanceMode == .locked,
            iso: Double(device.iso), exposureSeconds: CMTimeGetSeconds(device.exposureDuration),
            focusPosition: Double(device.lensPosition), whiteBalanceTemperature: Double(balance.temperature),
            whiteBalanceTint: Double(balance.tint), redGain: Double(gains.redGain),
            greenGain: Double(gains.greenGain), blueGain: Double(gains.blueGain),
            width: Int(dimensions.width), height: Int(dimensions.height))
    }

    func setLocked(_ locked: Bool, completion: @escaping @Sendable (Result<CameraSettings, Error>) -> Void) {
        queue.async {
            guard let device = self.device, self.session.isRunning, self.completion == nil, !self.changingSettings else {
                completion(.failure(CameraError.unavailable)); return
            }
            guard device.isFocusModeSupported(.locked), device.isExposureModeSupported(.locked),
                  device.isWhiteBalanceModeSupported(.locked), device.isFocusModeSupported(.continuousAutoFocus),
                  device.isExposureModeSupported(.continuousAutoExposure), device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else {
                completion(.failure(CameraError.unsupported)); return
            }
            self.changingSettings = true
            if locked {
                self.waitForSettling(deadline: Date().addingTimeInterval(8), stableSamples: 0, completion: completion)
            } else {
                self.applyLock(false, completion: completion)
            }
        }
    }

    private func waitForSettling(deadline: Date, stableSamples: Int, completion: @escaping @Sendable (Result<CameraSettings, Error>) -> Void) {
        guard let device, session.isRunning else {
            changingSettings = false; completion(.failure(CameraError.unavailable)); return
        }
        let adjusting = device.isAdjustingFocus || device.isAdjustingExposure || device.isAdjustingWhiteBalance
        let samples = adjusting ? 0 : stableSamples + 1
        if samples >= 5 { applyLock(true, completion: completion); return }
        guard Date() < deadline else {
            changingSettings = false; completion(.failure(CameraError.notSettled)); return
        }
        queue.asyncAfter(deadline: .now() + 0.1) {
            self.waitForSettling(deadline: deadline, stableSamples: samples, completion: completion)
        }
    }

    private func applyLock(_ locked: Bool, completion: @escaping @Sendable (Result<CameraSettings, Error>) -> Void) {
        do {
            guard let device else { throw CameraError.unavailable }
            try device.lockForConfiguration()
            device.focusMode = locked ? .locked : .continuousAutoFocus
            device.exposureMode = locked ? .locked : .continuousAutoExposure
            device.whiteBalanceMode = locked ? .locked : .continuousAutoWhiteBalance
            device.unlockForConfiguration()
            changingSettings = false
            guard let settings = snapshot() else { throw CameraError.unavailable }
            completion(.success(settings))
        } catch { changingSettings = false; completion(.failure(error)) }
    }

    func capture(completion: @escaping @Sendable (Result<CameraPhoto, Error>) -> Void) {
        queue.async {
            guard self.session.isRunning, self.completion == nil, !self.changingSettings else {
                completion(.failure(CameraError.unavailable)); return
            }
            self.completion = completion
            self.result = nil
            self.captureSettings = self.snapshot()
            let codec: AVVideoCodecType = self.output.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
            self.fileExtension = codec == .hevc ? "heic" : "jpg"
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
            settings.maxPhotoDimensions = self.output.maxPhotoDimensions
            settings.photoQualityPrioritization = .quality
            settings.flashMode = .off
            if let connection = self.output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        queue.async { self.captureSettings = self.snapshot() }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        let dimensions = photo.resolvedSettings.photoDimensions
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let iso = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue
        let exposure = (exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
        queue.async {
            if let error { self.result = .failure(error) }
            else if let data {
                self.result = .success(CameraPhoto(data: data, width: Int(dimensions.width), height: Int(dimensions.height),
                    fileExtension: self.fileExtension, settings: self.captureSettings, iso: iso, exposureSeconds: exposure))
            }
            else { self.result = .failure(CameraError.noImage) }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        queue.async {
            let completion = self.completion
            self.completion = nil
            completion?(error.map { .failure($0) } ?? self.result ?? .failure(CameraError.noImage))
            self.result = nil
        }
    }
}
enum CameraError: LocalizedError {
    case unavailable, noImage, unsupported, notSettled
    var errorDescription: String? {
        switch self {
        case .unavailable: "Camera is unavailable or busy."
        case .noImage: "The camera did not produce an image."
        case .unsupported: "This camera does not support locking all three settings."
        case .notSettled: "Camera settings did not settle. Keep the phone and lighting steady, then try again."
        }
    }
}
