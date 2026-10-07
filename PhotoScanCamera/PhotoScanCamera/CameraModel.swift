import AVFoundation
import Combine
import Network
import UIKit

@MainActor
final class CameraModel: ObservableObject {
    let engine = CameraEngine()
    @Published var status = "Starting camera"
    @Published var ready = false
    @Published var connected = false
    @Published var busy = false
    @Published var error: String?
    private var listener: NWListener?
    private var peer: ScanConnection?
    private var started = false
    private var settingsTask: Task<Void, Never>?
    func start() async {
        guard !started else { return }
        started = true
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            error = "Camera access is disabled. Enable it in Settings."; status = "Camera unavailable"; return
        }
        UIApplication.shared.isIdleTimerDisabled = true
        engine.start { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success: self.ready = true; self.listen()
                case .failure(let error): self.error = error.localizedDescription; self.status = "Camera unavailable"
                }
            }
        }
    }
    private func listen() {
        do {
            let listener = try NWListener(using: ScanWire.parameters())
            listener.service = NWListener.Service(name: "PhotoScan Camera", type: ScanWire.service)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    if case .ready = state { self?.status = "Waiting for Mac" }
                    if case .failed(let error) = state { self?.error = error.localizedDescription }
                    if case .waiting(let error) = state { self?.error = error.localizedDescription }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch { self.error = error.localizedDescription }
    }
    private func accept(_ connection: NWConnection) {
        guard peer == nil else { connection.cancel(); return }
        let peer = ScanConnection(connection, app: .camera)
        self.peer = peer
        peer.onReady = { [weak self, weak peer] in
            self?.error = nil; self?.connected = true; self?.status = "Connected to Mac"
            peer?.send(ScanMessage(kind: "ready", text: "Main camera"))
            self?.streamSettings()
        }
        peer.onClose = { [weak self] reason in
            self?.peer = nil; self?.connected = false; self?.status = "Waiting for Mac"
            self?.settingsTask?.cancel(); self?.settingsTask = nil
            if reason != "Disconnected" { self?.error = reason }
        }
        peer.onMessage = { [weak self, weak peer] message, _ in
            guard let self, self.connected else { return }
            if message.kind == "lockSettings" || message.kind == "unlockSettings" {
                guard let commandID = message.commandID else { return }
                guard peer?.supports(ScanCapability.settings) == true else { return }
                guard !self.busy, self.ready else {
                    peer?.send(ScanMessage(kind: "error", text: "Camera is busy.", commandID: commandID)); return
                }
                self.busy = true; self.error = nil
                self.status = message.kind == "lockSettings" ? "Settling camera settings" : "Unlocking settings"
                self.engine.setLocked(message.kind == "lockSettings") { [weak self, weak peer] result in
                    Task { @MainActor [weak self, weak peer] in
                        guard let self else { return }
                        self.busy = false; self.status = self.connected ? "Connected to Mac" : "Waiting for Mac"
                        switch result {
                        case .success(let settings): peer?.send(ScanMessage(kind: "settings", settings: settings, commandID: commandID))
                        case .failure(let error):
                            self.error = error.localizedDescription
                            peer?.send(ScanMessage(kind: "error", text: error.localizedDescription, commandID: commandID))
                        }
                    }
                }
                return
            }
            guard message.kind == "capture", let request = message.request else { return }
            guard request.side == .front, !self.busy, self.ready else {
                peer?.send(ScanMessage(kind: "error", request: request, text: "Camera is busy or capture side is unsupported.")); return
            }
            self.busy = true; self.status = "Capturing"; self.error = nil
            self.engine.capture { [weak self, weak peer] result in
                Task { @MainActor [weak self, weak peer] in
                    guard let self else { return }
                    switch result {
                    case .success(let photo):
                        self.status = "Sending photo"
                        let info = CaptureInfo(request: request, capturedAt: Date(), fileExtension: photo.fileExtension,
                            width: photo.width, height: photo.height, camera: "Main wide-angle camera",
                            settings: photo.settings, photoISO: photo.iso, photoExposureSeconds: photo.exposureSeconds)
                        peer?.send(ScanMessage(kind: "photo", capture: info), image: photo.data) { [weak self] _ in
                            self?.busy = false; self?.status = self?.connected == true ? "Connected to Mac" : "Waiting for Mac"
                        }
                        if peer == nil { self.busy = false }
                    case .failure(let error):
                        self.busy = false; self.error = error.localizedDescription
                        self.status = self.connected ? "Connected to Mac" : "Waiting for Mac"
                        peer?.send(ScanMessage(kind: "error", request: request, text: error.localizedDescription))
                    }
                }
            }
        }
        peer.start()
    }
    private func streamSettings() {
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let peer = self.peer else { return }
                self.engine.readSettings { [weak peer] settings in
                    Task { @MainActor [weak peer] in
                        if let settings { peer?.send(ScanMessage(kind: "settings", settings: settings)) }
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func disconnect() { peer?.close() }
}
