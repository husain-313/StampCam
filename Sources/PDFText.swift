//  PDFText.swift
//  The text read from a PDF's photos, kept privately inside the app (never inside the PDF),
//  page by page. It powers Smart Suggestions and "All Text from Photos", and it follows the
//  PDF when it's renamed, added to, rearranged or deleted.

import Foundation

enum PDFText {
    struct Stored: Codable {
        /// The best names (already ranked).
        var names: [String] = []
        /// Lines of text for each page, in page order ([] for a page that wasn't read).
        var pages: [[String]] = []

        var allLines: [String] {
            var seen = Set<String>()
            return pages.joined().filter { seen.insert(TextScanner.normalize($0)).inserted }
        }
        var isEmpty: Bool { names.isEmpty && pages.allSatisfy(\.isEmpty) }
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
        guard let data = try? Data(contentsOf: file(for: pdf)) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
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

    /// [extra]'s pages were added after the [basePages] pages of [target].
    static func append(_ extra: URL, to target: URL, basePages: Int) {
        let added = load(for: extra)
        delete(for: extra)
        guard let added else { return }
        var stored = load(for: target) ?? Stored()
        stored.pages = Array(stored.pages.prefix(basePages))
            + Array(repeating: [], count: max(0, basePages - stored.pages.count))
            + added.pages
        var seen = Set(stored.names.map(TextScanner.normalize))
        stored.names += added.names.filter { seen.insert(TextScanner.normalize($0)).inserted }
        save(stored, for: target)
    }

    /// The pages were put in a new [order] (old page numbers, from 0); left-out pages were removed,
    /// and so is their text.
    static func arrange(_ pdf: URL, order: [Int]) {
        guard var stored = load(for: pdf) else { return }
        stored.pages = order.map { $0 < stored.pages.count ? stored.pages[$0] : [] }
        stored.names = keepNames(stored.names, foundIn: stored.pages)
        save(stored, for: pdf)
    }

    /// Only the names whose words still appear in the pages' text.
    static func keepNames(_ names: [String], foundIn pages: [[String]]) -> [String] {
        let text = TextScanner.normalize(pages.joined().joined(separator: " "))
        return names.filter { text.contains(TextScanner.normalize($0)) }
    }
}
