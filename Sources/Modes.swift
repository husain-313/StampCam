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
    case magic, original, enhanced, grayscale, blackWhite
    var id: String { rawValue }

    var title: String {
        switch self {
        case .magic: return "Magic"
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
        case .magic:
            ci = magic(ci)
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
            // Even out shadows first, so the page turns white and the ink black.
            ci = colorControls(flattenLighting(ci), saturation: 0, brightness: 0.02, contrast: 1.9)
        }
        return ImageUtil.render(ci) ?? image
    }

    /// Like a scanner app's "magic color": removes shadows, makes the paper white, keeps ink and colors crisp.
    private static func magic(_ input: CIImage) -> CIImage {
        var out = flattenLighting(input)
        out = colorControls(out, saturation: 1.15, brightness: 0, contrast: 1.12)
        if let sharpen = CIFilter(name: "CISharpenLuminance") {
            sharpen.setValue(out, forKey: kCIInputImageKey)
            sharpen.setValue(0.5, forKey: "inputSharpness")
            out = sharpen.outputImage ?? out
        }
        return out
    }

    /// Divides the photo by its own "paper brightness", so shadows and uneven light disappear.
    private static func flattenLighting(_ input: CIImage) -> CIImage {
        let extent = input.extent
        let longSide = max(extent.width, extent.height)

        // Estimate the paper: wipe out the text (max filter), then blur it smooth.
        var paper = input.clampedToExtent()
        if let maxFilter = CIFilter(name: "CIMorphologyMaximum") {
            maxFilter.setValue(paper, forKey: kCIInputImageKey)
            maxFilter.setValue(max(4, longSide * 0.012), forKey: kCIInputRadiusKey)
            paper = maxFilter.outputImage ?? paper
        }
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(paper, forKey: kCIInputImageKey)
            blur.setValue(max(8, longSide * 0.025), forKey: kCIInputRadiusKey)
            paper = blur.outputImage ?? paper
        }
        paper = paper.cropped(to: extent)

        guard let kernel = divideKernel else { return input }
        return kernel.apply(extent: extent, arguments: [input, paper]) ?? input
    }

    /// pixel / paper, clamped: paper becomes white, ink keeps its contrast.
    private static let divideKernel: CIColorKernel? = CIColorKernel(source: """
        kernel vec4 stampcamDivide(__sample s, __sample p) {
            vec3 paper = max(p.rgb, vec3(0.08));
            vec3 r = clamp(s.rgb / paper, 0.0, 1.0);
            r = pow(r, vec3(1.25));
            return vec4(r, s.a);
        }
        """)

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
    /// The person cut out from the background, kept in memory so changing color or size is instant.
    private final class Cutout {
        let subject: CIImage      // original photo, upright
        let mask: CIImage         // 1 = person, 0 = background (soft edges)
        let face: CGRect?         // normalized, origin bottom-left
        init(subject: CIImage, mask: CIImage, face: CGRect?) {
            self.subject = subject; self.mask = mask; self.face = face
        }
    }
    private static let cache: NSCache<NSString, Cutout> = {
        let c = NSCache<NSString, Cutout>()
        c.countLimit = 6
        return c
    }()

    /// Replaces the background and crops to the ID size with the face centered. Fully automatic.
    static func process(_ image: UIImage, id: UUID? = nil, background: IDBackground, size: IDSize, dpi: CGFloat = 600) -> UIImage {
        guard let cutout = cutout(for: image, id: id) else { return image }
        let extent = cutout.subject.extent

        // 1. New background
        let c = background.rgb
        let color = CIImage(color: CIColor(red: c.0, green: c.1, blue: c.2)).cropped(to: extent)
        var composed = cutout.subject
        if let blend = CIFilter(name: "CIBlendWithMask") {
            blend.setValue(cutout.subject, forKey: kCIInputImageKey)
            blend.setValue(color, forKey: kCIInputBackgroundImageKey)
            blend.setValue(cutout.mask, forKey: kCIInputMaskImageKey)
            composed = blend.outputImage ?? cutout.subject
        }

        // 2. Crop around the face
        let crop = cropRect(extent: extent, face: cutout.face, aspect: size.aspect)
        let cropped = composed.cropped(to: crop)

        // 3. Scale to the print size
        let mm = size.millimetres
        let target = CGSize(width: (mm.width / 25.4 * dpi).rounded(), height: (mm.height / 25.4 * dpi).rounded())
        let moved = cropped.transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let scaled = moved.transformed(by: CGAffineTransform(scaleX: target.width / crop.width, y: target.height / crop.height))
        return ImageUtil.render(scaled.cropped(to: CGRect(origin: .zero, size: target))) ?? image
    }

    private static func cutout(for image: UIImage, id: UUID?) -> Cutout? {
        if let id, let cached = cache.object(forKey: id.uuidString as NSString) { return cached }
        let upright = ImageUtil.upright(image, maxDimension: 3000)
        guard let cg = upright.cgImage else { return nil }
        let subject = CIImage(cgImage: cg)
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])

        let faceRequest = VNDetectFaceRectanglesRequest()
        try? handler.perform([faceRequest])
        let face = faceRequest.results?.max(by: { $0.boundingBox.height < $1.boundingBox.height })?.boundingBox

        // Apple's newest cut-out (the same one as "lift subject" in Photos): sharp edges, good with hair.
        // Falls back to the older person mask if it finds nothing.
        guard let mask = subjectMask(handler: handler, face: face, extent: subject.extent)
                ?? personMask(handler: handler, extent: subject.extent) else { return nil }

        let result = Cutout(subject: subject, mask: mask, face: face)
        if let id { cache.setObject(result, forKey: id.uuidString as NSString) }
        return result
    }

    private static func subjectMask(handler: VNImageRequestHandler, face: CGRect?, extent: CGRect) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }

        // Keep only the subject under the face (so a chair or bag behind isn't kept too).
        var instances = observation.allInstances
        if let face {
            let labels = observation.instanceMask
            CVPixelBufferLockBaseAddress(labels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
            let w = CVPixelBufferGetWidth(labels), h = CVPixelBufferGetHeight(labels)
            if let base = CVPixelBufferGetBaseAddress(labels) {
                let row = CVPixelBufferGetBytesPerRow(labels)
                let px = min(w - 1, max(0, Int(face.midX * CGFloat(w))))
                let py = min(h - 1, max(0, Int((1 - face.midY) * CGFloat(h))))   // buffer rows go top-down
                let label = Int(base.load(fromByteOffset: py * row + px, as: UInt8.self))
                if label > 0 && observation.allInstances.contains(label) {
                    instances = IndexSet(integer: label)
                }
            }
        }

        guard let buffer = try? observation.generateScaledMaskForImage(forInstances: instances, from: handler) else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        let sx = extent.width / mask.extent.width
        let sy = extent.height / mask.extent.height
        return mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }

    private static func personMask(handler: VNImageRequestHandler, extent: CGRect) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do { try handler.perform([request]) } catch { return nil }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        let sx = extent.width / mask.extent.width
        let sy = extent.height / mask.extent.height
        return mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }

    /// Crop with the face about 45% of the height, centered, eyes in the upper part.
    private static func cropRect(extent: CGRect, face: CGRect?, aspect: CGFloat) -> CGRect {
        let W = extent.width, H = extent.height
        var cropH = H
        var cropW = cropH * aspect
        if cropW > W { cropW = W; cropH = W / aspect }

        guard let face else {
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
            let processed = IDPhotoProcessor.process(original, id: shot.id,
                                                     background: shot.idBackground ?? .white,
                                                     size: shot.idSize ?? .passport)
            return maxDimension < max(processed.size.width, processed.size.height)
                ? ImageUtil.upright(processed, maxDimension: maxDimension)
                : processed
        }
    }
}
