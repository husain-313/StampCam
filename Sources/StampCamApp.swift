//  StampCamApp.swift
//  StampCam — take photos, tap Done, get one PDF with time & location on every photo.

import SwiftUI

@main
struct StampCamApp: App {
    init() {
        Defaults.register()
        // Remove the hidden text that 3.9–4.0 kept inside PDFs. Marked done only after it
        // finishes, so if the app closes halfway it simply runs again next time (4.2).
        if !UserDefaults.standard.bool(forKey: "cleanedPDFText42") {
            DispatchQueue.global(qos: .utility).async {
                if FileStore.removeHiddenTextFromOldPDFs() {
                    UserDefaults.standard.set(true, forKey: "cleanedPDFText42")
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .preferredColorScheme(.dark)
        }
    }
}
