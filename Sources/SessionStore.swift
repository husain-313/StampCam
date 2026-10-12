//  SessionStore.swift
//  The current set of photos is saved to the iPhone as you shoot,
//  so nothing is lost if the app is closed, killed or the phone restarts.

import UIKit
import ImageIO
import CoreLocation

// MARK: - One photo in the current set

struct Shot: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    var latitude: Double?
    var longitude: Double?
    var placeName: String?

    // Optional so sessions saved by older versions still load.
    var kind: ShotKind? = nil
    var filter: DocFilter? = nil
    var idBackground: IDBackground? = nil
    var idSize: IDSize? = nil
    /// Added from the photo library (keeps its own date and location).
    var imported: Bool? = nil

    var shotKind: ShotKind { kind ?? .photo }

    var location: CLLocation? {
        guard let latitude, let longitude else { return nil }
        return CLLocation(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Storage

enum SessionStore {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Session", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static var indexURL: URL { folder.appendingPathComponent("session.json") }

    static func imageURL(_ id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).photo")
    }

    // MARK: Photos

    @discardableResult
    static func writeImage(_ data: Data, id: UUID) -> Bool {
        (try? data.write(to: imageURL(id), options: .atomic)) != nil
    }

    static func deleteImage(_ id: UUID) {
        try? FileManager.default.removeItem(at: imageURL(id))
    }

    /// Full-size photo (orientation applied).
    static func image(_ id: UUID) -> UIImage? {
        guard let data = try? Data(contentsOf: imageURL(id)) else { return nil }
        return UIImage(data: data)
    }

    /// Small, fast thumbnail (orientation applied).
    static func thumbnail(_ id: UUID, maxPixel: Int = 360) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(imageURL(id) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: Index

    static func save(_ shots: [Shot]) {
        guard let data = try? JSONEncoder().encode(shots) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    static func load() -> [Shot] {
        guard let data = try? Data(contentsOf: indexURL),
              let shots = try? JSONDecoder().decode([Shot].self, from: data) else { return [] }
        return shots.filter { FileManager.default.fileExists(atPath: imageURL($0.id).path) }
    }

    /// Deletes leftover photo files that aren't part of the set.
    static func removeOrphans(keeping ids: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "photo" {
            let name = file.deletingPathExtension().lastPathComponent
            if let id = UUID(uuidString: name), ids.contains(id) { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
