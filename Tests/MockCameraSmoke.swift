import Foundation

// Run on an iOS Simulator; uses the same engine and calibration code as the apps.
@main
struct MockCameraSmoke {
    static func main() async throws {
        precondition(CameraEngine.isMock)
        let capabilities = ScanHello.current(.camera).capabilities
        precondition(capabilities.contains(ScanCapability.lightMatching))
        precondition(capabilities.contains(ScanCapability.settings))
        precondition(capabilities.contains(ScanCapability.captureSettings))
        let engine = CameraEngine()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            engine.start { continuation.resume(with: $0) }
        }
        let initial = await withCheckedContinuation { continuation in
            engine.readSettings { continuation.resume(returning: $0) }
        }
        precondition(initial?.locked == false)
        let locked = try await withCheckedThrowingContinuation { continuation in
            engine.prepareLightMatching { continuation.resume(with: $0) }
        }
        let preview = await withCheckedContinuation { continuation in
            engine.readLightPreview { data, settings in continuation.resume(returning: (data, settings)) }
        }
        precondition(preview.0?.isEmpty == false && preview.1 == locked)
        let finalized = try await withCheckedThrowingContinuation { continuation in
            engine.finalizeLightExposure { continuation.resume(with: $0) }
        }
        precondition(finalized.matchesLocked(locked))
        precondition(locked.locked)
        let reference = try await capture(engine)
        precondition(reference.settings == locked)
        precondition(reference.iso == locked.iso && reference.exposureSeconds == locked.exposureSeconds)
        let info = info(reference)
        let flat = try FlatField.makeProfile(data: reference.data, info: info)
        let gray = try GrayBalance.makeProfile(data: reference.data, info: info, target: .gray18,
            selection: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4))
        let next = try await capture(engine)
        precondition(flat.matches(self.info(next)) && gray.matches(self.info(next)))
        _ = try GrayBalance.corrected(FlatField.corrected(FlatField.image(next.data), profile: flat), profile: gray)
        let unlocked = try await lock(engine, false)
        precondition(!unlocked.locked)
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                engine.finalizeLightExposure { continuation.resume(with: $0) }
            }
            fatalError("Finalized exposure without a camera lock")
        } catch {}
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                engine.capture(expected: locked) { continuation.resume(with: $0) }
            }
            fatalError("Captured with mismatched expected settings")
        } catch {}
        let afterUnlock = try await capture(engine)
        precondition(afterUnlock.settings == unlocked)
        precondition(!flat.matches(self.info(afterUnlock)) && !gray.matches(self.info(afterUnlock)))
        print("Simulator mock light preview, automatic preparation/final exposure, settings, calibration, subsequent capture, and unlock checks passed")
    }

    static func lock(_ engine: CameraEngine, _ locked: Bool) async throws -> CameraSettings {
        try await withCheckedThrowingContinuation { continuation in
            engine.setLocked(locked) { continuation.resume(with: $0) }
        }
    }

    static func capture(_ engine: CameraEngine) async throws -> CameraPhoto {
        try await withCheckedThrowingContinuation { continuation in
            engine.capture { continuation.resume(with: $0) }
        }
    }

    static func info(_ photo: CameraPhoto) -> CaptureInfo {
        CaptureInfo(request: CaptureRequest(assetID: UUID(), side: .front), capturedAt: Date(),
            fileExtension: photo.fileExtension, width: photo.width, height: photo.height,
            camera: CameraEngine.cameraName, settings: photo.settings,
            photoISO: photo.iso, photoExposureSeconds: photo.exposureSeconds)
    }
}
