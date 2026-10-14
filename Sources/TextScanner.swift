//  TextScanner.swift
//  Reads the text in all of a PDF's photos (on-device, Apple Vision) and suggests file names.
//  Big, centered text that shows up in several photos (usually the sign) comes first;
//  two-line signs are joined, and things that make poor names (phone numbers, websites,
//  prices, "Made in …") are skipped.

import UIKit
import Vision
import PDFKit

enum TextScanner {
    struct Found {
        let text: String
        let box: CGRect         // normalized, origin bottom-left (Vision)
        let confidence: Float
        let page: Int
        var merged = false
    }

    /// The best file names from the text in the PDF's photos (most likely first, at most 8).
    static func suggestions(for url: URL, maxPages: Int = 30) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            TextScanner.scan(url, maxPages: maxPages)
        }.value
    }

    // MARK: Reading

    private static func scan(_ url: URL, maxPages: Int) -> [String] {
        guard let document = PDFDocument(url: url) else { return [] }
        var found: [Found] = []
        var scanned = 0
        for index in 0..<document.pageCount where scanned < maxPages {
            guard let page = document.page(at: index) else { continue }
            // Skip the cover page that version 2.0 added (it's real text, not a photo).
            if page.string?.contains(PDFBuilder.coverMark) == true { continue }
            scanned += 1
            let bounds = page.bounds(for: .mediaBox)
            let longest = max(bounds.width, bounds.height)
            guard longest > 0 else { continue }
            let size = CGSize(width: bounds.width * 1600 / longest, height: bounds.height * 1600 / longest)
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

        // Text seen in several photos (like a shop name shot from a few angles) is more likely the name.
        var pagesByKey: [String: Set<Int>] = [:]
        for item in candidates {
            pagesByKey[normalize(item.text), default: []].insert(item.page)
        }
        func total(_ item: Found) -> CGFloat {
            let seenIn = CGFloat(pagesByKey[normalize(item.text)]?.count ?? 1)
            return score(item) * (1 + 0.35 * (seenIn - 1))
        }

        let sorted = candidates.sorted { total($0) > total($1) }

        var result: [String] = []
        var seen = Set<String>()
        for item in sorted {
            let key = normalize(item.text)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(String(item.text.prefix(60)))
            if result.count == 8 { break }
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

        if isPoorName(text) { return false }

        // Skip our own stamp: the date/time and area names printed on the photos.
        if text.range(of: #"\d{1,4}[-/:.]\d{1,2}[-/:.]\d{1,4}"#, options: .regularExpression) != nil { return false }
        let stamped = UserDefaults.standard.stringArray(forKey: Keys.stampedPlaces) ?? []
        let key = normalize(text)
        return !stamped.contains { normalize($0) == key }
    }

    // MARK: Helpers

    /// Things that rarely make a good file name.
    private static func isPoorName(_ text: String) -> Bool {
        let lower = text.lowercased()
        // Websites, emails, social handles.
        if lower.contains("www") || lower.contains("http") || lower.contains(".com") || lower.contains("@") { return true }
        // Phone numbers (7+ digits).
        if text.filter(\.isNumber).count >= 7 { return true }
        // Prices.
        if text.range(of: #"\d+([.,]\d+)?\s*(bd|bhd|sar|aed|kwd|usd|\$|€|د\.ب|ريال|درهم)"#,
                      options: [.regularExpression, .caseInsensitive]) != nil { return true }
        // Common small print.
        let smallPrint = ["made in", "ingredients", "best before", "expiry", "exp.", "net wt", "barcode",
                          "all rights", "copyright", "no smoking", "no parking"]
        if smallPrint.contains(where: { lower.contains($0) }) { return true }
        // Door and sign words on their own.
        let signWords: Set<String> = ["push", "pull", "exit", "open", "closed", "entrance", "toilet", "wc",
                                      "ادفع", "اسحب", "مخرج", "مدخل", "مفتوح", "مغلق"]
        return signWords.contains(lower.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)))
    }

    private static func clean(_ text: String) -> String {
        // Turns special Arabic letter shapes into normal letters, so the same word always matches.
        text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\u{0640}", with: "")      // tatweel (ـ)
            .components(separatedBy: .whitespacesAndNewlines)
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
        let folded = text.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return String(kept)
    }
}
