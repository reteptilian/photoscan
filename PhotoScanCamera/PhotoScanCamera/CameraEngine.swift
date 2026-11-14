import AVFoundation
import Foundation
import ImageIO
import CoreImage

struct CameraPhoto: Sendable {
    let data: Data
    let width: Int
    let height: Int
    let fileExtension: String
    let settings: CameraSettings?
    let iso: Double?
    let exposureSeconds: Double?
}

final class CameraEngine: NSObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    static var isMock: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
    static var cameraName: String { isMock ? "Mock camera" : "Main wide-angle camera" }
    let session = AVCaptureSession()
    private var mockPhoto: CameraPhoto?
    private var mockLocked = false
    private let queue = DispatchQueue(label: "photoscan.camera")
    private let output = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let previewContext = CIContext()
    private var previewData: Data?
    private var previewSettings: CameraSettings?
    private var previewTime: TimeInterval = 0
    private var previewUntil: TimeInterval = 0
    private var sessionID = UUID()
    private var lockValid = true
    private var observers: [NSObjectProtocol] = []
    private var completion: (@Sendable (Result<CameraPhoto, Error>) -> Void)?
    private var result: Result<CameraPhoto, Error>?
    private var device: AVCaptureDevice?
    private var changingSettings = false
    private var captureSettings: CameraSettings?
    private var fileExtension = "heic"

    func start(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            if Self.isMock {
                do {
                    self.mockPhoto = try Self.makeMockPhoto()
                    completion(.success(()))
                } catch { completion(.failure(error)) }
                return
            }
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
                guard self.session.canAddOutput(self.videoOutput) else { throw CameraError.unavailable }
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                self.videoOutput.setSampleBufferDelegate(self, queue: self.queue)
                self.session.addOutput(self.videoOutput)
                if let connection = self.videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
                for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification,
                             AVCaptureSession.didStopRunningNotification] {
                    self.observers.append(NotificationCenter.default.addObserver(forName: name, object: self.session, queue: nil) { [weak self] _ in
                        guard let self else { return }
                        self.queue.async {
                            self.lockValid = false; self.sessionID = UUID()
                            self.previewData = nil; self.previewSettings = nil
                        }
                    })
                }
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
        if Self.isMock {
            guard let photo = mockPhoto else { return nil }
            return CameraSettings(locked: mockLocked, iso: 100, exposureSeconds: 1.0 / 60,
                focusPosition: 0.5, whiteBalanceTemperature: 5000, whiteBalanceTint: 0,
                redGain: 1, greenGain: 1, blueGain: 1, width: photo.width, height: photo.height, sessionID: sessionID)
        }
        guard let device else { return nil }
        let gains = device.deviceWhiteBalanceGains
        let balance = device.temperatureAndTintValues(for: gains)
        let dimensions = output.maxPhotoDimensions
        return CameraSettings(
            locked: lockValid && session.isRunning && !session.isInterrupted && device.focusMode == .locked && device.exposureMode == .locked && device.whiteBalanceMode == .locked,
            iso: Double(device.iso), exposureSeconds: CMTimeGetSeconds(device.exposureDuration),
            focusPosition: Double(device.lensPosition), whiteBalanceTemperature: Double(balance.temperature),
            whiteBalanceTint: Double(balance.tint), redGain: Double(gains.redGain),
            greenGain: Double(gains.greenGain), blueGain: Double(gains.blueGain),
            width: Int(dimensions.width), height: Int(dimensions.height), sessionID: sessionID)
    }

    func setLocked(_ locked: Bool, completion: @escaping @Sendable (Result<CameraSettings, Error>) -> Void) {
        queue.async {
            if Self.isMock {
                guard self.mockPhoto != nil else { completion(.failure(CameraError.unavailable)); return }
                self.mockLocked = locked
                guard let settings = self.snapshot() else { completion(.failure(CameraError.unavailable)); return }
                completion(.success(settings))
                return
            }
            guard let device = self.device, self.session.isRunning, !self.session.isInterrupted, self.completion == nil, !self.changingSettings else {
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
        guard let device, session.isRunning, !session.isInterrupted else {
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
            guard let device, session.isRunning, !session.isInterrupted else { throw CameraError.unavailable }
            try device.lockForConfiguration()
            device.focusMode = locked ? .locked : .continuousAutoFocus
            device.exposureMode = locked ? .locked : .continuousAutoExposure
            device.whiteBalanceMode = locked ? .locked : .continuousAutoWhiteBalance
            device.unlockForConfiguration()
            lockValid = true
            changingSettings = false
            guard let settings = snapshot() else { throw CameraError.unavailable }
            completion(.success(settings))
        } catch { changingSettings = false; completion(.failure(error)) }
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    // Pull-based preview: one small frame per request, never an unbounded stream.
    func readLightPreview(completion: @escaping @Sendable (Data?, CameraSettings?) -> Void) {
        queue.async {
            self.previewUntil = Date.timeIntervalSinceReferenceDate + 3
            if Self.isMock { completion(self.mockPhoto?.data, self.snapshot()); return }
            guard Date.timeIntervalSinceReferenceDate - self.previewTime < 2,
                  let captured = self.previewSettings, let current = self.snapshot(),
                  captured.sessionID == current.sessionID,
                  (captured.matchesLocked(current) || (!captured.locked && !current.locked)) else { completion(nil, nil); return }
            completion(self.previewData, captured)
            self.previewData = nil
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date.timeIntervalSinceReferenceDate
        guard now < previewUntil, now - previewTime >= 0.25, !changingSettings,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, 480 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let data = previewContext.pngRepresentation(of: small, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return }
        previewData = data; previewSettings = snapshot(); previewTime = now
    }

    func prepareLightMatching(completion: @escaping @Sendable (Result<CameraSettings, Error>) -> Void) {
        setLocked(false) { result in
            switch result {
            case .failure: completion(result)
            case .success: self.setLocked(true, completion: completion)
            }
        }
    }
    // Final exposure adjustment deliberately preserves focus and white-balance gains.
    func finalizeLightExposure(completion: @escaping @Sendable (Result<CameraSettings, Error>) -> Void) {
        queue.async {
            if Self.isMock {
                guard let settings = self.snapshot(), settings.locked else { completion(.failure(CameraError.unavailable)); return }
                completion(.success(settings)); return
            }
            guard let device = self.device, self.snapshot()?.locked == true,
                  !self.changingSettings, self.completion == nil else { completion(.failure(CameraError.unavailable)); return }
            do {
                try device.lockForConfiguration()
                device.exposureMode = .continuousAutoExposure
                device.unlockForConfiguration()
                self.changingSettings = true
                self.waitForExposure(deadline: Date().addingTimeInterval(8), stable: 0, completion: completion)
            } catch { completion(.failure(error)) }
        }
    }
    private func waitForExposure(deadline: Date, stable: Int,
                                 completion: @escaping @Sendable (Result<CameraSettings, Error>) -> Void) {
        guard let device, session.isRunning, !session.isInterrupted else {
            changingSettings = false; completion(.failure(CameraError.unavailable)); return
        }
        let count = device.isAdjustingExposure ? 0 : stable + 1
        if count >= 5 || Date() >= deadline {
            let timedOut = count < 5
            applyLock(true) { result in completion(timedOut ? .failure(CameraError.notSettled) : result) }
            return
        }
        queue.asyncAfter(deadline: .now() + 0.1) {
            self.waitForExposure(deadline: deadline, stable: count, completion: completion)
        }
    }

    func capture(expected: CameraSettings? = nil, completion: @escaping @Sendable (Result<CameraPhoto, Error>) -> Void) {
        queue.async {
            if let expected, self.snapshot().map({ expected.matchesLocked($0) }) != true {
                completion(.failure(CameraError.settingsChanged)); return
            }
            if Self.isMock {
                guard let photo = self.mockPhoto, let settings = self.snapshot() else {
                    completion(.failure(CameraError.unavailable)); return
                }
                // Attach the current lock state rather than the state when the JPEG was generated.
                completion(.success(CameraPhoto(data: photo.data, width: photo.width, height: photo.height,
                    fileExtension: photo.fileExtension, settings: settings,
                    iso: settings.iso, exposureSeconds: settings.exposureSeconds)))
                return
            }
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
    private static func makeMockPhoto() throws -> CameraPhoto {
        let width = 1200, height = 1600
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CameraError.noImage }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw CameraError.noImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CameraError.noImage }
        return CameraPhoto(data: data as Data, width: width, height: height, fileExtension: "jpg",
            settings: nil, iso: nil, exposureSeconds: nil)
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
    case unavailable, noImage, unsupported, notSettled, settingsChanged
    var errorDescription: String? {
        switch self {
        case .settingsChanged: "Camera settings changed. Check calibration before capturing again."
        case .unavailable: "Camera is unavailable or busy."
        case .noImage: "The camera did not produce an image."
        case .unsupported: "This camera does not support locking all three settings."
        case .notSettled: "Camera settings did not settle. Keep the phone and lighting steady, then try again."
        }
    }
}
