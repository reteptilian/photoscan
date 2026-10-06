import AVFoundation
import Foundation

final class CameraEngine: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "photoscan.camera")
    private let output = AVCapturePhotoOutput()
    private var completion: (@Sendable (Result<(Data, Int, Int, String), Error>) -> Void)?
    private var result: Result<(Data, Int, Int, String), Error>?
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
                if let dimensions = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
                    Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
                }) { self.output.maxPhotoDimensions = dimensions }
                self.output.maxPhotoQualityPrioritization = .quality
            } catch { completion(.failure(error)); return }
            self.session.startRunning()
            completion(.success(()))
        }
    }
    func capture(completion: @escaping @Sendable (Result<(Data, Int, Int, String), Error>) -> Void) {
        queue.async {
            guard self.session.isRunning, self.completion == nil else {
                completion(.failure(CameraError.unavailable)); return
            }
            self.completion = completion
            self.result = nil
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
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        let dimensions = photo.resolvedSettings.photoDimensions
        queue.async {
            if let error { self.result = .failure(error) }
            else if let data { self.result = .success((data, Int(dimensions.width), Int(dimensions.height), self.fileExtension)) }
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
    case unavailable, noImage
    var errorDescription: String? {
        switch self {
        case .unavailable: "Camera is unavailable or busy."
        case .noImage: "The camera did not produce an image."
        }
    }
}
