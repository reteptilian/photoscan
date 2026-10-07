import AppKit
import Combine
import ImageIO
import Network

struct ScanManifest: Codable {
    var schemaVersion = 1
    let assetID: UUID
    var captures: [ScanSide.RawValue: CaptureInfo]
}

@MainActor
final class DeskModel: ObservableObject {
    @Published var cameras: [NWBrowser.Result] = []
    @Published var status = "Searching for cameras"
    @Published var connected = false
    @Published var busy = false
    @Published var folder: URL?
    @Published var preview: NSImage?
    @Published var latestURL: URL?
    @Published var dimensions = ""
    @Published var count = 0
    @Published var error: String?
    @Published var settings: CameraSettings?
    private var browser: NWBrowser?
    private var peer: ScanConnection?
    private var pending: CaptureRequest?
    private var pendingCommand: UUID?
    private var timeout: Task<Void, Never>?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: ScanWire.service, domain: nil), using: ScanWire.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                self?.cameras = results.sorted { String(describing: $0.endpoint) < String(describing: $1.endpoint) }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed(let error), .waiting(let error): self?.error = error.localizedDescription
                default: break
                }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }
    func connect(_ camera: NWBrowser.Result) {
        disconnect()
        error = nil; status = "Connecting"
        let peer = ScanConnection(NWConnection(to: camera.endpoint, using: ScanWire.parameters()))
        self.peer = peer
        peer.onClose = { [weak self] reason in
            self?.connected = false; self?.peer = nil
            self?.settings = nil
            self?.finish(); self?.status = "Disconnected"; self?.error = reason
        }
        peer.onMessage = { [weak self] message, image in
            guard let self else { return }
            switch message.kind {
            case "ready": self.connected = true; self.status = "Camera ready"
            case "settings":
                self.settings = message.settings
                if let commandID = message.commandID, commandID == self.pendingCommand {
                    self.finish(); self.status = message.settings?.locked == true ? "Settings locked" : "Automatic settings"
                }
            case "error":
                let captureError = message.request != nil && message.request == self.pending
                let settingsError = message.commandID != nil && message.commandID == self.pendingCommand
                guard captureError || settingsError else { return }
                self.error = message.text; self.finish(); self.status = "Camera ready"
            case "photo":
                guard let info = message.capture, info.request == self.pending else { return }
                self.save(info, image: image)
            default: break
            }
        }
        peer.start()
    }
    func disconnect() {
        peer?.close()
        peer = nil; connected = false; finish()
        settings = nil
    }
    func setLocked(_ locked: Bool) {
        guard connected, !busy, settings != nil else { return }
        let commandID = UUID()
        pendingCommand = commandID; busy = true; error = nil
        status = locked ? "Settling and locking settings" : "Unlocking settings"
        peer?.send(ScanMessage(kind: locked ? "lockSettings" : "unlockSettings", commandID: commandID))
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.pendingCommand == commandID else { return }
            self.peer?.close("Settings command timed out. Reconnect and try again.")
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Choose Archive"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let folder { folder.stopAccessingSecurityScopedResource() }
        _ = url.startAccessingSecurityScopedResource()
        folder = url; error = nil
    }
    func capture() {
        guard connected, !busy, folder != nil else { return }
        let request = CaptureRequest(assetID: UUID(), side: .front)
        pending = request; busy = true; error = nil; status = "Capturing and receiving"
        peer?.send(ScanMessage(kind: "capture", request: request))
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, self.pending == request else { return }
            self.peer?.close("Capture timed out. Reconnect and try again.")
        }
    }
    private func finish() {
        timeout?.cancel(); timeout = nil; pending = nil; pendingCommand = nil; busy = false
    }
    private func save(_ info: CaptureInfo, image: Data) {
        defer { finish() }
        guard let folder else { return }
        do {
            guard ["heic", "jpg"].contains(info.fileExtension), !image.isEmpty,
                  CGImageSourceCreateWithData(image as CFData, nil) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let destination = folder.appendingPathComponent(info.request.assetID.uuidString, isDirectory: true)
            let staging = folder.appendingPathComponent(".pending-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            do {
                let filename = info.request.side.rawValue + "." + info.fileExtension
                try image.write(to: staging.appendingPathComponent(filename), options: .atomic)
                let manifest = ScanManifest(assetID: info.request.assetID, captures: [info.request.side.rawValue: info])
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(manifest).write(to: staging.appendingPathComponent("metadata.json"), options: .atomic)
                try FileManager.default.moveItem(at: staging, to: destination)
                latestURL = destination.appendingPathComponent(filename)
                preview = NSImage(data: image)
                dimensions = "\(info.width) x \(info.height)"
                count += 1; status = "Saved"
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        } catch { self.error = "Could not save photo: " + error.localizedDescription; status = "Save failed" }
    }
    func reveal() {
        if let latestURL { NSWorkspace.shared.activateFileViewerSelecting([latestURL]) }
    }
    func name(_ camera: NWBrowser.Result) -> String {
        if case .service(let name, _, _, _) = camera.endpoint { return name }
        return String(describing: camera.endpoint)
    }
}
