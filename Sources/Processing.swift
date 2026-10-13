//  Processing.swift
//  Stamping and resizing photos, building the PDF, and the saved PDF files.

import UIKit
import PDFKit

// MARK: - Stamp text

enum StampText {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
    private static let twelveHour = formatter("yyyy-MM-dd  h:mm a")     // 1:05 PM
    private static let twentyFourHour = formatter("yyyy-MM-dd  HH:mm")  // 13:05

    /// Date and time for the stamp, in 12-hour (AM/PM) or 24-hour format.
    static func time(_ date: Date) -> String {
        UserDefaults.standard.bool(forKey: Keys.use24Hour)
            ? twentyFourHour.string(from: date)
            : twelveHour.string(from: date)
    }
}

// MARK: - Image processing

enum ImageProcessor {
    /// Resizes the photo and prints the stamp on it.
    static func render(_ image: UIImage, lines: [String], style: StampStyle, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(),
                            height: (size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
            if !lines.isEmpty {
                drawStamp(lines, style: style, canvas: target)
            }
        }
    }

    /// Bold text only (no box), with a soft shadow so it stays readable.
    static func drawStamp(_ lines: [String], style: StampStyle, canvas: CGSize) {
        // Based on the short side, so text is the same size in portrait and landscape.
        let fontSize = min(canvas.width, canvas.height) * style.size

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.position.isLeft ? .left : .right
        paragraph.lineSpacing = fontSize * 0.15

        let shadow = NSShadow()
        shadow.shadowColor = style.color.shadowColor
        shadow.shadowBlurRadius = fontSize * 0.2
        shadow.shadowOffset = .zero

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: style.color.uiColor,
            .paragraphStyle: paragraph,
            .shadow: shadow
        ]
        let text = NSAttributedString(string: lines.joined(separator: "\n"), attributes: attributes)

        let margin = fontSize * 0.9
        let width = canvas.width - margin * 2
        let drawOptions: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let height = ceil(text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                            options: drawOptions, context: nil).height)
        let y = style.position.isTop ? margin : canvas.height - height - margin
        let rect = CGRect(x: margin, y: y, width: width, height: height)

        // Two passes make the shadow strong enough on bright photos.
        text.draw(with: rect, options: drawOptions, context: nil)
        text.draw(with: rect, options: drawOptions, context: nil)
    }
}

// MARK: - PDF

struct PDFPageSource {
    let shot: Shot
    let lines: [String]
}

enum PDFBuilder {
    static let a4 = CGSize(width: 595.2, height: 841.8)

