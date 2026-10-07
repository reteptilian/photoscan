import AppKit
import Combine
import ImageIO
import CoreImage
import Network
import UniformTypeIdentifiers

struct ChartReference: Identifiable {
    let info: CaptureInfo
    let data: Data
    var id: UUID { info.request.assetID }
}
enum ScanPreview: String, CaseIterable { case finished = "Finished", original = "Source" }
struct CropReview: Identifiable {
    let id = UUID()
    let assetURL: URL
    let candidates: [PrintBoundary]
    let preview: CGImage
    let isRevision: Bool
}

@MainActor
final class DeskModel: ObservableObject {
    @Published var cameras: [NWBrowser.Result] = []
    @Published var status = "Searching for cameras"
    @Published var connected = false
    @Published var supportsSettings = false
    @Published var supportsCalibration = false
    @Published var cameraVersion = ""
    @Published var connectionPath = ""
    private var capturePhase = ""
    @Published var busy = false
    @Published var folder: URL?
    @Published var preview: NSImage?
    @Published var latestURL: URL?
    @Published var dimensions = ""
    @Published var count = 0
    @Published var extractedAssets: [URL] = []
    @Published var error: String?
    @Published var settings: CameraSettings?
    @Published var flatField: FlatFieldProfile?
    @Published var applyCorrection = true
    @Published var previewMode: ScanPreview = .finished
    @Published var finishedPreview: NSImage?
    @Published var cropReview: CropReview?
    @Published var assetURL: URL?
    @Published var document = DocumentMetadata()
    @Published var showMetadata = false
    @Published var finishedDimensions = ""
    var displayedPreview: NSImage? { previewMode == .original ? preview : finishedPreview }
    var displayedDimensions: String { previewMode == .original ? dimensions : finishedDimensions }
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
        error = nil; status = "Connecting to camera"
        let peer = ScanConnection(NWConnection(to: camera.endpoint, using: ScanWire.parameters()), app: .desk)
        self.peer = peer
        peer.onPath = { [weak self] path in self?.connectionPath = path }
        peer.onReceiveProgress = { [weak self] received, total in
            guard let self, self.pending != nil else { return }
            self.capturePhase = "Receiving image: \(received * 100 / total)%"
            self.status = self.capturePhase
        }
        peer.onTransportReady = { [weak self] in self?.status = "Checking camera compatibility" }
        peer.onReady = { [weak self, weak peer] in
            self?.supportsSettings = peer?.supports(ScanCapability.settings) == true
            self?.supportsCalibration = peer?.supports(ScanCapability.settings) == true
                && peer?.supports(ScanCapability.captureSettings) == true
            self?.cameraVersion = peer?.session.remote?.summary ?? ""
            self?.status = "Waiting for camera readiness"
            self?.timeout = Task { [weak self, weak peer] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, self?.connected == false else { return }
                peer?.close("Camera readiness timed out. Keep the phone app open and reconnect.")
            }
        }
        peer.onClose = { [weak self] reason in
            self?.connected = false; self?.peer = nil
            self?.settings = nil
            self?.supportsSettings = false; self?.supportsCalibration = false; self?.cameraVersion = ""
            self?.flatField = nil
            self?.grayBalance = nil; self?.chartReference = nil
            self?.finish(); self?.connectionPath = ""; self?.status = "Disconnected"; self?.error = reason
        }
        peer.onMessage = { [weak self] message, image in
            guard let self else { return }
            guard self.connected || message.kind == "ready" else { return }
            switch message.kind {
            case "ready":
                self.timeout?.cancel(); self.timeout = nil
                self.connected = true; self.status = "Camera ready"
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
            case "captureProgress":
                guard message.request == self.pending, let stage = message.text else { return }
                self.capturePhase = stage; self.status = stage
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
        supportsSettings = false; supportsCalibration = false; cameraVersion = ""; connectionPath = ""
        flatField = nil
        grayBalance = nil; chartReference = nil
    }
    func setLocked(_ locked: Bool) {
        guard connected, supportsSettings, !busy, settings != nil else { return }
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
        guard supportsCalibration, settings?.locked == true else { return }
        beginCapture(reference: true)
    }
    func captureGrayChart() {
        guard supportsCalibration, settings?.locked == true else { return }
        beginCapture(reference: false, chart: true)
    }
    private func beginCapture(reference: Bool, chart: Bool = false) {
        guard connected, !busy, cropReview == nil, folder != nil else { return }
        referenceCapture = reference
        chartCapture = chart
        let request = CaptureRequest(assetID: UUID(), side: .front)
        pending = request; busy = true; error = nil
        status = reference ? "Capturing flat field" : (chart ? "Capturing DKC-Pro chart" : "Capturing and receiving")
        capturePhase = peer?.supports(ScanCapability.captureProgress) == true
            ? "Waiting for the phone to acknowledge Capture" : "Waiting for captured image (phone has no progress reporting)"
        status = capturePhase
        peer?.send(ScanMessage(kind: "capture", request: request))
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, self.pending == request else { return }
            self.peer?.close("Capture timed out after 60 seconds. Last stage: \(self.capturePhase). Reconnect and try again.")
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
                    if chart { return .success((nil, nil)) }
                    return .success((try ScanArchive.save(info, data: image, folder: folder, profile: profile, grayBalance: balance), nil))
                } catch { return .failure(error) }
            }.value
            processing = false; finish()
            switch result {
            case .success(let (url, calibration)):
                if let calibration {
                    if connected && settings?.locked == true { flatField = calibration }
                    status = "Flat field saved"
                } else if chart {
                    if connected && settings?.locked == true { chartReference = ChartReference(info: info, data: image) }
                    status = "Select the neutral gray patch"
                } else if let url {
                    assetURL = url; latestURL = nil; finishedPreview = nil; finishedDimensions = ""
                    document = DocumentMetadata(); previewMode = .finished
                    extractedAssets = []
                    preview = NSImage(data: image); dimensions = "\(info.width) x \(info.height)"
                    status = "Source saved; crop review pending"
                    detectPrint()
                }
            case .failure(let failure):
                error = failure.localizedDescription; status = "Save failed"
            }
        }
    }
    func clearFlatField() {
        flatField = nil
    }
    func clearGrayBalance() { grayBalance = nil }
    func detectPrint() {
        guard !busy, let assetURL else { return }
        busy = true; processing = true; error = nil; status = "Detecting prints"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<([PrintBoundary], CGImage, Bool), Error> in
                do {
                    let manifest = try ScanArchive.read(assetURL)
                    let preview = try ScanArchive.previewImage(manifest, asset: assetURL)
                    let candidates = (try? PrintCrop.detect(CoreImage.CIImage(cgImage: preview))) ?? []
                    return .success((manifest.finished != nil ? [manifest.recipe.crop ?? .manual] : candidates, preview, manifest.finished != nil))
                } catch { return .failure(error) }
            }.value
            processing = false; finish()
            switch result {
            case .success(let (candidates, preview, revision)):
                cropReview = CropReview(assetURL: assetURL, candidates: candidates, preview: preview, isRevision: revision)
                status = candidates.isEmpty ? "No boundary detected; manual crop available" : "Review print boundaries"
            case .failure(let failure): error = failure.localizedDescription; status = "Review pending; detection failed"
            }
        }
    }
    func selectExtracted(_ url: URL) {
        guard !busy, let manifest = try? ScanArchive.read(url), let final = manifest.finished else { return }
        assetURL = url; latestURL = url.appendingPathComponent(final.filename)
        finishedPreview = NSImage(contentsOf: latestURL!); previewMode = .finished
        document = manifest.document; finishedDimensions = "\(final.width) x \(final.height)"
    }
    func extractPrints(_ boundaries: [PrintBoundary]) {
        guard !busy, let review = cropReview, !review.isRevision else { return }
        busy = true; processing = true; error = nil; status = "Extracting prints"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[URL], Error> in
                Result { try ScanArchive.extract(frame: review.assetURL, boundaries: boundaries) }
            }.value
            processing = false; finish()
            switch result {
            case .success(let assets):
                extractedAssets = assets; count += assets.count
                if let first = assets.first { selectExtracted(first) }
                cropReview = nil; status = "\(assets.count) prints saved"
            case .failure(let failure):
                error = failure.localizedDescription; status = "Extraction failed; source preserved"
            }
        }
    }
    func saveCrop(_ boundary: PrintBoundary) { publish(crop: boundary, review: true) }
    func skipCrop() { publish(crop: nil, review: true) }
    func saveMetadata(_ draft: DocumentMetadata) { publish(metadata: draft) }
    func rotate() {
        guard let assetURL, let manifest = try? ScanArchive.read(assetURL) else { return }
        publish(turns: manifest.recipe.quarterTurns + 1)
    }
    private func publish(crop: PrintBoundary? = nil, review: Bool = false, metadata: DocumentMetadata? = nil, turns: Int? = nil) {
        guard !busy, let assetURL else { return }
        busy = true; processing = true; error = nil; status = "Rendering finished scan"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                do {
                    var recipe = try ScanArchive.read(assetURL).recipe
                    if review { recipe.crop = crop; recipe.cropReviewed = true }
                    if let turns { recipe.quarterTurns = turns }
                    return .success(try ScanArchive.regenerate(asset: assetURL, document: metadata, recipe: recipe))
                } catch { return .failure(error) }
            }.value
            processing = false; finish()
            switch result {
            case .success(let url):
                if latestURL == nil { count += 1 }
                latestURL = url; finishedPreview = NSImage(contentsOf: url); previewMode = .finished
                if let manifest = try? ScanArchive.read(assetURL), let final = manifest.finished {
                    document = manifest.document; finishedDimensions = "\(final.width) x \(final.height)"
                }
                cropReview = nil; showMetadata = false; status = "Finished scan saved"
            case .failure(let failure): error = failure.localizedDescription; status = latestURL == nil ? "Source saved; finish pending" : "Previous finished revision preserved"
            }
        }
    }
    func export(_ type: UTType) {
        guard !busy, let assetURL, let latestURL else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = latestURL.deletingPathExtension().lastPathComponent + (type == .jpeg ? ".jpg" : ".tiff")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        busy = true; processing = true; error = nil
        Task {
            let result = await Task.detached { () -> Result<Void, Error> in
                Result { try ScanArchive.export(asset: assetURL, to: destination, type: type) }
            }.value
            processing = false; finish()
            switch result {
            case .success: status = "Export saved"
            case .failure(let failure): error = failure.localizedDescription
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
        if let latestURL { NSWorkspace.shared.activateFileViewerSelecting([latestURL]) }
    }
    func revealSource() {
        guard let assetURL, let manifest = try? ScanArchive.read(assetURL) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([ScanArchive.sourceURL(manifest, asset: assetURL)])
    }
    func name(_ camera: NWBrowser.Result) -> String {
        if case .service(let name, _, _, _) = camera.endpoint { return name }
        return String(describing: camera.endpoint)
    }
}
