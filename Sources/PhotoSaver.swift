//  PhotoSaver.swift
//  Saves stamped photos to the Photos app, in a "StampCam" album.

import Foundation
import Photos
import CoreLocation

enum PhotoSaver {
    static let albumName = "StampCam"

    /// Asks for access once. `album` is false when only "add photos" access was given.
    static func requestAccess() async -> (canSave: Bool, album: Bool) {
        let full = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if full == .authorized || full == .limited { return (true, true) }
        let add = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return (add == .authorized || add == .limited, false)
    }

    private static func findAlbum() -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", albumName)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject
    }

    private static func albumCreatingIfNeeded() -> PHAssetCollection? {
        if let album = findAlbum() { return album }
        var id: String?
        try? PHPhotoLibrary.shared().performChangesAndWait {
            id = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: albumName)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let id else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// Saves one photo, dated when it was taken and tagged with where. Blocking: call off the main thread.
    @discardableResult
    static func save(_ data: Data, date: Date, location: CLLocation?, useAlbum: Bool) -> Bool {
        let album = useAlbum ? albumCreatingIfNeeded() : nil
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
                request.creationDate = date
                request.location = location
                if let album,
                   let placeholder = request.placeholderForCreatedAsset,
                   let change = PHAssetCollectionChangeRequest(for: album) {
                    change.addAssets([placeholder] as NSArray)
                }
            }
            return true
        } catch {
            return false
        }
    }
}
