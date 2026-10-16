//  Settings.swift
//  All user settings, their keys and default values.

import SwiftUI
import UIKit

// MARK: - Keys

enum Keys {
    static let showDate = "showDate"
    static let showTime = "showTime"
    static let showLocation = "showLocation"
    static let stampPosition = "stampPosition"
    static let stampSize = "stampSize"
    static let stampColor = "stampColor"
    static let quality = "quality"
    static let pageSize = "pageSize"
    static let shareAfterDone = "shareAfterDone"
    static let flashMode = "flashMode"
    static let askNameAfterDone = "askNameAfterDone"
    static let stampedPlaces = "stampedPlaces"
    static let use24Hour = "use24Hour"
    static let saveToPhotos = "saveToPhotos"
    // 2.0
    static let stampNote = "stampNote"
    static let showCoordinates = "showCoordinates"
    static let showHeading = "showHeading"
    // 2.5
    static let seenCameraTips = "seenCameraTips"
}

// MARK: - Defaults

enum Defaults {
    static let stampSize: Double = 0.035
    static let noteLimit = 60
    static let stampSizeRange: ClosedRange<Double> = 0.02...0.07

    static func register() {
        let d = UserDefaults.standard
        // Before 2.1 one switch ("Date & Time") showed both; keep the same choice for the date.
        if d.object(forKey: Keys.showDate) == nil, d.object(forKey: Keys.showTime) != nil {
            d.set(d.bool(forKey: Keys.showTime), forKey: Keys.showDate)
        }
        // 3.5 removed these options: Done always saves quietly, pages fit the photo,
        // and the stamp has no GPS coordinates or compass direction.
        for key in [Keys.askNameAfterDone, Keys.shareAfterDone, Keys.showCoordinates, Keys.showHeading] {
            d.set(false, forKey: key)
        }
        d.set(PageSize.photo.rawValue, forKey: Keys.pageSize)
        // 3.9: flash starts off (once); after that your choice is remembered.
        if !d.bool(forKey: "flashOffSince39") {
            d.set(FlashMode.off.rawValue, forKey: Keys.flashMode)
            d.set(true, forKey: "flashOffSince39")
        }
        // Defaults for a fresh install: time only, top left, white, small files, flash off.
        d.register(defaults: [
            Keys.showDate: false,
            Keys.showTime: true,
            Keys.showLocation: false,
            Keys.stampPosition: StampPosition.topLeft.rawValue,
            Keys.stampSize: stampSize,
            Keys.stampColor: StampColor.white.rawValue,
            Keys.quality: Quality.small.rawValue,
            Keys.pageSize: PageSize.photo.rawValue,
            Keys.shareAfterDone: true,
            Keys.flashMode: FlashMode.off.rawValue,
            Keys.askNameAfterDone: true,
            Keys.use24Hour: false,
            Keys.saveToPhotos: true,
            Keys.stampNote: "",
            Keys.showCoordinates: false,
            Keys.showHeading: false,
        ])
    }
}

// MARK: - Quality (sharpness & file size)

enum Quality: String, CaseIterable, Identifiable {
    case high, medium, small
    var id: String { rawValue }

    var title: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .small: return "Small"
        }
    }

    /// Longest side of the saved photo, in pixels.
    var maxDimension: CGFloat {
        switch self {
        case .high: return 4032
        case .medium: return 2048
        case .small: return 1280
        }
    }

    /// JPEG compression quality.
    var compression: CGFloat {
        switch self {
        case .high: return 0.85
        case .medium: return 0.6
        case .small: return 0.4
        }
    }

    var hint: String {
        switch self {
        case .high: return "Sharpest photos, largest file (about 1.5–3 MB per photo)."
        case .medium: return "Good balance (about 300–600 KB per photo)."
        case .small: return "Smallest file for quick sharing (about 100–200 KB per photo)."
        }
    }
}

// MARK: - Stamp position

enum StampPosition: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }

    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }

    var alignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
}

// MARK: - Stamp color

enum StampColor: String, CaseIterable, Identifiable {
    case white, yellow, black
    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: return "White"
        case .yellow: return "Yellow"
        case .black: return "Black"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .white: return .white
        case .yellow: return UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1)
        case .black: return .black
        }
    }

    /// Soft glow around the letters so the text reads on any photo.
    var shadowColor: UIColor {
        self == .black
            ? UIColor.white.withAlphaComponent(0.9)
            : UIColor.black.withAlphaComponent(0.85)
    }

    var color: Color { Color(uiColor: uiColor) }
    var shadow: Color { Color(uiColor: shadowColor) }
}

// MARK: - PDF page size

enum PageSize: String, CaseIterable, Identifiable {
    case photo, a4
    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: return "Fit to Photo"
        case .a4: return "A4"
        }
    }
}

// MARK: - Snapshot of the stamp style

struct StampStyle {
    let position: StampPosition
    let size: CGFloat
    let color: StampColor

    static func current() -> StampStyle {
        let d = UserDefaults.standard
        return StampStyle(
            position: StampPosition(rawValue: d.string(forKey: Keys.stampPosition) ?? "") ?? .bottomRight,
            size: CGFloat(d.double(forKey: Keys.stampSize)),
            color: StampColor(rawValue: d.string(forKey: Keys.stampColor) ?? "") ?? .white
        )
    }
}
