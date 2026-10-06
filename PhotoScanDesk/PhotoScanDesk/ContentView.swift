//
//  ContentView.swift
//  PhotoScanDesk
//
//  Created by Peter Esbensen on 10/6/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var model = DeskModel()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(model.status, systemImage: model.connected ? "link" : "wifi")
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
                }
                Button("Archive Folder", systemImage: "folder", action: model.chooseFolder)
                    .disabled(model.busy)
                Button("Capture", systemImage: "camera", action: model.capture)
                    .disabled(!model.connected || model.busy || model.folder == nil)
                    .keyboardShortcut(.space, modifiers: [])
            }
            .padding()
            Divider()
            ZStack {
                Color(nsColor: .textBackgroundColor)
                if let preview = model.preview {
                    Image(nsImage: preview).resizable().scaledToFit().padding(20)
                } else {
                    Image(systemName: "photo").font(.system(size: 64)).foregroundStyle(.tertiary)
                }
                if model.busy { ProgressView().padding().background(.regularMaterial) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text(model.folder?.path ?? "No archive folder selected").lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(model.dimensions)
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
    }
}

#Preview {
    ContentView()
}
