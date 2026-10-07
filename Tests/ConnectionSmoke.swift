import Foundation
import Network

@MainActor
final class ConnectionFixture {
    let listener: NWListener
    var client: ScanConnection?
    var server: ScanConnection?
    var rawServer: NWConnection?
    var listening = false
    var clientReady = false
    var serverReady = false
    var receivedCapture = false
    var receivedReady = false
    var closeReason: String?
    var receivedImages: [Data] = []
    var receivedDiagnostics: [String] = []
    var progress: [(Int, Int)] = []

    init() throws {
        let parameters = ScanWire.parameters()
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start(rawMessage: ScanMessage? = nil, silent: Bool = false) async throws {
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .ready = state { self?.listening = true }
                if case .failed(let error) = state { fatalError(error.localizedDescription) }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else { return }
                if rawMessage != nil || silent {
                    self.rawServer = connection
                    connection.stateUpdateHandler = { state in
                        if case .ready = state, let rawMessage {
                            let data = try! ScanWire.encode(rawMessage)
                            // Exercise buffering across a split frame header.
                            connection.send(content: Data(data.prefix(2)), completion: .contentProcessed { error in
                                precondition(error == nil)
                                connection.send(content: Data(data.dropFirst(2)), completion: .contentProcessed { _ in })
                            })
                        }
                    }
                    connection.start(queue: .main)
                } else {
                    let server = ScanConnection(connection, app: .camera)
                    self.server = server
                    server.onReady = { [weak self, weak server] in
                        self?.serverReady = true
                        server?.send(ScanMessage(kind: "ready"))
                    }
                    server.onMessage = { [weak self] message, _ in
                        precondition(self?.serverReady == true)
                        if message.kind == "capture" { self?.receivedCapture = true }
                    }
                    server.start()
                }
            }
        }
        listener.start(queue: .main)
        await wait { self.listening }
        let client = ScanConnection(NWConnection(host: .ipv4(.loopback), port: listener.port!, using: ScanWire.parameters()), app: .desk)
        self.client = client
        client.onReady = { [weak self, weak client] in
            self?.clientReady = true
            precondition(client?.supports(ScanCapability.capture) == true)
            client?.send(ScanMessage(kind: "capture", request: CaptureRequest(assetID: UUID(), side: .front)))
        }
        client.onReceiveProgress = { [weak self] received, total in self?.progress.append((received, total)) }
        client.onMessage = { [weak self] message, image in
            precondition(self?.clientReady == true)
            if message.kind == "ready" { self?.receivedReady = true }
            if message.kind == "photo" { self?.receivedImages.append(image) }
            if message.kind == "diagnostic", let text = message.text { self?.receivedDiagnostics.append(text) }
        }
        client.onClose = { [weak self] reason in self?.closeReason = reason }
        client.start()
    }
    func wait(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            precondition(Date() < deadline, "Connection test timed out")
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    func stop() {
        client?.close(); server?.close(); rawServer?.cancel(); listener.cancel()
    }
}

@main
struct ConnectionSmoke {
    @MainActor
    static func main() async throws {
        // Bound Bonjour resolution/TCP establishment, before a hello can arrive.
        let unresolved = ScanConnection(NWConnection(to: .service(name: "Missing-" + UUID().uuidString,
            type: ScanWire.service, domain: "local.", interface: nil), using: ScanWire.parameters()),
            app: .desk, connectionTimeout: .milliseconds(200))
        var unresolvedReason: String?
        var unresolvedReady = false
        unresolved.onClose = { unresolvedReason = $0 }
        unresolved.onReady = { unresolvedReady = true }
        let started = ContinuousClock.now
        unresolved.start()
        while unresolvedReason == nil {
            precondition(ContinuousClock.now - started < .seconds(2), "Unbounded connection establishment")
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(!unresolvedReady)
        precondition(unresolvedReason!.contains("Connecting to camera timed out"))

        let normal = try ConnectionFixture()
        try await normal.start()
        await normal.wait { normal.receivedCapture && normal.receivedReady }
        precondition(normal.clientReady && normal.serverReady && normal.closeReason == nil)
        precondition(normal.client?.supports(ScanCapability.diagnostics) == true)
        normal.server?.onTrace = { [weak server = normal.server] line in
            server?.send(ScanMessage(kind: "diagnostic", text: line))
        }
        let payload = Data((0..<(4 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        normal.server?.send(ScanMessage(kind: "photo"), image: payload)
        normal.server?.send(ScanMessage(kind: "settings"))
        normal.server?.send(ScanMessage(kind: "photo"), image: payload)
        await normal.wait { normal.receivedImages.count == 2 }
        precondition(normal.receivedDiagnostics.contains { $0.contains("Sending photo") }, "Relay phone traces without recursion")
        precondition(normal.receivedImages.allSatisfy { $0 == payload })
        precondition(normal.progress.contains { $0.0 < $0.1 }, "Report partial image delivery")
        precondition(normal.progress.filter { $0.0 == $0.1 }.count == 2)
        normal.stop()

        let legacy = try ConnectionFixture()
        try await legacy.start(rawMessage: ScanMessage(kind: "ready"))
        await legacy.wait { legacy.closeReason != nil }
        precondition(!legacy.clientReady && !legacy.receivedReady)
        precondition(legacy.closeReason!.contains("Update PhotoScanCamera"))
        legacy.stop()

        let future = try ConnectionFixture()
        let hello = ScanHello(app: .camera, appVersion: "2.0", build: "99", protocolVersion: 2,
                              capabilities: ScanCapability.supported)
        try await future.start(rawMessage: ScanMessage(version: 2, kind: "hello", hello: hello))
        await future.wait { future.closeReason != nil }
        precondition(!future.clientReady && future.closeReason!.contains("Update PhotoScanDesk"))
        future.stop()

        let silent = try ConnectionFixture()
        try await silent.start(silent: true)
        await silent.wait { silent.closeReason != nil }
        precondition(!silent.clientReady && silent.closeReason!.contains("Update PhotoScanCamera"))
        silent.stop()
        print("Connection smoke tests passed")
    }
}
