//  Modes.swift
//  The three capture modes (Photo, Document, ID Photo), document filters,
//  ID photo processing, and one renderer that turns any saved shot into its final image.

import UIKit
import CoreImage
import Vision

// MARK: - Modes

enum ShotKind: String, Codable, CaseIterable, Identifiable {
    case photo, document, idPhoto
    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: return "PHOTO"
        case .document: return "DOCUMENT"
        case .idPhoto: return "ID PHOTO"
        }
    }
}

// MARK: - Document filters

enum DocFilter: String, Codable, CaseIterable, Identifiable {
    case original, enhanced, grayscale, blackWhite
    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .enhanced: return "Enhanced"
        case .grayscale: return "Grayscale"
        case .blackWhite: return "B&W"
        }
    }
}

// MARK: - ID photo options

enum IDBackground: String, Codable, CaseIterable, Identifiable {
    case white, lightGray, lightBlue, blue
    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: return "White"
        case .lightGray: return "Light Gray"
        case .lightBlue: return "Light Blue"
        case .blue: return "Blue"
        }
    }

    var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .white: return (1, 1, 1)
        case .lightGray: return (0.92, 0.92, 0.93)
        case .lightBlue: return (0.84, 0.91, 0.98)
        case .blue: return (0.33, 0.56, 0.86)
        }
    }

    var uiColor: UIColor {
        let c = rgb
        return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
    }
}

enum IDSize: String, Codable, CaseIterable, Identifiable {
    case passport, large, us
    var id: String { rawValue }

    var title: String {
        switch self {
        case .passport: return "35 × 45 mm"
        case .large: return "40 × 60 mm"
        case .us: return "2 × 2 in"
        }
    }

    /// Size in millimetres.
    var millimetres: CGSize {
        switch self {
        case .passport: return CGSize(width: 35, height: 45)
        case .large: return CGSize(width: 40, height: 60)
        case .us: return CGSize(width: 50.8, height: 50.8)
        }
    }

    /// Size in PDF points (exact print size).
    var points: CGSize {
        let mm = millimetres
        return CGSize(width: mm.width * 72 / 25.4, height: mm.height * 72 / 25.4)
    }

    var aspect: CGFloat { millimetres.width / millimetres.height }
}

// MARK: - Image helpers

