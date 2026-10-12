//  PhotoInfo.swift
//  Reads the date and location saved inside a photo (EXIF / GPS).

import Foundation
import ImageIO
import CoreLocation

struct PhotoInfo {
    var date: Date?
    var coordinate: CLLocationCoordinate2D?

    static func read(_ data: Data) -> PhotoInfo {
        var info = PhotoInfo()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return info }

        // Date taken
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        if let text = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            info.date = f.date(from: text)
        }

        // Location
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           var lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           var lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = -lat }
            if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lon = -lon }
            info.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return info
    }
}
