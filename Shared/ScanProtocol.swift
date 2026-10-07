import Foundation
import Network
import OSLog

enum ScanSide: String, Codable, Sendable { case front, back }
struct CaptureRequest: Codable, Equatable, Sendable {
    let assetID: UUID
    let side: ScanSide
}
struct CaptureInfo: Codable, Sendable {
    let request: CaptureRequest
    let capturedAt: Date
    let fileExtension: String
    let width: Int
    let height: Int
    let camera: String
    var settings: CameraSettings?
    var photoISO: Double?
    var photoExposureSeconds: Double?

    func hasSameLockedSetup(as reference: CaptureInfo) -> Bool {
        guard let a = reference.settings, let b = settings, a.locked, b.locked,
              reference.camera == camera, reference.width == width, reference.height == height else { return false }
        func near(_ x: Double, _ y: Double) -> Bool { abs(x - y) <= max(abs(x) * 0.01, 0.000001) }
        return near(a.iso, b.iso) && near(a.exposureSeconds, b.exposureSeconds)
            && abs(a.focusPosition - b.focusPosition) <= 0.002
            && near(a.redGain, b.redGain) && near(a.greenGain, b.greenGain) && near(a.blueGain, b.blueGain)
    }
}
struct CameraSettings: Codable, Equatable, Sendable {
    let locked: Bool
    let iso: Double
    let exposureSeconds: Double
    let focusPosition: Double
    let whiteBalanceTemperature: Double
    let whiteBalanceTint: Double
    let redGain: Double
    let greenGain: Double
    let blueGain: Double
    let width: Int
    let height: Int
}
enum ScanApp: String, Codable, Sendable {
    case camera = "PhotoScanCamera", desk = "PhotoScanDesk"
    var other: ScanApp { self == .camera ? .desk : .camera }
}
enum ScanCapability {
    static let capture = "capture.front"
    static let settings = "settings.lock"
    static let captureSettings = "capture.settings"
    static let captureProgress = "capture.progress"
    static let supported = [capture, settings, captureSettings, captureProgress]
}
struct ScanHello: Codable, Equatable, Sendable {
    let app: ScanApp
    let appVersion: String
    let build: String
    let protocolVersion: Int
    let capabilities: [String]

    static func current(_ app: ScanApp) -> ScanHello {
        ScanHello(app: app,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            protocolVersion: ScanWire.version, capabilities: ScanCapability.supported)
    }
    var summary: String { "\(app.rawValue) \(appVersion) (build \(build), protocol \(protocolVersion))" }
}
struct ScanCompatibilityError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

// The hello envelope remains readable across protocol revisions. App release numbers
// are diagnostic only; the protocol and capabilities determine interoperability.
struct ScanSession {
    let local: ScanHello
    private(set) var remote: ScanHello?
    var ready: Bool { remote != nil }
    func supports(_ capability: String) -> Bool {
        local.capabilities.contains(capability) && remote?.capabilities.contains(capability) == true
    }
    var missingHandshake: String {
        "Compatibility check failed. Update \(local.app.other.rawValue) and reconnect."
    }
    // Returns true only for application messages after a validated hello.
    mutating func receive(_ message: ScanMessage, image: Data) throws -> Bool {
        guard message.kind == "hello" else {
            guard ready else { throw ScanCompatibilityError(reason: missingHandshake) }
            return true
        }
        guard remote == nil, image.isEmpty, let hello = message.hello, hello.app == local.app.other else {
            throw ScanCompatibilityError(reason: "Invalid compatibility handshake from \(local.app.other.rawValue). Reconnect or update both apps.")
        }
        guard hello.protocolVersion == message.version else {
            throw ScanCompatibilityError(reason: "Invalid protocol version in compatibility handshake. Update both apps and reconnect.")
        }
        guard hello.protocolVersion == local.protocolVersion else {
            let outdated = hello.protocolVersion < local.protocolVersion ? hello.app : local.app
            throw ScanCompatibilityError(reason: "Incompatible apps: \(local.summary); \(hello.summary). Update \(outdated.rawValue) and reconnect.")
        }
        guard hello.capabilities.contains(ScanCapability.capture), local.capabilities.contains(ScanCapability.capture) else {
            throw ScanCompatibilityError(reason: "\(hello.summary) cannot support photo capture with this app. Update both apps and reconnect.")
        }
        remote = hello
        return false
    }
}
struct ScanMessage: Codable {
    var version = ScanWire.version
    let kind: String
    var request: CaptureRequest?
    var capture: CaptureInfo?
    var text: String?
    var settings: CameraSettings?
    var commandID: UUID?
    var hello: ScanHello?
}
enum ScanWire {
    static let version = 1
    static let service = "_photoscan._tcp"
    static let limit = 100 * 1024 * 1024
    static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        // The supported setup uses a shared LAN. Avoid competing AWDL routes.
        parameters.includePeerToPeer = false
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            // Release the phone's single-client slot after a broken route, including
            // unplugging a cable used by the connection. Do not wait for TCP defaults.
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10; tcp.keepaliveInterval = 5; tcp.keepaliveCount = 3
            tcp.connectionDropTime = 20
        }
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
        let json = body.subdata(in: 4..<(4 + size))
        struct Envelope: Decodable { let version: Int; let kind: String }
        let envelope = try JSONDecoder().decode(Envelope.self, from: json)
        // Decode a future hello so the handshake can identify which app needs updating.
        guard envelope.version == version || envelope.kind == "hello" else {
            throw ScanCompatibilityError(reason: "Unsupported PhotoScan protocol \(envelope.version). Update both apps and reconnect.")
        }
        let message = try JSONDecoder().decode(ScanMessage.self, from: json)
        return (message, body.subdata(in: (4 + size)..<body.count))
    }
}

