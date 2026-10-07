import Foundation

@main
struct ProtocolSmoke {
    static func compatibilityChecks() throws {
        func hello(_ app: ScanApp, version: Int = ScanWire.version,
                   capabilities: [String] = ScanCapability.supported) -> ScanHello {
            ScanHello(app: app, appVersion: app == .camera ? "1.9" : "3.2", build: "42",
                      protocolVersion: version, capabilities: capabilities)
        }
        func expectRejection(_ message: ScanMessage, image: Data = Data(), update: String? = nil) {
            var session = ScanSession(local: hello(.desk))
            do {
                _ = try session.receive(message, image: image)
                fatalError("Accepted an incompatible peer")
            } catch {
                precondition(!session.ready)
                if let update { precondition(error.localizedDescription.contains(update)) }
            }
        }
        // App release numbers may differ in either direction; both roles validate.
        for app in [ScanApp.camera, .desk] {
            var session = ScanSession(local: hello(app))
            precondition(!session.ready && !session.supports(ScanCapability.capture))
            let packet = try ScanWire.encode(ScanMessage(kind: "hello", hello: hello(app.other)))
            let (decoded, _) = try ScanWire.decode(Data(packet.dropFirst(4)))
            let deliveredHello = try session.receive(decoded, image: Data())
            precondition(!deliveredHello)
            precondition(session.ready && session.remote == hello(app.other))
            precondition(session.supports(ScanCapability.settings))
            let deliveredCapture = try session.receive(ScanMessage(kind: "capture"), image: Data())
            precondition(deliveredCapture)
            do {
                _ = try session.receive(decoded, image: Data())
                fatalError("Accepted a repeated handshake")
            } catch {}
        }
        // Unknown optional capabilities are ignored; missing features stay disabled.
        var limited = ScanSession(local: hello(.desk))
        _ = try limited.receive(ScanMessage(kind: "hello", hello: hello(.camera,
            capabilities: [ScanCapability.capture, "future.optional"])), image: Data())
        precondition(limited.ready && limited.supports(ScanCapability.capture))
        precondition(!limited.supports(ScanCapability.settings) && !limited.supports(ScanCapability.captureSettings))
        precondition(!limited.supports("future.optional"))
        expectRejection(ScanMessage(kind: "ready"), update: "Update PhotoScanCamera")
        expectRejection(ScanMessage(kind: "capture"))
        expectRejection(ScanMessage(kind: "hello"))
        expectRejection(ScanMessage(kind: "hello", hello: hello(.desk)))
        expectRejection(ScanMessage(kind: "hello", hello: hello(.camera)), image: Data([1]))
        expectRejection(ScanMessage(kind: "hello", hello: hello(.camera, capabilities: [])))
        expectRejection(ScanMessage(version: 0, kind: "hello", hello: hello(.camera, version: 0)),
                        update: "Update PhotoScanCamera")
        // A future hello must decode even if its message envelope version is newer.
        let future = try ScanWire.encode(ScanMessage(version: 2, kind: "hello", hello: hello(.camera, version: 2)))
        let (decoded, _) = try ScanWire.decode(Data(future.dropFirst(4)))
        expectRejection(decoded, update: "Update PhotoScanDesk")
        expectRejection(ScanMessage(version: 2, kind: "hello", hello: hello(.camera)))
    }
    static func main() throws {
        let request = CaptureRequest(assetID: UUID(), side: .front)
        let image = Data((0..<65536).map { UInt8($0 % 256) })
        let info = CaptureInfo(request: request, capturedAt: Date(), fileExtension: "heic", width: 8064, height: 6048, camera: "Main")
        let packet = try ScanWire.encode(ScanMessage(kind: "photo", capture: info), image: image)
        precondition(ScanWire.length(packet) == packet.count - 4)
        let (message, received) = try ScanWire.decode(Data(packet.dropFirst(4)))
        precondition(message.capture?.request == request && received == image)
        let back = CaptureRequest(assetID: request.assetID, side: .back)
        let command = try ScanWire.encode(ScanMessage(kind: "capture", request: back))
        let (decoded, empty) = try ScanWire.decode(Data(command.dropFirst(4)))
        precondition(decoded.request == back && empty.isEmpty)
        let settings = CameraSettings(locked: true, iso: 80, exposureSeconds: 1.0 / 60,
            focusPosition: 0.4, whiteBalanceTemperature: 5000, whiteBalanceTint: 2,
            redGain: 1.4, greenGain: 1, blueGain: 1.6, width: 8064, height: 6048)
        let commandID = UUID()
        for kind in ["lockSettings", "unlockSettings", "settings"] {
            let packet = try ScanWire.encode(ScanMessage(kind: kind, settings: settings, commandID: commandID))
            let (decoded, _) = try ScanWire.decode(Data(packet.dropFirst(4)))
            precondition(decoded.commandID == commandID && decoded.settings == settings)
        }
        var annotated = info
        annotated.settings = settings
        annotated.photoISO = 100
        annotated.photoExposureSeconds = 1.0 / 50
        let annotatedPacket = try ScanWire.encode(ScanMessage(kind: "photo", capture: annotated), image: image)
        let (annotatedMessage, _) = try ScanWire.decode(Data(annotatedPacket.dropFirst(4)))
        precondition(annotatedMessage.capture?.settings == settings)
        precondition(annotatedMessage.capture?.photoISO == 100)
        precondition(annotatedMessage.capture?.photoExposureSeconds == 1.0 / 50)
        // Older capture records remain readable without the newly added fields.
        let legacy = try JSONEncoder().encode(info)
        let legacyInfo = try JSONDecoder().decode(CaptureInfo.self, from: legacy)
        precondition(legacyInfo.settings == nil && legacyInfo.photoISO == nil)
        for invalid in [Data(), Data([0, 0, 0, 20, 1]), ScanWire.prefix(0)] {
            do {
                _ = try ScanWire.decode(invalid)
                fatalError("Accepted a malformed frame")
            } catch {}
        }
        let future = try ScanWire.encode(ScanMessage(version: 2, kind: "ready"))
        do {
            _ = try ScanWire.decode(Data(future.dropFirst(4)))
            fatalError("Accepted an unsupported protocol version")
        } catch {}
        try compatibilityChecks()
        print("Protocol smoke tests passed")
    }
}
