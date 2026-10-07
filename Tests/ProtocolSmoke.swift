import Foundation

@main
struct ProtocolSmoke {
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
        print("Protocol smoke tests passed")
    }
}