@MainActor
final class ScanConnection {
    let connection: NWConnection
    var onPath: ((String) -> Void)?
    var onReceiveProgress: ((Int, Int) -> Void)?
    var onTransportReady: (() -> Void)?
    var onReady: (() -> Void)?
    var onMessage: ((ScanMessage, Data) -> Void)?
    var onClose: ((String) -> Void)?
    private(set) var session: ScanSession
    private let connectionTimeout: Duration
    private var handshakeTimeout: Task<Void, Never>?
    private var buffer = Data()
    private var closed = false
    private let logger = Logger(subsystem: "PhotoScan", category: "Transport")
    private let traceID = String(UUID().uuidString.prefix(8))
    private var progressBucket = -1
    func trace(_ event: String) {
        logger.notice("[\(self.session.local.app.rawValue, privacy: .public) \(self.traceID, privacy: .public)] \(event, privacy: .public)")
    }
    init(_ connection: NWConnection, app: ScanApp, connectionTimeout: Duration = .seconds(20)) {
        self.connection = connection
        self.connectionTimeout = connectionTimeout
        session = ScanSession(local: .current(app))
    }
    func supports(_ capability: String) -> Bool { session.supports(capability) }
    func start() {
        trace("Connection starting")
        connection.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                let interfaces = path.availableInterfaces.map { "\($0.name)(\($0.type))" }.joined(separator: ", ")
                let summary = "\(path.status); interfaces: \(interfaces); Wi-Fi: \(path.usesInterfaceType(.wifi)); wired: \(path.usesInterfaceType(.wiredEthernet))"
                self.trace("Path: " + summary); self.onPath?(summary)
            }
        }
        connection.viabilityUpdateHandler = { [weak self] viable in
            MainActor.assumeIsolated { self?.trace("Connection viable: \(viable)") }
        }
        // Bonjour resolution and TCP establishment can stall before .ready.
        handshakeTimeout = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.connectionTimeout)
            guard !Task.isCancelled, !self.closed else { return }
            self.close("Connecting to camera timed out. Keep the phone app open, check Wi-Fi and Local Network access, then select the camera again.")
        }
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                self.trace("State: \(state)")
                switch state {
                case .ready:
                    self.handshakeTimeout?.cancel()
                    self.onTransportReady?()
                    self.handshakeTimeout = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(10))
                        guard !Task.isCancelled, let self, !self.session.ready else { return }
                        self.close(self.session.missingHandshake)
                    }
                    self.send(ScanMessage(kind: "hello", hello: self.session.local))
                    self.receive()
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
        guard !closed else { completion?(false); return }
        guard session.ready || message.kind == "hello" else {
            close(session.missingHandshake); completion?(false); return
        }
        do {
            let data = try ScanWire.encode(message, image: image)
            if message.kind != "settings" { trace("Sending \(message.kind); frame bytes: \(data.count)") }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                MainActor.assumeIsolated {
                    if let error { self?.close(error.localizedDescription) }
                    else if message.kind != "settings" { self?.trace("TCP send completed: \(message.kind) (not an application acknowledgement)") }
                    completion?(error == nil)
                }
            })
        } catch { close(error.localizedDescription); completion?(false) }
    }
    func close(_ reason: String = "Disconnected") {
        guard !closed else { return }
        closed = true
        trace("Closed: " + reason)
        handshakeTimeout?.cancel(); handshakeTimeout = nil
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
                        if size > 256 * 1024 {
                            let received = min(self.buffer.count - 4, size)
                            let bucket = received * 20 / size
                            if bucket != self.progressBucket {
                                self.progressBucket = bucket
                                self.trace("Receiving frame: \(received)/\(size) bytes")
                                self.onReceiveProgress?(received, size)
                            }
                        }
                        guard self.buffer.count >= size + 4 else { break }
                        self.progressBucket = -1
                        let body = self.buffer.subdata(in: 4..<(size + 4))
                        self.buffer.removeSubrange(0..<(size + 4))
                        let (message, image) = try ScanWire.decode(body)
                        if message.kind != "settings" { self.trace("Received \(message.kind); image bytes: \(image.count)") }
                        let wasReady = self.session.ready
                        if try self.session.receive(message, image: image) {
                            self.onMessage?(message, image)
                        } else if !wasReady {
                            self.handshakeTimeout?.cancel(); self.handshakeTimeout = nil
                            self.onReady?()
                        }
                        guard !self.closed else { return }
                    }
                } catch { self.close(error.localizedDescription); return }
                if let error { self.close(error.localizedDescription) }
                else if complete { self.close() }
                else { self.receive() }
            }
        }
    }
}