    /// Builds the PDF from the saved photos. The stamp, filters, quality and page size
    /// are applied here, so the latest settings always count.
    static func build(_ pages: [PDFPageSource],
                      style: StampStyle,
                      quality: Quality,
                      pageSize: PageSize,
                      onPage: ((Shot, Data) -> Void)? = nil,
                      progress: @escaping (Int) -> Void) -> URL? {
        guard !pages.isEmpty else { return nil }
        let url = FileStore.newFileURL()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: a4))
        var written = 0

        do {
            try renderer.writePDF(to: url) { ctx in
                for (index, page) in pages.enumerated() {
                    autoreleasepool {
                        guard let rendered = ShotRenderer.render(page.shot, lines: page.lines,
                                                                 style: style, maxDimension: quality.maxDimension) else { return }
                        // Re-open as JPEG so the PDF stores compressed photos (small file).
                        let compression = page.shot.shotKind == .idPhoto ? max(quality.compression, 0.85) : quality.compression
                        guard let data = rendered.jpegData(compressionQuality: compression),
                              let image = UIImage(data: data) else { return }
                        onPage?(page.shot, data)      // e.g. also save to Photos

                        if page.shot.shotKind == .idPhoto {
                            drawIDPhoto(image, size: page.shot.idSize ?? .passport, pageSize: pageSize, ctx: ctx)
                        } else {
                            drawPage(image, pageSize: pageSize, ctx: ctx)
                        }
                        written += 1
                    }
                    progress(index + 1)
                }
            }
        } catch {
            return nil
        }

        guard written > 0 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    private static func drawPage(_ image: UIImage, pageSize: PageSize, ctx: UIGraphicsPDFRendererContext) {
        let landscape = image.size.width > image.size.height
        switch pageSize {
        case .photo:
            // Page shaped like the photo, with the long side as long as A4.
            let ratio = a4.height / max(image.size.width, image.size.height)
            let rect = CGRect(x: 0, y: 0,
                              width: (image.size.width * ratio).rounded(),
                              height: (image.size.height * ratio).rounded())
            ctx.beginPage(withBounds: rect, pageInfo: [:])
            image.draw(in: rect)
        case .a4:
            // Landscape photos get a landscape A4 page.
            let a4Size = landscape ? CGSize(width: a4.height, height: a4.width) : a4
            let page = CGRect(origin: .zero, size: a4Size)
            ctx.beginPage(withBounds: page, pageInfo: [:])
            image.draw(in: fit(image.size, in: page.insetBy(dx: 20, dy: 20)))
        }
    }

    /// ID photos print at their real size: one per page, or as many copies as fit on A4.
    private static func drawIDPhoto(_ image: UIImage, size: IDSize, pageSize: PageSize, ctx: UIGraphicsPDFRendererContext) {
        let photo = size.points
        switch pageSize {
        case .photo:
            let rect = CGRect(origin: .zero, size: photo)
            ctx.beginPage(withBounds: rect, pageInfo: [:])
            image.draw(in: rect)
        case .a4:
            let page = CGRect(origin: .zero, size: a4)
            ctx.beginPage(withBounds: page, pageInfo: [:])
            let margin: CGFloat = 28, gap: CGFloat = 10
            let columns = max(1, Int((a4.width - 2 * margin + gap) / (photo.width + gap)))
            let rows = max(1, Int((a4.height - 2 * margin + gap) / (photo.height + gap)))
            let cg = ctx.cgContext
            cg.setStrokeColor(UIColor(white: 0.75, alpha: 1).cgColor)
            cg.setLineWidth(0.4)
            for row in 0..<rows {
                for column in 0..<columns {
                    let rect = CGRect(x: margin + CGFloat(column) * (photo.width + gap),
                                      y: margin + CGFloat(row) * (photo.height + gap),
                                      width: photo.width, height: photo.height)
                    image.draw(in: rect)
                    cg.stroke(rect)      // thin cut line
                }
            }
        }
    }

    private static func fit(_ size: CGSize, in rect: CGRect) -> CGRect {
        let s = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * s
        let h = size.height * s
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}

// MARK: - Saved PDF files

struct PDFFile: Identifiable, Hashable {
    let url: URL
    let date: Date
    let size: Int64
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum FileStore {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func newFileURL() -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = "StampCam_\(f.string(from: Date()))"
        var url = folder.appendingPathComponent("\(base).pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)_\(n).pdf")
            n += 1
        }
        return url
    }

    static func list() -> [PDFFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                 includingPropertiesForKeys: keys)) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return PDFFile(url: url,
                               date: values?.contentModificationDate ?? .distantPast,
                               size: Int64(values?.fileSize ?? 0))
            }
            .sorted { $0.date > $1.date }
    }

    /// Adds the pages of `newPDF` to the end of `target`, then removes `newPDF`.
    static func append(_ newPDF: URL, to target: URL) -> Bool {
        guard let base = PDFDocument(url: target), let extra = PDFDocument(url: newPDF) else { return false }
        for i in 0..<extra.pageCount {
            guard let page = extra.page(at: i)?.copy() as? PDFPage else { continue }
            base.insert(page, at: base.pageCount)
        }
        let temp = folder.appendingPathComponent(".merge-\(UUID().uuidString).pdf")
        guard base.write(to: temp) else { return false }
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            try? FileManager.default.removeItem(at: newPDF)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
    }

    static func delete(_ file: PDFFile) {
        try? FileManager.default.removeItem(at: file.url)
    }

    /// Removes characters that can't be in a file name.
    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = name
            .components(separatedBy: bad)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return String(cleaned.prefix(80))
    }

    /// Renames a PDF. Returns the new URL, or nil if the name is empty or the move fails.
    static func rename(_ url: URL, to rawName: String) -> URL? {
        let name = sanitize(rawName)
        guard !name.isEmpty else { return nil }
        if name == url.deletingPathExtension().lastPathComponent { return url }

        var target = folder.appendingPathComponent(name).appendingPathExtension("pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(name) \(n)").appendingPathExtension("pdf")
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }
}
