// Copyright © 2026 Apple Inc.

import Foundation

/// Where a patent comes from.
///
/// One protocol so a second source can be added without touching anything downstream:
/// the library, the index and the reader all take a `Patent`, and none of them knows
/// whether it was scraped, fetched from an API, or read off a PDF. That matters more
/// than usual here, because the only source this app ships with is an unofficial one.
///
/// **The source is Google Patents, and the honest position on that is short.** The page
/// is server-rendered and one request per patent, so this is not crawling; patent text
/// is a public record and not copyrightable in the US; but the page markup and Google's
/// own OCR are theirs, and their terms of service for programmatic access are not
/// something this app has cleared. That is worth the reader's own reading before this
/// goes anywhere beyond a personal tool. What this protocol buys is that the answer can
/// change: USPTO's Open Data Portal is a `PatentSource` away, and nothing above this
/// line would move.
protocol PatentSource: Sendable {
    /// A name for the library row and the error message, so a failure says which source
    /// failed.
    var name: String { get }

    func fetch(_ number: PatentKey) async throws -> Patent
}

/// Google Patents, over one HTTPS request.
struct GooglePatentsSource: PatentSource {
    let name = "Google Patents"

    /// `/en` rather than the bare path: without it the page is served in the
    /// publication's own language, and a JP or DE grant then parses into a document the
    /// reader cannot read and the embedder cannot index. The English machine translation
    /// is imperfect and is labelled as such by the source, which is a limitation worth
    /// knowing about rather than a reason to fetch the other one.
    private static func url(for key: PatentKey) -> URL? {
        URL(string: "https://patents.google.com/patent/\(key.slug)/en")
    }

    enum Failure: LocalizedError {
        case badNumber(PatentKey)
        case notFound(PatentKey, status: Int)
        case notText

        var errorDescription: String? {
            switch self {
            case .badNumber(let key):
                "\(key.display) is not a number this source can address."
            case .notFound(let key, let status):
                status == 404
                    ? "Google Patents has no page for \(key.display). Check the number, "
                        + "including the kind code — US 10,123,456 is a B2."
                    : "Google Patents answered \(status) for \(key.display)."
            case .notText:
                "The response was not text. That usually means a network appliance "
                    + "returned a captcha or an error page instead of the patent."
            }
        }
    }

    func fetch(_ number: PatentKey) async throws -> Patent {
        guard let url = Self.url(for: number) else { throw Failure.badNumber(number) }

        var request = URLRequest(url: url)
        // The default `URLSession` user agent is the bundle id, which reads as anonymous
        // traffic. Naming the app is the courteous thing to do and makes this app's
        // requests attributable in somebody else's logs, which is the least a scraper
        // owes its source. The page is served identically with or without it — checked.
        request.setValue(
            "PatentReader/1.0 (mlx-swift-examples; on-device patent reader)",
            forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.notFound(number, status: http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else { throw Failure.notText }

        return try GooglePatentsParser.parse(
            html, requested: number, url: url.absoluteString)
    }

    /// The fetched bytes, unparsed.
    ///
    /// Kept alongside `fetch` so `tools/refresh_fixtures.swift` can update the golden
    /// fixtures through the very code path the app uses, rather than through a curl
    /// invocation that might differ in a header.
    func fetchSource(_ number: PatentKey) async throws -> (html: String, url: URL) {
        guard let url = Self.url(for: number) else { throw Failure.badNumber(number) }
        var request = URLRequest(url: url)
        request.setValue(
            "PatentReader/1.0 (mlx-swift-examples; on-device patent reader)",
            forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.notFound(number, status: http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else { throw Failure.notText }
        return (html, url)
    }
}
