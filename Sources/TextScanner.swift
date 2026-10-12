//  TextScanner.swift
//  Reads the text in a PDF's photos (on-device, Apple Vision) and suggests file names.
//  Big, centered text (usually the sign) comes first, and two-line signs are joined.

import UIKit
import Vision
import PDFKit

enum TextScanner {
    static func suggestions(for url: URL, maxPages: Int = 3) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            TextScanner.scan(url, maxPages: maxPages)
        }.value
    }

    private struct Found {
        let text: String
        let box: CGRect         // normalized, origin bottom-left (Vision)
        let confidence: Float
        let page: Int
        var merged = false
    }

    // MARK: Reading

    private static func scan(_ url: URL, maxPages: Int) -> [String] {
        guard let document = PDFDocument(url: url) else { return [] }
        var found: [Found] = []
        for index in 0..<min(document.pageCount, maxPages) {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale = 1800 / max(bounds.width, bounds.height)
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            guard let image = page.thumbnail(of: size, for: .mediaBox).cgImage else { continue }
            found += recognize(image, page: index)
        }
        return rank(found)
    }

    private static func recognize(_ image: CGImage, page: Int) -> [Found] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        // Arabic first, then English (only the ones this iPhone supports).
        let wanted = ["ar-SA", "ars-SA", "en-US"]
        if let supported = try? request.supportedRecognitionLanguages() {
            let languages = wanted.filter { supported.contains($0) }
            if !languages.isEmpty { request.recognitionLanguages = languages }
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return Found(text: clean(candidate.string),
                         box: observation.boundingBox,
                         confidence: candidate.confidence,
                         page: page)
        }
    }

    // MARK: Ranking

    private static func rank(_ found: [Found]) -> [String] {
        let usable = found.filter(isUsable)

        // Join lines that belong together, like a sign written on two lines.
        var candidates = usable
        for page in Set(usable.map(\.page)) {
            let lines = usable.filter { $0.page == page }.sorted { $0.box.midY > $1.box.midY } // top to bottom
            for (upper, lower) in zip(lines, lines.dropFirst()) where belongTogether(upper, lower) {
                candidates.append(Found(text: "\(upper.text) \(lower.text)",
                                        box: upper.box.union(lower.box),
                                        confidence: min(upper.confidence, lower.confidence),
                                        page: page,
                                        merged: true))
            }
        }

        let sorted = candidates.sorted { score($0) > score($1) }

        var result: [String] = []
        var seen = Set<String>()
        for item in sorted {
            let key = normalize(item.text)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(String(item.text.prefix(60)))
            if result.count == 6 { break }
        }
        return result
    }

    /// Bigger text, nearer the middle of the photo, read with more confidence = better.
    private static func score(_ item: Found) -> CGFloat {
        let lineHeight = item.merged ? item.box.height / 2 : item.box.height
        let dx = item.box.midX - 0.5
        let dy = item.box.midY - 0.5
        let distance = min(1, (dx * dx + dy * dy).squareRoot() / 0.7071)
        let centerWeight = 1 - 0.4 * distance
        let confidenceWeight = CGFloat(0.5 + item.confidence / 2)
        let mergeBonus: CGFloat = item.merged ? 1.08 : 1
        return lineHeight * centerWeight * confidenceWeight * mergeBonus
    }

    private static func belongTogether(_ upper: Found, _ lower: Found) -> Bool {
        let h1 = upper.box.height, h2 = lower.box.height
        guard min(h1, h2) / max(h1, h2) >= 0.65 else { return false }                  // similar size
        let gap = upper.box.minY - lower.box.maxY
        guard gap > -0.3 * h1, gap < 1.0 * max(h1, h2) else { return false }           // right under each other
        let overlap = min(upper.box.maxX, lower.box.maxX) - max(upper.box.minX, lower.box.minX)
        guard overlap > 0.3 * min(upper.box.width, lower.box.width) else { return false } // lined up
        return isArabic(upper.text) == isArabic(lower.text)                             // same language
    }

    private static func isUsable(_ item: Found) -> Bool {
        let text = item.text
        guard text.count >= 2, item.confidence >= 0.3 else { return false }

        let scalars = text.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        guard !scalars.isEmpty, Double(letters) / Double(scalars.count) >= 0.5 else { return false }

        // Skip our own stamp: the date/time and area names printed on the photos.
        if text.range(of: #"\d{1,4}[-/:.]\d{1,2}[-/:.]\d{1,4}"#, options: .regularExpression) != nil { return false }
        let stamped = UserDefaults.standard.stringArray(forKey: Keys.stampedPlaces) ?? []
        let key = normalize(text)
        return !stamped.contains { normalize($0) == key }
    }

    // MARK: Helpers

    private static func clean(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func isArabic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) || (0x0750...0x077F).contains($0.value) }
    }

    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return String(kept)
    }
}
