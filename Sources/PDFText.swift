//  PDFText.swift
//  The text read from a PDF's photos, kept privately inside the app (never inside the PDF),
//  page by page. It powers Smart Suggestions and "All Text from Photos", and it follows the
//  PDF when it's renamed, added to, rearranged or deleted.

import Foundation

enum PDFText {
    struct Stored: Codable {
        /// The best names (already ranked).
        var names: [String] = []
        /// Lines of text for each page, in page order. nil = not read yet: it's read the
        /// next time the Rename screen opens.
        var pages: [[String]?] = []
        /// 2 since 4.2. Saved by 4.1 (nil): an empty page there may not have been read.
        var format: Int? = 2

        var allLines: [String] {
            var seen = Set<String>()
            return pages.compactMap { $0 }.joined().filter { seen.insert(TextScanner.normalize($0)).inserted }
        }
        var isEmpty: Bool { names.isEmpty && pages.isEmpty }
        /// Pages that still need reading.
        var unread: [Int] { pages.indices.filter { pages[$0] == nil } }
    }

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("PDFText", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(for pdf: URL) -> URL {
        folder.appendingPathComponent(pdf.lastPathComponent + ".json")
    }

    static func load(for pdf: URL) -> Stored? {
        guard let data = try? Data(contentsOf: file(for: pdf)),
              var stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        if stored.format == nil {
            // 4.1 only read the first 6 photos and saved the rest as empty: read those again.
            stored.pages = stored.pages.map { $0?.isEmpty == false ? $0 : nil }
            stored.format = 2
        }
        return stored
    }

    static func save(_ stored: Stored, for pdf: URL) {
        guard !stored.isEmpty, let data = try? JSONEncoder().encode(stored) else {
            delete(for: pdf)
            return
        }
        try? data.write(to: file(for: pdf), options: .atomic)
    }

    static func delete(for pdf: URL) {
        try? FileManager.default.removeItem(at: file(for: pdf))
    }

    /// The PDF was renamed.
    static func move(from old: URL, to new: URL) {
        guard old != new else { return }
        try? FileManager.default.removeItem(at: file(for: new))
        try? FileManager.default.moveItem(at: file(for: old), to: file(for: new))
    }

    /// [extra]'s [addedPages] pages were added after the [basePages] pages of [target].
    static func append(_ extra: URL, to target: URL, basePages: Int, addedPages: Int) {
        let added = load(for: extra) ?? Stored(pages: Array(repeating: nil, count: addedPages))
        delete(for: extra)
        var stored = load(for: target) ?? Stored()
        // Pages of the old PDF with no saved text are read later, when needed.
        stored.pages = Array(stored.pages.prefix(basePages))
            + Array(repeating: nil, count: max(0, basePages - stored.pages.count))
            + added.pages
        var seen = Set(stored.names.map(TextScanner.normalize))
        stored.names += added.names.filter { seen.insert(TextScanner.normalize($0)).inserted }
        save(stored, for: target)
    }

    /// The pages were put in a new [order] (old page numbers, from 0); left-out pages were removed,
    /// and so is their text.
    static func arrange(_ pdf: URL, order: [Int]) {
        guard var stored = load(for: pdf) else { return }
        stored.pages = order.map { $0 < stored.pages.count ? stored.pages[$0] : nil }
        stored.names = keepNames(stored.names, foundIn: stored.pages)
        save(stored, for: pdf)
    }

    /// Only the names whose words still appear in the pages' text.
    static func keepNames(_ names: [String], foundIn pages: [[String]?]) -> [String] {
        let text = TextScanner.normalize(pages.compactMap { $0 }.joined().joined(separator: " "))
        return names.filter { text.contains(TextScanner.normalize($0)) }
    }

    /// Text read from photos after the PDF was saved: [lines] are pages [offset]...,
    /// and [names] join the list (no repeats). The PDF has [pageCount] pages.
    static func fill(_ pdf: URL, pageCount: Int, from offset: Int, lines: [[String]], names: [String]) {
        var stored = load(for: pdf) ?? Stored()
        let needed = max(pageCount, offset + lines.count)
        if stored.pages.count < needed {
            stored.pages += Array(repeating: nil, count: needed - stored.pages.count)
        }
        for (i, page) in lines.enumerated() { stored.pages[offset + i] = page }
        var seen = Set(stored.names.map(TextScanner.normalize))
        stored.names += names.filter { seen.insert(TextScanner.normalize($0)).inserted }
        save(stored, for: pdf)
    }

    /// Forgets the text of PDFs that are gone (deleted or renamed in the Files app).
    static func removeOrphans(keeping pdfs: [URL]) {
        let keep = Set(pdfs.map { $0.lastPathComponent + ".json" })
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
