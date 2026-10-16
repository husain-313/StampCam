//  LibraryPicker.swift
//  Opens the photo library on top of whatever is showing. If a menu or another screen is
//  still opening or closing, it waits a moment and tries again, so a fast tap is never lost.

import UIKit
import PhotosUI
import UniformTypeIdentifiers

enum LibraryPicker {
    /// The picker that is open (or about to open). Only one at a time.
    private static var current: Session?

    /// Opens the library; [onPicked] gets the chosen photos' data, in the order picked.
    /// Nothing is called if you close the library without picking.
    static func present(limit: Int = 30, onPicked: @escaping ([Data]) -> Void) {
        guard current == nil else { return }       // already opening
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = limit
        config.selection = .ordered
        let picker = PHPickerViewController(configuration: config)
        let session = Session(onPicked: onPicked)
        picker.delegate = session
        current = session
        tryPresent(picker, attempt: 0)
    }

    private static func tryPresent(_ picker: UIViewController, attempt: Int) {
        guard let top = topController(), !isBusy(top) else {
            if attempt < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { tryPresent(picker, attempt: attempt + 1) }
            } else {
                current = nil                       // gave up; a new tap can try again
            }
            return
        }
        top.present(picker, animated: true)
    }

    /// True while a screen or menu is still moving in or out.
    private static func isBusy(_ vc: UIViewController) -> Bool {
        vc.isBeingPresented || vc.isBeingDismissed || vc.transitionCoordinator != nil
            || vc.presentedViewController?.isBeingDismissed == true
    }

    private static func topController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        return top
    }

    private final class Session: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([Data]) -> Void
        init(onPicked: @escaping ([Data]) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else {
                LibraryPicker.current = nil
                return
            }
            var loaded = [Data?](repeating: nil, count: results.count)
            let group = DispatchGroup()
            for (index, result) in results.enumerated() {
                group.enter()
                result.itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    DispatchQueue.main.async {
                        loaded[index] = data
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) {
                LibraryPicker.current = nil
                let photos = loaded.compactMap { $0 }
                if !photos.isEmpty { self.onPicked(photos) }
            }
        }
    }
}