enum ImageUtil {
    static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Redraws the image upright (applies EXIF orientation), no bigger than `maxDimension`.
    static func upright(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    static func render(_ ciImage: CIImage) -> UIImage? {
        guard let cg = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Document filters

enum DocumentFilters {
    static func apply(_ filter: DocFilter, to image: UIImage) -> UIImage {
        guard filter != .original, let cg = image.cgImage else { return image }
        var ci = CIImage(cgImage: cg)

        switch filter {
        case .original:
            return image
        case .enhanced:
            ci = colorControls(ci, saturation: 1.1, brightness: 0.03, contrast: 1.15)
            if let sharpen = CIFilter(name: "CISharpenLuminance") {
                sharpen.setValue(ci, forKey: kCIInputImageKey)
                sharpen.setValue(0.4, forKey: "inputSharpness")
                ci = sharpen.outputImage ?? ci
            }
        case .grayscale:
            ci = colorControls(ci, saturation: 0, brightness: 0.02, contrast: 1.1)
        case .blackWhite:
            ci = colorControls(ci, saturation: 0, brightness: 0.12, contrast: 2.0)
        }
        return ImageUtil.render(ci) ?? image
    }

    private static func colorControls(_ input: CIImage, saturation: Double, brightness: Double, contrast: Double) -> CIImage {
        guard let f = CIFilter(name: "CIColorControls") else { return input }
        f.setValue(input, forKey: kCIInputImageKey)
        f.setValue(saturation, forKey: kCIInputSaturationKey)
        f.setValue(brightness, forKey: kCIInputBrightnessKey)
        f.setValue(contrast, forKey: kCIInputContrastKey)
        return f.outputImage ?? input
    }
}

// MARK: - ID photo

enum IDPhotoProcessor {
    /// Replaces the background and crops to the ID size with the face centered.
    static func process(_ image: UIImage, background: IDBackground, size: IDSize, dpi: CGFloat = 600) -> UIImage {
        let upright = ImageUtil.upright(image, maxDimension: 3000)
        guard let cg = upright.cgImage else { return upright }
        let original = CIImage(cgImage: cg)
        let extent = original.extent

        // 1. Background
        var composed = original
        if let mask = personMask(cg, extent: extent) {
            let c = background.rgb
            let color = CIImage(color: CIColor(red: c.0, green: c.1, blue: c.2)).cropped(to: extent)
            if let blend = CIFilter(name: "CIBlendWithMask") {
                blend.setValue(original, forKey: kCIInputImageKey)
                blend.setValue(color, forKey: kCIInputBackgroundImageKey)
                blend.setValue(mask, forKey: kCIInputMaskImageKey)
                composed = blend.outputImage ?? original
            }
        }

        // 2. Crop around the face
        let crop = cropRect(for: cg, extent: extent, aspect: size.aspect)
        let cropped = composed.cropped(to: crop)

        // 3. Scale to the print size
        let mm = size.millimetres
        let target = CGSize(width: (mm.width / 25.4 * dpi).rounded(), height: (mm.height / 25.4 * dpi).rounded())
        let moved = cropped.transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let scaled = moved.transformed(by: CGAffineTransform(scaleX: target.width / crop.width, y: target.height / crop.height))
        return ImageUtil.render(scaled.cropped(to: CGRect(origin: .zero, size: target))) ?? upright
    }

    private static func personMask(_ cg: CGImage, extent: CGRect) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        let sx = extent.width / mask.extent.width
        let sy = extent.height / mask.extent.height
        return mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }

    /// Crop with the face about 45% of the height, centered, eyes in the upper part.
    private static func cropRect(for cg: CGImage, extent: CGRect, aspect: CGFloat) -> CGRect {
        let W = extent.width, H = extent.height
        var cropH = H
        var cropW = cropH * aspect
        if cropW > W { cropW = W; cropH = W / aspect }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([request])

        guard let face = request.results?.max(by: { $0.boundingBox.height < $1.boundingBox.height })?.boundingBox else {
            return CGRect(x: (W - cropW) / 2, y: (H - cropH) / 2, width: cropW, height: cropH)
        }

        // Face box from Vision is normalized with origin bottom-left (same as Core Image).
        let faceH = face.height * H
        cropH = min(H, faceH / 0.45)
        cropW = cropH * aspect
        if cropW > W { cropW = W; cropH = W / aspect }

        let faceCX = face.midX * W
        let faceCY = face.midY * H
        var x = faceCX - cropW / 2
        var y = faceCY + 0.42 * cropH - cropH      // face center 42% from the top
        x = min(max(0, x), W - cropW)
        y = min(max(0, y), H - cropH)
        return CGRect(x: x, y: y, width: cropW, height: cropH)
    }
}

// MARK: - One renderer for every kind of shot

enum ShotRenderer {
    /// The final image for a saved shot, using the shot's own options and the given stamp.
    static func render(_ shot: Shot, lines: [String], style: StampStyle, maxDimension: CGFloat) -> UIImage? {
        guard let original = SessionStore.image(shot.id) else { return nil }

        switch shot.shotKind {
        case .photo:
            return ImageProcessor.render(original, lines: lines, style: style, maxDimension: maxDimension)

        case .document:
            let base = ImageUtil.upright(original, maxDimension: maxDimension)
            let filtered = DocumentFilters.apply(shot.filter ?? .original, to: base)
            if lines.isEmpty { return filtered }
            return ImageProcessor.render(filtered, lines: lines, style: style, maxDimension: maxDimension)

        case .idPhoto:
            let processed = IDPhotoProcessor.process(original,
                                                     background: shot.idBackground ?? .white,
                                                     size: shot.idSize ?? .passport)
            return maxDimension < max(processed.size.width, processed.size.height)
                ? ImageUtil.upright(processed, maxDimension: maxDimension)
                : processed
        }
    }
}
