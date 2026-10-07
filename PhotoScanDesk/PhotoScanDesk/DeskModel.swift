import AppKit
import Combine
import ImageIO
import Network

struct ChartReference: Identifiable {
    let info: CaptureInfo
    let data: Data
    var id: UUID { info.request.assetID }
}
enum ScanPreview: String, CaseIterable { case original = "Original", corrected = "Corrected", cropped = "Cropped" }
struct CropReview: Identifiable {
    let id = UUID()
    let originalURL: URL
    let sourceURL: URL
    let candidates: [PrintBoundary]
    let preview: CGImage
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
    @Published var flatField: FlatFieldProfile?
    @Published var applyCorrection = true
    @Published var previewMode: ScanPreview = .corrected
    @Published var correctedPreview: NSImage?
    @Published var croppedPreview: NSImage?
    @Published var croppedDimensions = ""
    @Published var cropReview: CropReview?
    private var croppedURL: URL?
    var displayedPreview: NSImage? {
        switch previewMode {
        case .original: preview
        case .corrected: correctedPreview ?? preview
        case .cropped: croppedPreview ?? preview
        }
    }
    var displayedDimensions: String { previewMode == .cropped && croppedPreview != nil ? croppedDimensions : dimensions }
    @Published var grayBalance: GrayBalanceProfile?
    @Published var applyGrayBalance = true
    @Published var chartReference: ChartReference?
    private var referenceCapture = false
    private var chartCapture = false
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
        guard !busy else { return }
        disconnect()
        error = nil; status = "Connecting"
        let peer = ScanConnection(NWConnection(to: camera.endpoint, using: ScanWire.parameters()))
        self.peer = peer
        peer.onClose = { [weak self] reason in
            self?.connected = false; self?.peer = nil
            self?.settings = nil
            self?.flatField = nil
            self?.grayBalance = nil; self?.chartReference = nil
            self?.finish(); self?.status = "Disconnected"; self?.error = reason
        }
        peer.onMessage = { [weak self] message, image in
            guard let self else { return }
            switch message.kind {
            case "ready": self.connected = true; self.status = "Camera ready"
            case "settings":
                self.settings = message.settings
                if message.settings?.locked != true { self.flatField = nil; self.grayBalance = nil; self.chartReference = nil }
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
        grayBalance = nil; chartReference = nil
    }
    func setLocked(_ locked: Bool) {
        guard connected, !busy, settings != nil else { return }
        if !locked { flatField = nil; grayBalance = nil; chartReference = nil }
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
        folder = url; error = nil; flatField = nil; grayBalance = nil; chartReference = nil
    }
    func capture() {
        beginCapture(reference: false)
    }
    func captureFlatField() {
        guard settings?.locked == true else { return }
        beginCapture(reference: true)
    }
    func captureGrayChart() {
        guard settings?.locked == true else { return }
        beginCapture(reference: false, chart: true)
    }
    private func beginCapture(reference: Bool, chart: Bool = false) {
        guard connected, !busy, folder != nil else { return }
        referenceCapture = reference
        chartCapture = chart
        let request = CaptureRequest(assetID: UUID(), side: .front)
        pending = request; busy = true; error = nil
        status = reference ? "Capturing flat field" : (chart ? "Capturing DKC-Pro chart" : "Capturing and receiving")
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
        let chart = chartCapture
        let profile = applyCorrection && !reference && !chart ? flatField : nil
        let balance = applyGrayBalance && !reference && !chart ? grayBalance : nil
        processing = true; finish()
        status = reference ? "Building flat field" : "Saving and processing"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(URL?, FlatFieldProfile?), Error> in
                do {
                    if reference {
                        return .success((nil, try ScanArchive.saveReference(info, data: image, folder: folder)))
                    }
                    return .success((try ScanArchive.save(info, data: image, folder: folder, profile: profile, grayBalance: balance), nil))
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
                    if chart && connected && settings?.locked == true {
                        chartReference = ChartReference(info: info, data: image)
                    }
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
        croppedPreview = nil; croppedURL = nil; croppedDimensions = ""; previewMode = .corrected
        latestURL = url; preview = NSImage(data: image)
        correctedPreview = NSImage(contentsOf: url.deletingLastPathComponent().appendingPathComponent(info.request.side.rawValue + "-corrected.tiff"))
        dimensions = "\(info.width) x \(info.height)"; count += 1
    }
    func clearFlatField() {
        flatField = nil
    }
    func clearGrayBalance() { grayBalance = nil }
    func detectPrint() {
        guard !busy, let originalURL = latestURL else { return }
        let corrected = originalURL.deletingLastPathComponent().appendingPathComponent(originalURL.deletingPathExtension().lastPathComponent + "-corrected.tiff")
        let sourceURL = FileManager.default.fileExists(atPath: corrected.path) ? corrected : originalURL
        busy = true; processing = true; error = nil; status = "Detecting print"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<([PrintBoundary], CGImage), Error> in
                do {
                    let preview = try PrintCrop.reviewPreview(url: sourceURL)
                    let candidates = try PrintCrop.detect(PrintCrop.image(url: sourceURL))
                    return .success((candidates, preview))
                }
                catch { return .failure(error) }
            }.value
            processing = false; finish()
            switch result {
            case .success(let (candidates, preview)):
                cropReview = CropReview(originalURL: originalURL, sourceURL: sourceURL, candidates: candidates, preview: preview)
                status = candidates.isEmpty ? "No boundary detected; manual crop available" : "Review print boundary"
            case .failure(let failure): error = failure.localizedDescription; status = "Detection failed"
            }
        }
    }
    func saveCrop(_ boundary: PrintBoundary) {
        guard !busy, let review = cropReview else { return }
        busy = true; processing = true; error = nil; status = "Saving crop"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                do { return .success(try PrintCrop.save(originalURL: review.originalURL, sourceURL: review.sourceURL, boundary: boundary)) }
                catch { return .failure(error) }
            }.value
            processing = false; finish()
            switch result {
            case .success(let url):
                croppedURL = url; croppedPreview = NSImage(contentsOf: url); previewMode = .cropped
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                   let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                   let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
                    croppedDimensions = "\(width) x \(height)"
                }
                cropReview = nil; status = "Crop saved"
            case .failure(let failure): error = failure.localizedDescription; status = "Crop failed"
            }
        }
    }
    func calibrateGray(target: DKCGrayTarget, selection: CGRect) {
        guard !busy, let chart = chartReference, let folder, settings?.locked == true else { return }
        busy = true; processing = true; error = nil; status = "Calibrating gray balance"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<GrayBalanceProfile, Error> in
                do { return .success(try ScanArchive.saveGrayReference(chart.info, data: chart.data, folder: folder, target: target, selection: selection)) }
                catch { return .failure(error) }
            }.value
            processing = false; finish()
            switch result {
            case .success(let profile):
                if connected && settings?.locked == true { grayBalance = profile }
                chartReference = nil; status = "Gray balance saved"
            case .failure(let failure): error = failure.localizedDescription; status = "Calibration failed"
            }
        }
    }
    func reveal() {
        let url = previewMode == .cropped ? (croppedURL ?? latestURL) : latestURL
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    func name(_ camera: NWBrowser.Result) -> String {
        if case .service(let name, _, _, _) = camera.endpoint { return name }
        return String(describing: camera.endpoint)
    }
}
