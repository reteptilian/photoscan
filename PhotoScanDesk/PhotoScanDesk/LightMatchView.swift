import SwiftUI

struct LightMatchView: View {
    @ObservedObject var matcher: LightMatchController
    @ObservedObject var model: DeskModel
    private var title: String {
        switch matcher.stage {
        case .prepare: "1 · Prepare with both lights"
        case .lightA: "2 · Save light A"
        case .lightB: "3 · Match light B"
        case .verifyA: "4 · Recheck light A"
        case .both: "5 · Finalize with both lights"
        case .ready: "Lights matched · Camera locked"
        case .invalid: "Restart light matching"
        }
    }
    private var instructions: String {
        switch matcher.stage {
        case .prepare:
            "Place a matte photographic gray card at the print position. Install the polarizers, minimize room light, and let the lights warm up. Turn BOTH lights on at roughly the desired temperature. Drag inside the preview to select a uniform gray area. The app will settle and lock focus, exposure, and white balance."
        case .lightA:
            "Turn OFF light B; leave only light A on. Keep its temperature and brightness fixed. Wait for a stable reading, then save A. Camera settings remain locked throughout the comparison."
        case .lightB:
            "Turn OFF light A and turn ON light B. Adjust B’s temperature dial to minimize the color difference. Pause after each adjustment for a stable average. Brightness is shown separately. A perfect match is not required; save the closest match you can achieve."
        case .verifyA:
            "Turn OFF light B and turn ON light A again, without changing its dial. The app checks both color and brightness against the saved A reading. If it does not repeat, check lighting and movement or restart."
        case .both:
            "Turn BOTH lights on. The app will establish the final exposure and lock it again, preserving focus and white balance. Keep the card and setup stationary."
        case .ready:
            "Wait for the final exposure check, then continue to capture gray balance and flat field using these locked settings. Keep the camera, lights, and polarizers in place for scanning."
        case .invalid:
            "The previous comparison is no longer valid. Check the camera connection and restart with both lights on."
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Match Lights").font(.title2.bold())
                Spacer()
                Label(matcher.adjusting ? "Configuring camera" : (matcher.baseline == nil ? "Preparing" : "Camera locked"),
                      systemImage: matcher.baseline == nil ? "camera" : "lock.fill")
                    .foregroundStyle(.secondary)
            }
            Text(title).font(.headline)
            Text(instructions).fixedSize(horizontal: false, vertical: true)
            GeometryReader { geometry in
                if let image = matcher.image {
                    let scale = min(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
                        .overlay(alignment: .topLeading) {
                            Rectangle().stroke(.yellow, lineWidth: 2).background(.yellow.opacity(0.15))
                                .frame(width: matcher.selection.width * size.width, height: matcher.selection.height * size.height)
                                .offset(x: matcher.selection.minX * size.width, y: matcher.selection.minY * size.height)
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                            guard !matcher.adjusting, matcher.reference == nil,
                                  matcher.stage == .prepare || matcher.stage == .lightA else { return }
                            let x0 = min(1, max(0, value.startLocation.x / size.width))
                            let y0 = min(1, max(0, value.startLocation.y / size.height))
                            let x1 = min(1, max(0, value.location.x / size.width))
                            let y1 = min(1, max(0, value.location.y / size.height))
                            matcher.selection = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
                        })
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                } else {
                    ProgressView("Waiting for live preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 220).background(Color(nsColor: .textBackgroundColor))
            readings.frame(height: 94, alignment: .topLeading)
            if let issue = matcher.issue {
                Text(issue).foregroundStyle(matcher.stage == .invalid ? .red : .orange)
                    .frame(height: 38, alignment: .topLeading)
            } else {
                Text(matcher.stable == nil ? "Waiting for a stable average…" : "Stable average ready")
                    .foregroundStyle(.secondary).frame(height: 38, alignment: .topLeading)
            }
            HStack {
                Button(matcher.stage == .ready ? "Close" : "Cancel") { model.closeLightMatching() }
                    .disabled(matcher.adjusting || model.busy)
                Button("Restart") { matcher.restart() }.disabled(matcher.adjusting || !model.connected)
                Spacer()
                if matcher.adjusting { ProgressView().controlSize(.small) }
                action.disabled(matcher.adjusting || !model.connected)
            }
            Text("Relative camera color match, not a Kelvin or Delta E measurement. Matching a gray card does not guarantee identical rendering of every color.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 800, height: 780)
        .interactiveDismissDisabled()
    }
    @ViewBuilder private var readings: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let reading = matcher.stable ?? matcher.reading {
                Text(String(format: "Linear RGB: %.4f · %.4f · %.4f", reading.rgb[0], reading.rgb[1], reading.rgb[2]))
                    .monospacedDigit().font(.caption)
                if let reference = matcher.reference, [.lightB, .verifyA].contains(matcher.stage) {
                    HStack(spacing: 20) {
                        Text(String(format: "Color difference: %.2f", reading.difference(from: reference)))
                        Text(String(format: "Brightness: %+.1f%%", (reading.brightness / reference.brightness - 1) * 100))
                        if let best = matcher.best { Text(String(format: "Best stable match: %.2f", best)) }
                    }.monospacedDigit()
                    let warm = reading.warmth(from: reference)
                    let tint = reading.tint(from: reference)
                    Text("\(abs(warm) < 0.015 ? "Similar warmth" : (warm > 0 ? "Warmer than A" : "Cooler than A")) · \(abs(tint) < 0.015 ? "Similar tint" : (tint > 0 ? "Greener than A" : "More magenta than A"))")
                    if matcher.stage == .verifyA {
                        Text(matcher.verificationPasses ? "A repeats within the check tolerance" : "A has not repeated yet; check the setup")
                            .foregroundStyle(matcher.verificationPasses ? .green : .orange)
                    }
                }
            }
            if matcher.stage == .ready, let a = matcher.reference, let b = matcher.savedB {
                Text(String(format: "Saved A/B color difference: %.2f", b.difference(from: a))).monospacedDigit()
                Text("Next: Capture Gray Chart, then Capture Flat Field.")
            }
        }
    }
    @ViewBuilder private var action: some View {
        switch matcher.stage {
        case .prepare:
            Button("Settle & Lock Camera", action: matcher.prepare).disabled(matcher.stable == nil)
        case .lightA:
            Button("Save Light A", action: matcher.saveA).disabled(matcher.stable == nil)
        case .lightB:
            Button("Save Light B", action: matcher.saveLightB).disabled(matcher.stable == nil)
        case .verifyA:
            Button("Confirm Light A", action: matcher.verify).disabled(!matcher.verificationPasses)
        case .both:
            Button("Set Final Exposure", action: matcher.finalize).disabled(!matcher.hasFreshFrame)
        case .ready:
            Button("Continue to Gray Balance") {
                model.closeLightMatching()
                model.captureGrayChart()
            }.disabled(!matcher.cameraReady || matcher.stable == nil || model.folder == nil)
        case .invalid:
            Button("Start Again", action: matcher.restart)
        }
    }
}
