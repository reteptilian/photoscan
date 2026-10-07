//
//  ContentView.swift
//  PhotoScanCamera
//
//  Created by Peter Esbensen on 10/6/26.
//

import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var model = CameraModel()
    @State private var diagnosticSnapshot: URL?
    var body: some View {
        VStack(spacing: 16) {
            CameraPreview(session: model.engine.session)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay { if !model.ready { ProgressView().tint(.white) } }
            HStack {
                Image(systemName: model.connected ? "link" : "wifi")
                Text(model.status)
                if model.busy { ProgressView() }
                Spacer()
                if model.connected { Button("Disconnect", systemImage: "xmark.circle", action: model.disconnect) }
            }
            HStack {
                Button(diagnosticSnapshot == nil ? "Prepare Diagnostics" : "Refresh Diagnostics") {
                    do { diagnosticSnapshot = try ScanDiagnostics.shared.shareSnapshot() }
                    catch { model.error = error.localizedDescription }
                }
                if let diagnosticSnapshot { ShareLink("Share Diagnostics", item: diagnosticSnapshot) }
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }
        .padding()
        .task { await model.start() }
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}
