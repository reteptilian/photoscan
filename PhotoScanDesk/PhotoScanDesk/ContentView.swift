//
//  ContentView.swift
//  PhotoScanDesk
//
//  Created by Peter Esbensen on 10/6/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = DeskModel()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(model.status, systemImage: model.connected ? "link" : "wifi")
                    .help([model.cameraVersion, model.connectionPath].filter { !$0.isEmpty }.joined(separator: "\n"))
                Spacer()
                if model.connected {
                    Button("Disconnect", systemImage: "xmark.circle", action: model.disconnect)
                        .disabled(model.busy)
                } else {
                    Menu("Cameras", systemImage: "iphone") {
                        if model.cameras.isEmpty { Text("No cameras found") }
                        ForEach(model.cameras, id: \.endpoint) { camera in
                            Button(model.name(camera)) { model.connect(camera) }
                        }
                    }
                    .disabled(model.busy)
                }
                Button("Archive Folder", systemImage: "folder", action: model.chooseFolder)
                    .disabled(model.busy)
                Button("Capture", systemImage: "camera", action: model.capture)
                    .disabled(!model.connected || model.busy || model.folder == nil)
                    .keyboardShortcut(.space, modifiers: [])
            }
            .padding()
            Divider()
            HStack(alignment: .top, spacing: 16) {
                Button(model.settings?.locked == true ? "Unlock Settings" : "Lock Settings",
                       systemImage: model.settings?.locked == true ? "lock.open" : "lock") {
                    model.setLocked(model.settings?.locked != true)
                }
                .disabled(!model.connected || !model.supportsSettings || model.busy || model.settings == nil)
                if let settings = model.settings {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { settingsReadout(settings) }
                        VStack(alignment: .leading, spacing: 6) { settingsReadout(settings) }
                    }
                    .font(.caption).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal).padding(.vertical, 10)
            Divider()
            HStack {
                Button("Capture Flat Field", systemImage: "rectangle.dashed", action: model.captureFlatField)
                    .disabled(!model.connected || !model.supportsCalibration || model.busy || model.folder == nil || model.settings?.locked != true)
                Toggle("Flat-field correction", isOn: $model.applyCorrection)
                    .disabled(model.flatField == nil || model.busy)
                if model.flatField != nil {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green).help("Flat field ready")
                    Button(action: model.clearFlatField) { Image(systemName: "trash") }
                        .help("Clear flat field").disabled(model.busy)
                }
                Spacer()
                Picker("Preview", selection: $model.previewMode) {
                    ForEach(ScanPreview.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 250)
                .disabled(model.preview == nil)
            }
            .padding(.horizontal).padding(.vertical, 10)
            Divider()
            HStack {
                Button("Capture Gray Chart", systemImage: "eyedropper", action: model.captureGrayChart)
                    .disabled(!model.connected || !model.supportsCalibration || model.busy || model.folder == nil || model.settings?.locked != true)
                Toggle("Gray balance", isOn: $model.applyGrayBalance)
                    .disabled(model.grayBalance == nil || model.busy)
                if model.grayBalance != nil {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green).help("DKC-Pro gray balance ready")
                    Button(action: model.clearGrayBalance) { Image(systemName: "trash") }
                        .help("Clear gray balance").disabled(model.busy)
                }
                Spacer()
                Button("Review Prints", systemImage: "crop", action: model.detectPrint)
                    .disabled(model.busy || model.assetURL == nil)
            }
            .padding(.horizontal).padding(.vertical, 10)
            HStack {
                if !model.extractedAssets.isEmpty {
                    Picker("Print", selection: Binding(get: { model.assetURL ?? model.extractedAssets[0] },
                        set: { model.selectExtracted($0) })) {
                        ForEach(Array(model.extractedAssets.enumerated()), id: \.element) { index, url in
                            Text("Print \(index + 1)").tag(url)
                        }
                    }.frame(width: 150).disabled(model.busy)
                }
                Button("Skip Crop Review", action: model.skipCrop).disabled(model.busy || model.assetURL == nil || model.latestURL != nil)
                Button("Edit Metadata") { model.showMetadata = true }.disabled(model.busy || model.latestURL == nil)
                Button("Rotate Right", action: model.rotate).disabled(model.busy || model.latestURL == nil)
                Menu("Export") {
                    Button("JPEG") { model.export(.jpeg) }
                    Button("16-bit TIFF") { model.export(.tiff) }
                }.disabled(model.busy || model.latestURL == nil)
                Spacer()
                Button("Reveal Source", action: model.revealSource).disabled(model.assetURL == nil)
            }.padding(.horizontal).padding(.vertical, 8)
            Divider()
            ZStack {
                Color(nsColor: .textBackgroundColor)
                if let preview = model.displayedPreview {
                    Image(nsImage: preview).resizable().scaledToFit().padding(20)
                } else {
                    VStack {
                        Image(systemName: "photo").font(.system(size: 64)).foregroundStyle(.tertiary)
                        if model.assetURL != nil { Text("Finished scan pending crop review").foregroundStyle(.secondary) }
                    }
                }
                if model.busy { ProgressView().padding().background(.regularMaterial) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text(model.folder?.path ?? "No archive folder selected").lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(model.displayedDimensions)
                Text("\(model.count) saved")
                Button("Show in Finder", systemImage: "folder", action: model.reveal)
                    .disabled(model.latestURL == nil)
            }
            .font(.callout).padding()
            if let error = model.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled).padding([.horizontal, .bottom])
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { model.start() }
        .sheet(item: $model.chartReference) { chart in
            GrayChartView(chart: chart, model: model)
        }
        .sheet(isPresented: $model.showMetadata) { MetadataEditor(model: model) }
        .sheet(item: $model.cropReview) { review in
            CropReviewView(review: review, model: model)
        }
    }
    @ViewBuilder
    private func settingsReadout(_ settings: CameraSettings) -> some View {
        Text("ISO \(settings.iso, specifier: "%.0f")")
        Text("Shutter \(settings.exposureSeconds, specifier: "%.4f") s")
        Text("Focus \(settings.focusPosition, specifier: "%.3f")")
        Text("WB \(settings.whiteBalanceTemperature, specifier: "%.0f") K / \(settings.whiteBalanceTint, specifier: "%.1f")")
        Text("Max \(settings.width) x \(settings.height)")
    }
}

#Preview {
    ContentView()
}
