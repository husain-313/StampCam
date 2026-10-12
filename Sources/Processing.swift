//  Processing.swift
//  Resizing, stamping and compressing photos, and building the PDF.

import UIKit

// MARK: - Options captured at the moment of the shot

struct CaptureOptions {
    let lines: [String]
    let style: StampStyle
    let quality: Quality
}

enum StampText {
    /// 24-hour date & time.
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd  HH:mm:ss"
        return f
    }()
}

// MARK: - Image processing

enum ImageProcessor {
    static func process(_ image: UIImage, options: CaptureOptions) -> (data: Data, thumbnail: UIImage) {
        let size = image.size
        let scale = min(1, options.quality.maxDimension / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(),
                            height: (size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
            if !options.lines.isEmpty {
                drawStamp(options.lines, style: options.style, canvas: target)
            }
        }

        let data = rendered.jpegData(compressionQuality: options.quality.compression) ?? Data()
        let thumbWidth: CGFloat = 300
        let thumbSize = CGSize(width: thumbWidth,
                               height: (thumbWidth * target.height / target.width).rounded())
        let thumbnail = rendered.preparingThumbnail(of: thumbSize) ?? rendered
        return (data, thumbnail)
    }

    /// Bold text only (no box), with a soft shadow so it stays readable.
    static func drawStamp(_ lines: [String], style: StampStyle, canvas: CGSize) {
        let fontSize = canvas.width * style.size

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

enum PDFBuilder {
    static let a4 = CGSize(width: 595.2, height: 841.8)

    static func build(_ pages: [Data], pageSize: PageSize) -> URL? {
        guard !pages.isEmpty else { return nil }
        let url = FileStore.newFileURL()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: a4))

        do {
            try renderer.writePDF(to: url) { ctx in
                for data in pages {
                    guard let image = UIImage(data: data) else { continue }
                    switch pageSize {
                    case .photo:
                        let rect = CGRect(origin: .zero, size: image.size)
                        ctx.beginPage(withBounds: rect, pageInfo: [:])
                        image.draw(in: rect)
                    case .a4:
                        let page = CGRect(origin: .zero, size: a4)
                        ctx.beginPage(withBounds: page, pageInfo: [:])
                        image.draw(in: fit(image.size, in: page.insetBy(dx: 20, dy: 20)))
                    }
                }
            }
            return url
        } catch {
            return nil
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
