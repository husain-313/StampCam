//  TextScanner.swift
//  Reads the text in a PDF's photos (on-device, Apple Vision) and suggests file names.
//  Big, centered text (usually the sign) comes first, and two-line signs are joined.

import UIKit
import Vision
import PDFKit

enum TextScanner {
    /// One line of text found in a photo, for tapping in the rename screen.
    struct Line: Identifiable {
        let id = UUID()
        let text: String
        /// Normalized (0...1), origin top-left, like the screen.
        let box: CGRect
    }

    /// One PDF page with its picture and the text lines found on it.
    struct Page: Identifiable {
        let id: Int            // page index in the PDF
        let image: UIImage
        let lines: [Line]
        /// Raw results, used for the name suggestions.
        let found: [Found]
    }

    struct Found {
        let text: String
        let box: CGRect         // normalized, origin bottom-left (Vision)
        let confidence: Float
        let page: Int
        var merged = false
    }

    /// Number of pages in the PDF (0 if it can't be opened).
    static func pageCount(_ url: URL) -> Int {
        PDFDocument(url: url)?.pageCount ?? 0
    }

    /// Reads the text on one page. Nil for pages without a photo (like an old cover page).
    static func readPage(_ url: URL, index: Int) async -> Page? {
        await Task.detached(priority: .userInitiated) {
            TextScanner.read(url, index: index)
        }.value
    }

    /// Best file names from the text found on some pages.
    static func suggestions(from found: [Found]) -> [String] {
        rank(found)
    }

    // MARK: Reading

    private static func read(_ url: URL, index: Int) -> Page? {
        guard let document = PDFDocument(url: url), let page = document.page(at: index) else { return nil }
        // Skip the cover page that version 2.0 added (it's real text, not a photo).
        if page.string?.contains(PDFBuilder.coverMark) == true { return nil }

        let bounds = page.bounds(for: .mediaBox)
        let longest = max(bounds.width, bounds.height)
        guard longest > 0 else { return nil }
        let readSize = CGSize(width: bounds.width * 1800 / longest, height: bounds.height * 1800 / longest)
        guard let image = page.thumbnail(of: readSize, for: .mediaBox).cgImage else { return nil }
        let found = recognize(image, page: index)

        // A smaller copy to show on screen.
        let showSize = CGSize(width: bounds.width * 900 / longest, height: bounds.height * 900 / longest)
        let shown = page.thumbnail(of: showSize, for: .mediaBox)

        return Page(id: index, image: shown, lines: tapLines(found), found: found)
    }

    /// Text to show as tap targets: no page numbers, and no small boxes hidden under a bigger one
    /// (curved text like a round logo is often read several times).
    private static func tapLines(_ found: [Found]) -> [Line] {
        let candidates = found
            .filter { !$0.text.isEmpty && $0.confidence >= 0.3 && !isPageNumber($0.text) }
            .sorted { $0.box.width * $0.box.height > $1.box.width * $1.box.height }
        var kept: [Found] = []
        for item in candidates {
            let area = item.box.width * item.box.height
            let hidden = kept.contains { other in
                let overlap = other.box.intersection(item.box)
                return !overlap.isNull && overlap.width * overlap.height > 0.6 * area
            }
            if !hidden { kept.append(item) }
        }
        return kept.map { item in
            Line(text: String(item.text.prefix(80)),
                 box: CGRect(x: item.box.minX, y: 1 - item.box.maxY,
                             width: item.box.width, height: item.box.height))
        }
    }

    /// "2 / 3": the page number StampCam prints on PDF pages.
    private static func isPageNumber(_ text: String) -> Bool {
        text.range(of: #"^\s*\d+\s*/\s*\d+\s*$"#, options: .regularExpression) != nil
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
        guard text.count >= 2, item.confidence >= 0.6 else { return false }

        let scalars = text.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        guard !scalars.isEmpty, Double(letters) / Double(scalars.count) >= 0.5 else { return false }

        // Persian-only letters (ی ک گ پ چ ژ) on Arabic signs usually mean the text was misread.
        let persianOnly: Set<UInt32> = [0x06CC, 0x06A9, 0x06AF, 0x067E, 0x0686, 0x0698]
        if text.unicodeScalars.contains(where: { persianOnly.contains($0.value) }) { return false }

        // Arabic and English letters mixed in one line is usually misread handwriting.
        let hasArabic = isArabic(text)
        let hasLatin = text.unicodeScalars.contains { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }
        if hasArabic && hasLatin { return false }

        // English lines: most words should be real words or names (drops scribbles read as text).
        if hasLatin && !looksLikeEnglish(text) { return false }

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

    private static func looksLikeEnglish(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 3 }
        guard words.count >= 2 else { return true }      // short names and single words are fine
        // UIKit's spell checker is used on the main thread to be safe.
        let check = { () -> Int in
            let checker = UITextChecker()
            return words.filter { word in
                if word.first?.isUppercase == true { return true }    // names, brands
                let range = NSRange(location: 0, length: (word as NSString).length)
                return checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0,
                                                     wrap: false, language: "en").location == NSNotFound
            }.count
        }
        let good = Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
        return Double(good) / Double(words.count) >= 0.5
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
