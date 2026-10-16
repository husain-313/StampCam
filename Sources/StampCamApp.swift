//  StampCamApp.swift
//  StampCam — take photos, tap Done, get one PDF with time & location on every photo.

import SwiftUI

@main
struct StampCamApp: App {
    init() {
        Defaults.register()
        // Once (4.1): remove the hidden text that 3.9–4.0 kept inside PDFs.
        if !UserDefaults.standard.bool(forKey: "cleanedPDFText41") {
            UserDefaults.standard.set(true, forKey: "cleanedPDFText41")
            DispatchQueue.global(qos: .utility).async { FileStore.removeHiddenTextFromOldPDFs() }
        }
    }

    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .preferredColorScheme(.dark)
        }
    }
}
