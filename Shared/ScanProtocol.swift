import Foundation
import Network

enum ScanSide: String, Codable { case front, back }
struct CaptureRequest: Codable, Equatable {
    let assetID: UUID
    let side: ScanSide
}
struct CaptureInfo: Codable {
    let request: CaptureRequest
    let capturedAt: Date
    let fileExtension: String
    let width: Int
    let height: Int
    let camera: String
}
struct ScanMessage: Codable {
    var version = 1
    let kind: String
    var request: CaptureRequest?
    var capture: CaptureInfo?
    var text: String?
}
enum ScanWire {
    static let service = "_photoscan._tcp"
    static let limit = 100 * 1024 * 1024
    static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        return parameters
    }
    static func prefix(_ count: Int) -> Data {
        var value = UInt32(count).bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    static func length(_ data: Data) -> Int {
        data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
    }
    static func encode(_ message: ScanMessage, image: Data = Data()) throws -> Data {
        let json = try JSONEncoder().encode(message)
        let body = prefix(json.count) + json + image
        guard body.count <= limit else { throw CocoaError(.fileReadTooLarge) }
        return prefix(body.count) + body
    }
    static func decode(_ body: Data) throws -> (ScanMessage, Data) {
        guard body.count >= 4 else { throw CocoaError(.fileReadCorruptFile) }
        let size = length(body)
        guard size > 0, size <= body.count - 4 else { throw CocoaError(.fileReadCorruptFile) }
        let message = try JSONDecoder().decode(ScanMessage.self, from: body.subdata(in: 4..<(4 + size)))
        guard message.version == 1 else { throw CocoaError(.fileReadUnknown) }
        return (message, body.subdata(in: (4 + size)..<body.count))
    }
}

@MainActor
final class ScanConnection {
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onMessage: ((ScanMessage, Data) -> Void)?
    var onClose: ((String) -> Void)?
    private var buffer = Data()
    private var closed = false
    init(_ connection: NWConnection) { self.connection = connection }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                switch state {
                case .ready: self.onReady?(); self.receive()
                case .failed(let error): self.close(error.localizedDescription)
                case .waiting(let error): self.close(error.localizedDescription)
                case .cancelled: self.close("Disconnected")
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }
    func send(_ message: ScanMessage, image: Data = Data(), completion: ((Bool) -> Void)? = nil) {
        do {
            let data = try ScanWire.encode(message, image: image)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                MainActor.assumeIsolated {
                    if let error { self?.close(error.localizedDescription) }
                    completion?(error == nil)
                }
            })
        } catch { close(error.localizedDescription); completion?(false) }
    }
    func close(_ reason: String = "Disconnected") {
        guard !closed else { return }
        closed = true
        connection.cancel()
        buffer.removeAll()
        onClose?(reason)
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data { self.buffer.append(data) }
                do {
                    while self.buffer.count >= 4 {
                        let size = ScanWire.length(self.buffer)
                        guard size >= 4, size <= ScanWire.limit else { throw CocoaError(.fileReadCorruptFile) }
                        guard self.buffer.count >= size + 4 else { break }
                        let body = self.buffer.subdata(in: 4..<(size + 4))
                        self.buffer.removeSubrange(0..<(size + 4))
                        let (message, image) = try ScanWire.decode(body)
                        self.onMessage?(message, image)
                    }
                } catch { self.close(error.localizedDescription); return }
                if let error { self.close(error.localizedDescription) }
                else if complete { self.close() }
                else { self.receive() }
            }
        }
    }
}
