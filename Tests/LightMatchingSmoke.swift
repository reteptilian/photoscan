import AppKit
import CoreImage

@main
struct LightMatchingSmoke {
    static let patch = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
    static func image(_ rgb: [Double], split: Bool = false) throws -> Data {
        let context = CIContext()
        let extent = CGRect(x: 0, y: 0, width: 160, height: 200)
        var image = CIImage(color: CIColor(red: rgb[0], green: rgb[1], blue: rgb[2])).cropped(to: extent)
        if split {
            image = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.1))
                .cropped(to: CGRect(x: 0, y: 100, width: 160, height: 100)).composited(over: image)
        }
        return context.pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    }
    static func settings(locked: Bool = true, exposure: Double = 0.01, red: Double = 1.4, session: UUID? = nil) -> CameraSettings {
        CameraSettings(locked: locked, iso: 80, exposureSeconds: exposure, focusPosition: 0.5,
                       whiteBalanceTemperature: 5000, whiteBalanceTint: 0, redGain: red, greenGain: 1,
                       blueGain: 1.6, width: 1200, height: 1600, sessionID: session)
    }
    @MainActor static func main() async throws {
        let a = LightReading(rgb: [0.2, 0.3, 0.4])
        let brighter = LightReading(rgb: [0.3, 0.45, 0.6])
        precondition(a.difference(from: brighter) < 1e-10)
        precondition(abs(brighter.brightness / a.brightness - 1.5) < 1e-10)
        precondition(LightReading(rgb: [0.3, 0.3, 0.3]).warmth(from: a) > 0)
        precondition(LightReading(rgb: [0.2, 0.4, 0.4]).tint(from: a) > 0)
        let data = try image([0.5, 0.5, 0.5])
        let measured = try LightReading.measure(data: data, selection: patch)
        precondition(measured.difference(from: LightReading(rgb: [1, 1, 1])) < 0.01)
        for bad in [try image([0, 0, 0]), try image([1, 1, 1]), try image([0.5, 0.5, 0.5], split: true)] {
            do { _ = try LightReading.measure(data: bad, selection: patch); fatalError("Accepted invalid sample") } catch {}
        }
        let split = try image([0.5, 0.5, 0.5], split: true)
        let top = try LightReading.measure(data: split, selection: CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.2))
        let bottom = try LightReading.measure(data: split, selection: CGRect(x: 0.2, y: 0.7, width: 0.4, height: 0.2))
        precondition(top.rgb[0] > top.rgb[1] * 5 && bottom.difference(from: measured) < 0.01)
        var window = LightReadingWindow()
        let now = Date()
        for i in 0..<6 { window.add(a, at: now.addingTimeInterval(Double(i) * 0.3)) }
        precondition(window.average != nil)
        window.add(brighter, at: now.addingTimeInterval(1.8)); precondition(window.average == nil)
        window.reset()
        for i in 0..<6 { window.add(a, at: now.addingTimeInterval(Double(i) * 0.3)) }
        window.add(a, at: now.addingTimeInterval(5)); precondition(window.average == nil)
        let session = UUID(), baseline = settings(session: session)
        precondition(baseline.matchesLocked(baseline))
        for changed in [settings(locked: false, session: session), settings(exposure: 0.02, session: session),
                        settings(red: 1.6, session: session), settings(session: UUID())] {
            precondition(!baseline.matchesLocked(changed))
        }
        let encoded = try ScanWire.encode(ScanMessage(kind: "lightPreview", settings: baseline, commandID: session), image: data)
        let (decoded, decodedImage) = try ScanWire.decode(Data(encoded.dropFirst(4)))
        precondition(decoded.settings == baseline && decoded.commandID == session && decodedImage == data)
        precondition(ScanCapability.supported.contains(ScanCapability.lightMatching))

        var request: ScanMessage?
        var commands: [String] = []
        var final = false
        var frameSettings = baseline
        let matcher = LightMatchController(send: { request = $0 }, command: { kind, done in
            commands.append(kind)
            done(.success(kind == "finalizeLightExposure" ? settings(exposure: 0.02, session: session) : baseline))
        })
        matcher.onFinalized = { _ in final = true }
        func feed(_ count: Int = 8) async throws {
            for _ in 0..<count {
                try await Task.sleep(for: .milliseconds(310))
                if let message = request {
                    request = nil
                    matcher.receive(ScanMessage(kind: "lightPreview", settings: frameSettings, commandID: message.commandID), data: data)
                }
            }
        }
        try await feed()
        precondition(matcher.stable != nil)
        matcher.prepare(); precondition(matcher.stage == .lightA && commands == ["prepareLightMatching"])
        // A stale reply cannot supply a reading in the new stage.
        matcher.receive(ScanMessage(kind: "lightPreview", settings: baseline, commandID: UUID()), data: data)
        precondition(matcher.stable == nil)
        try await feed(); matcher.saveA(); precondition(matcher.stage == .lightB)
        precondition(matcher.stable == nil)
        try await feed(); precondition(matcher.best != nil); matcher.saveLightB()
        precondition(matcher.stage == .verifyA && !matcher.verificationPasses)
        try await feed(); precondition(matcher.verificationPasses); matcher.verify()
        precondition(matcher.stage == .both)
        try await feed(); matcher.finalize()
        precondition(matcher.stage == .ready && final && commands.last == "finalizeLightExposure")
        frameSettings = settings(exposure: 0.02, session: session)
        try await feed(); precondition(matcher.cameraReady)
        matcher.observe(settings(exposure: 0.02, session: UUID()))
        precondition(matcher.stage == .invalid && matcher.reference == nil && !matcher.cameraReady)
        matcher.restart(); precondition(matcher.stage == .prepare && matcher.stable == nil)
        matcher.stop()
        print("Light matching: normalization, sampling/orientation, clipping/dark/uneven rejection, stability, wire format, guided flow, final exposure, and session invalidation passed")
    }
}
