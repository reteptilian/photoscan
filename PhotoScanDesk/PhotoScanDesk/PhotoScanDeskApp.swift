//
//  PhotoScanDeskApp.swift
//  PhotoScanDesk
//
//  Created by Peter Esbensen on 10/6/26.
//

import SwiftUI

@main
struct PhotoScanDeskApp: App {
    @StateObject private var model = DeskModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
