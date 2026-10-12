//  TextScanner.swift
//  Reads the text in a PDF's photos (on-device, Apple Vision) and suggests file names.
//  The biggest text (usually the sign) comes first.

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
        let height: CGFloat     // relative text height (0...1)
        let confidence: Float
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
            found += recognize(image)
        }
        return rank(found)
    }

    private static func recognize(_ image: CGImage) -> [Found] {
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
            return Found(text: candidate.string,
                         height: observation.boundingBox.height,
                         confidence: candidate.confidence)
        }
    }

    // MARK: Ranking

    private static func rank(_ found: [Found]) -> [String] {
        // Ignore our own stamp: the date/time and area names we printed on the photos.
        let stamped = Set((UserDefaults.standard.stringArray(forKey: Keys.stampedPlaces) ?? []).map(normalize))

        let cleaned: [Found] = found.compactMap { item in
            let text = item.text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard text.count >= 2, item.confidence >= 0.3 else { return nil }

            let scalars = text.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
            let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
            guard !scalars.isEmpty, Double(letters) / Double(scalars.count) >= 0.5 else { return nil }

            if text.range(of: #"\d{1,4}[-/:.]\d{1,2}[-/:.]\d{1,4}"#, options: .regularExpression) != nil { return nil }
            if stamped.contains(normalize(text)) { return nil }

            return Found(text: text, height: item.height, confidence: item.confidence)
        }

        let sorted = cleaned.sorted {
            $0.height * CGFloat(0.5 + $0.confidence / 2) > $1.height * CGFloat(0.5 + $1.confidence / 2)
        }

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

    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return String(kept)
    }
}
