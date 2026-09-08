// Copyright © 2026 Apple Inc.

import Foundation

/// The office's own PDF, as the fetched page names it.
///
/// One `<meta name="citation_pdf_url">` in the head of every Google Patents page:
///
/// ```html
/// <meta name="citation_pdf_url"
///       content="https://patentimages.storage.googleapis.com/52/c3/5d/ce0a71cb00213e/US10123456.pdf">
/// ```
///
/// **Read, never constructed**, and the four checked-in fixtures are the argument.
/// `US10123456B2` publishes `US10123456.pdf`, `US7654321B2` publishes `US7654321.pdf` and
/// `US5000000A` publishes `US5000000.pdf` — three that drop the kind code — while
/// `US20140030575A1` publishes `US20140030575A1.pdf`, which keeps it. All four sit behind
/// an opaque four-segment content hash (`/52/c3/5d/ce0a71cb00213e/`) that is not derivable
/// from anything the app holds. So there is no rule to write: string concatenation would
/// produce a URL that is right for some patents and 404 for others, which is the worst
/// available outcome because it looks like a network problem. `--selftest` asserts the
/// mismatch explicitly, so a later "simplification" into concatenation fails the build.
///
/// **Not on `GooglePatentsParser`**, even though it reads the same metas with the same
/// scanner. That type's `version` is the index's invalidation lever: bumping it reindexes
/// every patent in every library at tens of GPU-seconds each. Nothing here changes the
/// `Patent` a page produces — it is a fact *about the page*, read on demand from bytes
/// already on disk — and filing it next door would put a permanent temptation to bump that
/// counter for a string beside the counter itself.
///
/// **The host is deliberately not pinned.** Checking that the URL points at
/// `patentimages.storage.googleapis.com` would buy nothing today and break silently on the
/// day Google moves the bucket, leaving a reader with a PDF tab that reports "no original
/// PDF" for a page that plainly names one. What the app does instead is *say* which host it
/// is about to talk to, on screen, before it talks to it — see `PatentPDFReaderView`.
enum PatentPDFLink {

    /// The PDF the page points at, or `nil` if it points at none this app will fetch.
    ///
    /// `https` only. The scheme check is the whole of the validation and it is not
    /// theatre: this URL comes out of a document fetched over the network, is handed
    /// straight to `URLSession`, and `file:` would turn a page the app parsed into a read
    /// of the reader's own disk.
    static func url(inPageHTML html: String) -> URL? {
        // The identical expression `GooglePatentsParser.Metadata.init` uses, so the two
        // can never disagree about what counts as a meta — `descendants(named:)` and
        // `meta` in `voidElements` between them are what stop a `<meta>` swallowing the
        // rest of the head.
        for meta in HTMLScanner.parse(Substring(html)).flatMap({ $0.descendants(named: "meta") }) {
            guard meta["name"] == "citation_pdf_url" else { continue }
            let content = (meta["content"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Attribute values arrive entity-decoded from `HTMLScanner`, so a query string
            // written `?x=1&amp;y=2` in the markup is already `?x=1&y=2` here. That is the
            // second reason not to hand-roll a regex for this one attribute.
            guard !content.isEmpty, let url = URL(string: content), url.scheme == "https"
            else { continue }
            return url
        }
        return nil
    }
}
