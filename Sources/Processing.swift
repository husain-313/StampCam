//  Processing.swift
//  Stamping and resizing photos, building the PDF, and the saved PDF files.

import UIKit
import PDFKit
import CoreLocation

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

    private static let dayOnly = formatter("d MMM yyyy")                // 13 Oct 2026
    private static let clock12 = formatter("h:mm a")
    private static let clock24 = formatter("HH:mm")

    /// Date and time for the stamp, in 12-hour (AM/PM) or 24-hour format.
    static func time(_ date: Date) -> String {
        UserDefaults.standard.bool(forKey: Keys.use24Hour)
            ? twentyFourHour.string(from: date)
            : twelveHour.string(from: date)
    }

    /// "26.12345° N  50.55512° E"
    static func coordinates(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.5f° %@  %.5f° %@",
               abs(c.latitude), c.latitude >= 0 ? "N" : "S",
               abs(c.longitude), c.longitude >= 0 ? "E" : "W")
    }

    /// "SW 225°"
    static func heading(_ degrees: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let value = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let index = Int((value + 22.5) / 45) % 8
        return "\(names[index]) \(Int(value.rounded()) % 360)°"
    }

    /// The note line from Settings (empty when not set).
    static var note: String {
        (UserDefaults.standard.string(forKey: Keys.stampNote) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when at least one stamp line is turned on.
    static var isOn: Bool {
        let d = UserDefaults.standard
        return d.bool(forKey: Keys.showTime) || d.bool(forKey: Keys.showLocation)
            || d.bool(forKey: Keys.showCoordinates) || d.bool(forKey: Keys.showHeading)
            || !note.isEmpty
    }

    /// All stamp lines, top to bottom, using the current settings.
    /// Used for the photos, the live camera preview and the Settings preview, so they always match.
    static func lines(date: Date?, place: String?,
                      coordinate: CLLocationCoordinate2D?, heading: Double?) -> [String] {
        let d = UserDefaults.standard
        var lines: [String] = []
        let noteText = StampText.note
        if !noteText.isEmpty { lines.append(noteText) }
        if d.bool(forKey: Keys.showTime), let date { lines.append(time(date)) }
        if d.bool(forKey: Keys.showLocation), let place, !place.isEmpty { lines.append(place) }
        var extra: [String] = []
        if d.bool(forKey: Keys.showCoordinates), let coordinate { extra.append(coordinates(coordinate)) }
        if d.bool(forKey: Keys.showHeading), let heading { extra.append(StampText.heading(heading)) }
        if !extra.isEmpty { lines.append(extra.joined(separator: "  ·  ")) }
        return lines
    }

    /// "13 Oct 2026 · 2:05 PM – 3:40 PM", or "13 Oct 2026 – 15 Oct 2026" across days.
    static func dateRange(_ dates: [Date]) -> String {
        guard let first = dates.min(), let last = dates.max() else { return "" }
        let clock = UserDefaults.standard.bool(forKey: Keys.use24Hour) ? clock24 : clock12
        if !Calendar.current.isDate(first, inSameDayAs: last) {
            return "\(dayOnly.string(from: first)) – \(dayOnly.string(from: last))"
        }
        let day = dayOnly.string(from: first)
        let start = clock.string(from: first), end = clock.string(from: last)
        return start == end ? "\(day) · \(start)" : "\(day) · \(start) – \(end)"
    }
}

// MARK: - Final look of a saved photo

enum ShotRenderer {
    /// The final image for a saved photo, with the given stamp.
    static func render(_ shot: Shot, lines: [String], style: StampStyle, maxDimension: CGFloat) -> UIImage? {
        guard let original = SessionStore.image(shot.id) else { return nil }
        return ImageProcessor.render(original, lines: lines, style: style, maxDimension: maxDimension)
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

/// The first page of the PDF: a short summary of the set.
struct PDFCover {
    let title: String
    let dateText: String
    let places: [String]
    let photoCount: Int
    let thumbnailIDs: [UUID]
}

struct PDFOptions {
    var cover: PDFCover? = nil
    var pageNumbers = false
    /// Number of the first photo page (higher when adding to an existing PDF).
    var firstNumber = 1
    var totalNumber = 0
}

enum PDFBuilder {
    static let a4 = CGSize(width: 595.2, height: 841.8)
    /// Printed in the cover page footer; also how the cover is recognized later.
    static let coverMark = "Made with StampCam"
    private static let accent = UIColor(red: 1.0, green: 0.80, blue: 0.0, alpha: 1)

    /// Builds the PDF from the saved photos. The stamp, quality and page size
    /// are applied here, so the latest settings always count.
    static func build(_ pages: [PDFPageSource],
                      style: StampStyle,
                      quality: Quality,
                      pageSize: PageSize,
                      options: PDFOptions = PDFOptions(),
                      onPage: ((Shot, Data) -> Void)? = nil,
                      progress: @escaping (Int) -> Void) -> URL? {
        guard !pages.isEmpty else { return nil }
        let url = FileStore.newFileURL()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: a4))
        var written = 0

        do {
            try renderer.writePDF(to: url) { ctx in
                if let cover = options.cover {
                    autoreleasepool { drawCover(cover, ctx: ctx) }
                }
                for (index, page) in pages.enumerated() {
                    autoreleasepool {
                        guard let rendered = ShotRenderer.render(page.shot, lines: page.lines,
                                                                 style: style, maxDimension: quality.maxDimension) else { return }
                        // Re-open as JPEG so the PDF stores compressed photos (small file).
                        guard let data = rendered.jpegData(compressionQuality: quality.compression),
                              let image = UIImage(data: data) else { return }
                        onPage?(page.shot, data)      // e.g. also save to Photos

                        let number: String? = options.pageNumbers
                            ? "\(options.firstNumber + index) / \(max(options.totalNumber, options.firstNumber + index))"
                            : nil
                        let caption: String? = (page.shot.note?.isEmpty == false) ? page.shot.note : nil
                        drawPage(image, caption: caption, number: number, pageSize: pageSize, ctx: ctx)
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

    // MARK: Photo pages

    private static let captionFont = UIFont.systemFont(ofSize: 12, weight: .regular)

    private static func captionText(_ caption: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.baseWritingDirection = .natural
        return NSAttributedString(string: caption, attributes: [
            .font: captionFont,
            .foregroundColor: UIColor(white: 0.15, alpha: 1),
            .paragraphStyle: paragraph
        ])
    }

    private static func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
    }

    private static func drawPage(_ image: UIImage, caption: String?, number: String?,
                                 pageSize: PageSize, ctx: UIGraphicsPDFRendererContext) {
        let landscape = image.size.width > image.size.height
        switch pageSize {
        case .photo:
            // Page shaped like the photo, with the long side as long as A4.
            // A note adds a white strip under the photo.
            let ratio = a4.height / max(image.size.width, image.size.height)
            let photoRect = CGRect(x: 0, y: 0,
                                   width: (image.size.width * ratio).rounded(),
                                   height: (image.size.height * ratio).rounded())
            var pageRect = photoRect
            var text: NSAttributedString?
            var textHeightValue: CGFloat = 0
            if let caption {
                let t = captionText(caption)
                textHeightValue = textHeight(t, width: photoRect.width - 40)
                pageRect.size.height += textHeightValue + 28
                text = t
            }
            ctx.beginPage(withBounds: pageRect, pageInfo: [:])
            UIColor.white.setFill()
            UIRectFill(pageRect)
            image.draw(in: photoRect)
            if let text {
                text.draw(with: CGRect(x: 20, y: photoRect.maxY + 14, width: photoRect.width - 40, height: textHeightValue),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
            if let number {
                drawNumberPill(number, centerX: photoRect.midX, bottom: photoRect.maxY - 12)
            }
        case .a4:
            // Landscape photos get a landscape A4 page.
            let a4Size = landscape ? CGSize(width: a4.height, height: a4.width) : a4
            let page = CGRect(origin: .zero, size: a4Size)
            ctx.beginPage(withBounds: page, pageInfo: [:])
            var area = page.insetBy(dx: 24, dy: 24)
            area.size.height -= number == nil ? 0 : 14          // room for the page number
            if let caption {
                let text = captionText(caption)
                let h = textHeight(text, width: area.width - 20)
                area.size.height -= h + 14
                let photo = fit(image.size, in: area)
                image.draw(in: photo)
                text.draw(with: CGRect(x: area.minX + 10, y: photo.maxY + 12, width: area.width - 20, height: h),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            } else {
                image.draw(in: fit(image.size, in: area))
            }
            if let number {
                let text = NSAttributedString(string: number, attributes: [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                    .foregroundColor: UIColor(white: 0.45, alpha: 1)
                ])
                let size = text.size()
                text.draw(at: CGPoint(x: page.midX - size.width / 2, y: page.maxY - 22))
            }
        }
    }

    /// Small dark pill with the page number, on top of the photo.
    private static func drawNumberPill(_ number: String, centerX: CGFloat, bottom: CGFloat) {
        let text = NSAttributedString(string: number, attributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: UIColor.white
        ])
        let size = text.size()
        let pill = CGRect(x: centerX - size.width / 2 - 8, y: bottom - size.height - 6,
                          width: size.width + 16, height: size.height + 6)
        UIColor.black.withAlphaComponent(0.45).setFill()
        UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).fill()
        text.draw(at: CGPoint(x: pill.minX + 8, y: pill.minY + 3))
    }

    // MARK: Cover page

    private static func drawCover(_ cover: PDFCover, ctx: UIGraphicsPDFRendererContext) {
        let page = CGRect(origin: .zero, size: a4)
        ctx.beginPage(withBounds: page, pageInfo: [:])
        UIColor.white.setFill()
        UIRectFill(page)

        let margin: CGFloat = 48
        let width = page.width - margin * 2
        var y: CGFloat = 60

        accent.setFill()
        UIBezierPath(roundedRect: CGRect(x: margin, y: y, width: 44, height: 6), cornerRadius: 3).fill()
        y += 24

        y = draw("PHOTO REPORT", font: .systemFont(ofSize: 10, weight: .bold),
                 color: UIColor(white: 0.5, alpha: 1), kern: 2, x: margin, y: y, width: width)
        y += 6
        y = draw(cover.title, font: .systemFont(ofSize: 30, weight: .heavy),
                 color: UIColor(white: 0.08, alpha: 1), x: margin, y: y, width: width)
        y += 28

        // Summary rows
        var rows: [(String, String)] = []
        if !cover.dateText.isEmpty { rows.append(("DATE", cover.dateText)) }
        if !cover.places.isEmpty { rows.append(("LOCATION", cover.places.joined(separator: "\n"))) }
        rows.append(("PHOTOS", cover.photoCount == 1 ? "1 photo" : "\(cover.photoCount) photos"))

        for (label, value) in rows {
            UIColor(white: 0.9, alpha: 1).setFill()
            UIRectFill(CGRect(x: margin, y: y, width: width, height: 0.7))
            y += 12
            let labelBottom = draw(label, font: .systemFont(ofSize: 9, weight: .bold),
                                   color: UIColor(white: 0.55, alpha: 1), kern: 1.5, x: margin, y: y + 2, width: 100)
            let valueBottom = draw(value, font: .systemFont(ofSize: 14, weight: .medium),
                                   color: UIColor(white: 0.1, alpha: 1), x: margin + 110, y: y, width: width - 110)
            y = max(labelBottom, valueBottom) + 12
        }
        UIColor(white: 0.9, alpha: 1).setFill()
        UIRectFill(CGRect(x: margin, y: y, width: width, height: 0.7))
        y += 28

        // Photo overview
        let footerTop = page.height - 60
        let columns = 4
        let gap: CGFloat = 10
        let cell = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = cell * 4 / 3
        let maxRows = max(0, Int((footerTop - 24 - y + gap) / (cellHeight + gap)))
        let shown = Array(cover.thumbnailIDs.prefix(maxRows * columns))
        if let cg = UIGraphicsGetCurrentContext() {
            for (i, id) in shown.enumerated() {
                let rect = CGRect(x: margin + CGFloat(i % columns) * (cell + gap),
                                  y: y + CGFloat(i / columns) * (cellHeight + gap),
                                  width: cell, height: cellHeight)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 8)
                UIColor(white: 0.94, alpha: 1).setFill()
                path.fill()
                guard let thumb = SessionStore.thumbnail(id, maxPixel: 400) else { continue }
                cg.saveGState()
                path.addClip()
                thumb.draw(in: fill(thumb.size, in: rect))
                cg.restoreGState()
            }
        }
        let hidden = cover.thumbnailIDs.count - shown.count
        if hidden > 0 && !shown.isEmpty {
            let usedRows = (shown.count + columns - 1) / columns
            _ = draw("+ \(hidden) more", font: .systemFont(ofSize: 11, weight: .semibold),
                     color: UIColor(white: 0.45, alpha: 1),
                     x: margin, y: y + CGFloat(usedRows) * (cellHeight + gap), width: width)
        }

        // Footer
        UIColor(white: 0.9, alpha: 1).setFill()
        UIRectFill(CGRect(x: margin, y: footerTop, width: width, height: 0.7))
        _ = draw("\(coverMark) · \(StampText.time(Date()))",
                 font: .systemFont(ofSize: 9, weight: .medium),
                 color: UIColor(white: 0.55, alpha: 1), x: margin, y: footerTop + 12, width: width)
    }

    /// Draws text and returns the y just below it.
    @discardableResult
    private static func draw(_ string: String, font: UIFont, color: UIColor, kern: CGFloat = 0,
                             x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = font.pointSize * 0.2
        paragraph.baseWritingDirection = .natural
        let text = NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .kern: kern, .paragraphStyle: paragraph
        ])
        let height = textHeight(text, width: width)
        text.draw(with: CGRect(x: x, y: y, width: width, height: height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return y + height
    }

    private static func fit(_ size: CGSize, in rect: CGRect) -> CGRect {
        let s = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * s
        let h = size.height * s
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    private static func fill(_ size: CGSize, in rect: CGRect) -> CGRect {
        let s = max(rect.width / size.width, rect.height / size.height)
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
