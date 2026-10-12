//  StampCamApp.swift
//  StampCam — take photos, tap Done, get one PDF with time & location on every photo.

import SwiftUI

@main
struct StampCamApp: App {
    init() {
        Defaults.register()
    }

    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .preferredColorScheme(.dark)
        }
    }
}
