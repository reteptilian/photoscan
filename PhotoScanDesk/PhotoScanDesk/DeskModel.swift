import AppKit
import Combine
import ImageIO
import Network

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
    @Published var flatField: FlatFieldProfile?
    @Published var applyCorrection = true
    @Published var showCorrected = true
    @Published var correctedPreview: NSImage?
    private var referenceCapture = false
    private var processing = false
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
            self?.flatField = nil
            self?.finish(); self?.status = "Disconnected"; self?.error = reason
        }
        peer.onMessage = { [weak self] message, image in
            guard let self else { return }
            switch message.kind {
            case "ready": self.connected = true; self.status = "Camera ready"
            case "settings":
                self.settings = message.settings
                if message.settings?.locked != true { self.flatField = nil }
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
        flatField = nil
    }
    func setLocked(_ locked: Bool) {
        guard connected, !busy, settings != nil else { return }
        if !locked { flatField = nil }
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
        folder = url; error = nil; flatField = nil
    }
    func capture() {
        beginCapture(reference: false)
    }
    func captureFlatField() {
        guard settings?.locked == true else { return }
        beginCapture(reference: true)
    }
    private func beginCapture(reference: Bool) {
        guard connected, !busy, folder != nil else { return }
        referenceCapture = reference
        let request = CaptureRequest(assetID: UUID(), side: .front)
        pending = request; busy = true; error = nil
        status = reference ? "Capturing flat field" : "Capturing and receiving"
        peer?.send(ScanMessage(kind: "capture", request: request))
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, self.pending == request else { return }
            self.peer?.close("Capture timed out. Reconnect and try again.")
        }
    }
    private func finish() {
        timeout?.cancel(); timeout = nil; pending = nil; pendingCommand = nil; busy = processing
    }
    private func save(_ info: CaptureInfo, image: Data) {
        guard let folder else { return }
        let reference = referenceCapture
        let profile = applyCorrection && !reference ? flatField : nil
        processing = true; finish()
        status = reference ? "Building flat field" : "Saving and processing"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(URL?, FlatFieldProfile?), Error> in
                do {
                    if reference {
                        return .success((nil, try ScanArchive.saveReference(info, data: image, folder: folder)))
                    }
                    return .success((try ScanArchive.save(info, data: image, folder: folder, profile: profile), nil))
                } catch { return .failure(error) }
            }.value
            processing = false; finish()
            switch result {
            case .success(let (url, calibration)):
                if let calibration {
                    if connected && settings?.locked == true { flatField = calibration }
                    status = "Flat field saved"
                } else if let url {
                    displaySaved(url, image: image, info: info)
                    status = "Saved"
                }
            case .failure(let saved as SavedOriginalError):
                displaySaved(saved.url, image: image, info: info)
                error = saved.localizedDescription; status = "Original saved"
            case .failure(let failure):
                error = failure.localizedDescription; status = "Save failed"
            }
        }
    }
    private func displaySaved(_ url: URL, image: Data, info: CaptureInfo) {
        latestURL = url; preview = NSImage(data: image)
        correctedPreview = NSImage(contentsOf: url.deletingLastPathComponent().appendingPathComponent(info.request.side.rawValue + "-corrected.tiff"))
        dimensions = "\(info.width) x \(info.height)"; count += 1
    }
    func clearFlatField() {
        flatField = nil
    }
    func reveal() {
        if let latestURL { NSWorkspace.shared.activateFileViewerSelecting([latestURL]) }
    }
    func name(_ camera: NWBrowser.Result) -> String {
        if case .service(let name, _, _, _) = camera.endpoint { return name }
        return String(describing: camera.endpoint)
    }
}
