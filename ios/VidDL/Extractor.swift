import Foundation

struct VideoFormat: Identifiable, Hashable {
    let id = UUID()
    let label: String      // e.g. "1080p"
    let url: URL
    let ext: String
}

struct VideoInfo { let title: String; let formats: [VideoFormat] }

enum ExtractError: LocalizedError {
    case blocked(String), notFound, server(String)
    var errorDescription: String? {
        switch self {
        case .blocked(let s): return s
        case .notFound: return "No downloadable video found at this link."
        case .server(let s): return s
        }
    }
}

/// Resolves a page link into direct video file links.
/// 1. Direct media links are used as-is.
/// 2. Otherwise asks a cobalt-compatible extractor (set in Settings), which handles
///    YouTube, Instagram, Vimeo, Dailymotion, TikTok, X, Reddit and many more.
/// 3. Falls back to scanning the page HTML for .mp4/.m3u8/og:video links.
enum Extractor {
    static let drmHosts = ["netflix.com", "disneyplus.com", "primevideo.com", "hulu.com", "max.com", "tv.apple.com"]
    static let adultHosts = ["pornhub.com", "xvideos.com", "xnxx.com", "xhamster.com", "redtube.com", "youporn.com", "spankbang.com", "eporner.com"]

    static func resolve(_ link: String, allowAdult: Bool, apiURL: String, apiKey: String) async throws -> VideoInfo {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)), let host = url.host?.lowercased() else { throw ExtractError.notFound }
        if drmHosts.contains(where: host.hasSuffix) { throw ExtractError.blocked("This service is copy-protected and can't be downloaded.") }
        if adultHosts.contains(where: host.hasSuffix) && !allowAdult { throw ExtractError.blocked("Adult content is turned off. Enable it in Settings.") }

        let ext = url.pathExtension.lowercased()
        if ["mp4", "mov", "m4v", "webm", "mkv", "m3u8"].contains(ext) {
            return VideoInfo(title: url.deletingPathExtension().lastPathComponent, formats: [VideoFormat(label: "Original", url: url, ext: ext)])
        }
        if !apiURL.isEmpty, let info = try? await cobalt(url, apiURL: apiURL, apiKey: apiKey), !info.formats.isEmpty { return info }
        return try await scrape(url)
    }

    static func cobalt(_ url: URL, apiURL: String, apiKey: String) async throws -> VideoInfo {
        var formats: [VideoFormat] = []
        var title = url.host ?? "video"
        for q in ["2160", "1440", "1080", "720", "480", "360"] {
            var req = URLRequest(url: URL(string: apiURL)!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if !apiKey.isEmpty { req.setValue("Api-Key \(apiKey)", forHTTPHeaderField: "Authorization") }
            req.httpBody = try JSONSerialization.data(withJSONObject: ["url": url.absoluteString, "videoQuality": q, "filenameStyle": "basic"])
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let status = json["status"] as? String
            if status == "error" {
                let code = (json["error"] as? [String: Any])?["code"] as? String ?? "unknown"
                if formats.isEmpty && q == "2160" { throw ExtractError.server("Extractor error: \(code)") }
                continue
            }
            if let s = json["url"] as? String, let u = URL(string: s) {
                if let f = json["filename"] as? String { title = (f as NSString).deletingPathExtension }
                if !formats.contains(where: { $0.url == u }) { formats.append(VideoFormat(label: "\(q)p", url: u, ext: "mp4")) }
            } else if status == "picker", let items = json["picker"] as? [[String: Any]] {
                for (i, it) in items.enumerated() where (it["type"] as? String) == "video" {
                    if let s = it["url"] as? String, let u = URL(string: s) { formats.append(VideoFormat(label: "Item \(i + 1)", url: u, ext: "mp4")) }
                }
                break
            }
        }
        return VideoInfo(title: title, formats: formats)
    }

    static func scrape(_ url: URL) async throws -> VideoInfo {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile Safari/604.1", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        let html = String(decoding: data, as: UTF8.self)
        let pattern = #"https?:[^"'\s<>]+?\.(mp4|m3u8|webm|mov)(\?[^"'\s<>]*)?"#
        let rx = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        var seen = Set<String>(); var formats: [VideoFormat] = []
        for m in rx.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range, in: html) else { continue }
            let s = String(html[r]).replacingOccurrences(of: "\\/", with: "/")
            guard seen.insert(s).inserted, let u = URL(string: s) else { continue }
            let label = s.range(of: #"(\d{3,4})p"#, options: .regularExpression).map { String(s[$0]) } ?? "Source \(formats.count + 1)"
            formats.append(VideoFormat(label: label, url: u, ext: u.pathExtension.lowercased()))
        }
        if formats.isEmpty { throw ExtractError.notFound }
        return VideoInfo(title: url.host ?? "video", formats: formats)
    }
}
