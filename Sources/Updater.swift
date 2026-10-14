//  Updater.swift
//  Checks GitHub for a newer StampCam and downloads it, ready to install with your signing app.

import Foundation
import UIKit

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
    /// When this copy of the app was built.
    static var buildDate: Date? {
        guard let url = Bundle.main.executableURL,
              let values = try? url.resourceValues(forKeys: [.creationDateKey]) else { return nil }
        return values.creationDate
    }
    static var buildDateText: String {
        guard let date = buildDate else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy"
        return f.string(from: date)
    }
    /// Model code like "iPhone17,2".
    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
    /// Short summary to paste when reporting a problem.
    static var summary: String {
        """
        StampCam \(version) (\(build))\(buildDateText.isEmpty ? "" : " · built \(buildDateText)")
        \(deviceModel) · iOS \(UIDevice.current.systemVersion)
        """
    }
}

enum Updater {
    static let repo = "husain-313/StampCam"

    struct Release {
        let version: String
        let notes: String
        let downloadURL: URL
    }

    enum Failure: LocalizedError {
        case offline, noRelease
        var errorDescription: String? {
            switch self {
            case .offline: return "Couldn't reach GitHub. Check your internet and try again."
            case .noRelease: return "No version to download was found."
            }
        }
    }

    /// The newest iPhone release on GitHub (Android copies are tagged "android-…" and skipped).
    static func latest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=20")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.offline }

        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Item: Decodable {
            let tag_name: String
            let body: String?
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
        }
        let items = (try? JSONDecoder().decode([Item].self, from: data)) ?? []
        let candidates = items.compactMap { item -> Release? in
            guard !item.draft, !item.prerelease, item.tag_name.hasPrefix("v"),
                  let asset = item.assets.first(where: { $0.name.lowercased().hasSuffix(".ipa") }) else { return nil }
            return Release(version: String(item.tag_name.dropFirst()),
                           notes: cleanNotes(item.body ?? ""),
                           downloadURL: asset.browser_download_url)
        }
        guard let newest = candidates.max(by: { isNewer($1.version, than: $0.version) }) else {
            throw Failure.noRelease
        }
        return newest
    }

    /// Downloads the IPA to a temporary file named like "StampCam-2.7.ipa".
    static func download(_ release: Release) async throws -> URL {
        guard let (temp, response) = try? await URLSession.shared.download(from: release.downloadURL),
              (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.offline }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("StampCam-\(release.version).ipa")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    /// "2.10" is newer than "2.9"; "2.6.1" is newer than "2.6".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0
            let q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// Release notes as plain text (no Markdown stars or headings).
    private static func cleanNotes(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
            .map { line -> String in
                var l = line
                while l.hasPrefix("#") { l.removeFirst() }
                return l.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "^- ", with: "• ", options: .regularExpression)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
