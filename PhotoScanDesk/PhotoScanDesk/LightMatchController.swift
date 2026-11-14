import AppKit
import Combine

@MainActor
final class LightMatchController: ObservableObject, Identifiable {
    enum Stage { case prepare, lightA, lightB, verifyA, both, ready, invalid }
    let id = UUID()
    @Published private(set) var stage: Stage = .prepare
    @Published private(set) var adjusting = false
    @Published private(set) var image: NSImage?
    @Published private(set) var reading: LightReading?
    @Published private(set) var stable: LightReading?
    @Published private(set) var reference: LightReading?
    @Published private(set) var savedB: LightReading?
    @Published private(set) var best: Double?
    @Published private(set) var issue: String?
    @Published private(set) var baseline: CameraSettings?
    @Published var selection = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3) {
        didSet {
            guard oldValue != selection else { return }
            if reference != nil { invalidate("The sample area changed. Restart to measure both lights in the same area.") }
            resetReadings()
        }
    }
    let send: (ScanMessage) -> Void
    let command: (String, @escaping (Result<CameraSettings, Error>) -> Void) -> Void
    var onFinalized: ((CameraSettings) -> Void)?
    private var window = LightReadingWindow()
    private var polling: Task<Void, Never>?
    private var requestID: UUID?
    private var requestedAt = Date.distantPast
    private var lastFrame = Date.distantPast
    private var active = true
    var cameraReady: Bool { stage == .ready && stable != nil && issue == nil }
    var hasFreshFrame: Bool { Date().timeIntervalSince(lastFrame) < 2 }

    init(send: @escaping (ScanMessage) -> Void,
         command: @escaping (String, @escaping (Result<CameraSettings, Error>) -> Void) -> Void) {
        self.send = send; self.command = command
        polling = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }
    func stop() { active = false; polling?.cancel(); polling = nil; requestID = nil }
    private func poll() {
        guard active else { return }
        if Date().timeIntervalSince(lastFrame) > 2 {
            reading = nil; stable = nil; window.reset()
            if !adjusting && stage != .invalid { issue = "Waiting for a fresh camera sample…" }
        }
        guard requestID == nil || Date().timeIntervalSince(requestedAt) > 2 else { return }
        let id = UUID(); requestID = id; requestedAt = Date()
        send(ScanMessage(kind: "getLightPreview", commandID: id))
    }
    private func resetReadings() {
        window.reset(); reading = nil; stable = nil; requestID = nil; lastFrame = .distantPast
    }
    func receive(_ message: ScanMessage, data: Data) {
        guard active, message.commandID == requestID else { return }
        requestID = nil
        guard !adjusting, stage != .invalid else { return }
        guard !data.isEmpty, data.count <= 3 * 1024 * 1024, let settings = message.settings else {
            resetReadings(); issue = "Waiting for camera preview. Keep the phone app open."; return
        }
        if let baseline, !baseline.matchesLocked(settings) {
            invalidate("Camera settings changed. Restart light matching."); return
        }
        image = NSImage(data: data)
        lastFrame = Date()
        do {
            let sample = try LightReading.measure(data: data, selection: selection)
            lastFrame = Date(); reading = sample; issue = nil
            window.add(sample, at: lastFrame); stable = window.average
            if stage == .lightB, let stable, let reference {
                best = min(best ?? .infinity, stable.difference(from: reference))
            }
        } catch {
            window.reset(); reading = nil; stable = nil; issue = error.localizedDescription
        }
    }
    func observe(_ settings: CameraSettings?) {
        guard active, !adjusting, stage != .invalid, let baseline else { return }
        guard let settings, baseline.matchesLocked(settings) else {
            invalidate("Camera lock was lost or settings changed. Restart light matching."); return
        }
    }
    func invalidate(_ reason: String) {
        stage = .invalid; baseline = nil; reference = nil; savedB = nil; best = nil
        resetReadings(); issue = reason
    }
    func restart() {
        guard !adjusting else { return }
        stage = .prepare; baseline = nil; reference = nil; savedB = nil; best = nil; issue = nil
        resetReadings()
    }
    func prepare() {
        guard active, stage == .prepare, stable != nil else { return }
        adjust("prepareLightMatching") { settings in
            self.baseline = settings; self.stage = .lightA
        }
    }
    func saveA() {
        guard stage == .lightA, let stable else { return }
        reference = stable; stage = .lightB; best = nil; resetReadings()
    }
    func saveLightB() {
        guard stage == .lightB, let stable else { return }
        savedB = stable; stage = .verifyA; resetReadings()
    }
    var verificationPasses: Bool {
        guard let stable, let reference else { return false }
        return stable.difference(from: reference) <= 1 && abs(stable.brightness / reference.brightness - 1) <= 0.08
    }
    func verify() {
        guard stage == .verifyA, verificationPasses else { return }
        stage = .both; resetReadings()
    }
    func finalize() {
        // Let exposure recover even if the combined sample is currently clipped.
        guard active, stage == .both, hasFreshFrame else { return }
        let previous = baseline
        adjust("finalizeLightExposure") { settings in
            guard let previous,
                  abs(previous.focusPosition - settings.focusPosition) <= 0.002,
                  previous.redGain == settings.redGain, previous.greenGain == settings.greenGain,
                  previous.blueGain == settings.blueGain, previous.sessionID == settings.sessionID else {
                self.invalidate("Focus or white balance changed while finalizing. Restart light matching."); return
            }
            self.baseline = settings; self.stage = .ready
            self.onFinalized?(settings)
        }
    }
    private func adjust(_ kind: String, success: @escaping (CameraSettings) -> Void) {
        adjusting = true; issue = nil; resetReadings()
        command(kind) { [weak self] result in
            guard let self, self.active else { return }
            self.adjusting = false; self.resetReadings()
            switch result {
            case .success(let settings):
                guard settings.locked else { self.invalidate("Camera did not lock. Restart light matching."); return }
                success(settings)
            case .failure(let error): self.invalidate(error.localizedDescription)
            }
        }
    }
}
