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
