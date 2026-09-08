// Copyright © 2026 Apple Inc.

import Foundation
import PDFKit

/// The terminal commands that touch the library rather than the model.
///
/// `--fetch` earns its place beyond convenience: it is the only automated way to run the
/// **live** parse. `--selftest` reads checked-in fixtures, which is what makes it fast
/// and hermetic and also means it can only detect drift that has already been captured.
/// Fetching a patent that is not a fixture is the check that catches Google Patents
/// changing its markup *today*, and it is the one thing in the verification list that
/// cannot be automated without making the build depend on somebody else's website.
///
/// `--paragraph` and `--claim` are `--passage`'s counterparts next door: they resolve a
/// citation from a terminal, which is how the resolver is checked without clicking a chip.
@MainActor
enum LibraryCommands {

    /// `--fetch US10123456B2`, repeatable.
    ///
    /// Also indexes, and waits for it. The app deliberately does not wait — a patent is
    /// readable the moment it is parsed — but there is no progress to watch in a
    /// terminal, so here "done" has to mean searchable.
    static func fetch(_ numbers: [String], indexing: Bool = true) async -> Bool {
        let library = LibraryService()
        library.load()

        var ok = true
        var wanted: [PatentKey] = []
        for spelling in numbers {
            guard let key = PatentNumberParser.parse(spelling) else {
                print("\(spelling): not a patent number")
                ok = false
                continue
            }
            // Already in the library is not an error here, unlike in the app: the reader
            // there typed a number they already have, and refusing is the right answer.
            // From a terminal `--fetch` is how a library gets built and rebuilt, often in
            // a loop over the same list, so re-running it should converge rather than
            // fail — and the patent still needs indexing if it has none.
            if let existing = library.patents.first(where: {
                $0.key.country == key.country && $0.key.serial == key.serial
            }) {
                print("\(existing.key.display) is already in the library")
                wanted.append(existing.key)
                if case .ready = library.state(of: existing.key) {
                } else {
                    library.enqueue(existing.key)
                }
                continue
            }

            print("fetching \(key.display)…")
            await library.fetch(key)
            if let error = library.importError {
                print("  failed: \(error)")
                ok = false
                continue
            }
            guard let patent = library.store.patent(key) else {
                print("  failed: nothing was stored")
                ok = false
                continue
            }
            wanted.append(patent.key)
            print(
                """
                  \(patent.key.slug) — \(patent.title)
                  \(patent.assignee ?? "no assignee") · \(patent.publicationDate ?? "no date")
                  \(patent.paragraphs.count) paragraphs (\(patent.numbering.rawValue)) · \
                \(patent.claims.count) claims \
                (\(patent.claims.filter(\.isIndependent).count) independent) · \
                \(patent.calloutNumerals.count) reference numerals
                """)
            if let note = patent.source.note { print("  note: \(note)") }
        }

        if indexing, !wanted.isEmpty {
            print("indexing…")
            let started = Date()
            await library.waitForIndexing()
            for key in wanted {
                let state = library.state(of: key)
                print("  \(key.slug): \(state.label)")
                if case .failed = state { ok = false }
            }
            print(
                String(
                    format: "  %d chunks in %.1fs", library.index.chunks.count,
                    Date().timeIntervalSince(started)))
        }

        print("library: \(library.patents.count) patents")
        return ok
    }

    /// `--patent US10123456B2 --paragraph 42`, or `--claim 7`.
    ///
    /// Prints exactly what a citation to that passage would say, and the passage itself,
    /// so the resolver can be checked against a printed copy without opening the app.
    static func show(_ options: AppOptions) -> Bool {
        let library = LibraryService()
        library.load()

        guard let spelling = options.patents.first,
            let key = PatentNumberParser.parse(spelling)
        else {
            print("--paragraph and --claim need a --patent")
            return false
        }
        guard
            let patent = library.patents.first(where: {
                $0.key.country == key.country && $0.key.serial == key.serial
            })
        else {
            print("\(key.display) is not in the library — fetch it first with --fetch")
            return false
        }

        let target: CitationTarget
        if let number = options.paragraph {
            target = .paragraph(ParagraphKey(patent: patent.key, number: number))
        } else if let number = options.claim {
            target = .claim(ClaimKey(patent: patent.key, number: number))
        } else {
            print("--patent needs a --paragraph or a --claim")
            return false
        }

        guard let row = patent.rows.first(where: { $0.target(in: patent.key) == target })
        else {
            print(
                "\(Citation.string(target, numbering: patent.numbering)) does not exist "
                    + "in this patent")
            return false
        }

        print(Citation.string(target, numbering: patent.numbering))
        print(String(repeating: "-", count: 78))
        print(row.copyText)
        if case .claim(let claim) = row.kind, !claim.dependsOn.isEmpty {
            print(String(repeating: "-", count: 78))
            print(
                "depends on claim \(claim.dependsOn.map(String.init).joined(separator: ", "))"
                    + " (\(claim.dependencySource.rawValue))")
            print("as embedded: \(Chunker.resolvedText(of: claim, in: patent).prefix(300))…")
        }
        return true
    }

    /// `--anchor US10123456B2`, repeatable.
    ///
    /// **The probe harness, in the app.** It opens the stored `.source.pdf`, runs the real
    /// anchoring against it, and prints what happened.
    ///
    /// This exists because of a gap in the evidence the whole feature rests on, and the gap
    /// is worth stating rather than working around. `--selftest` is PDFKit-free by policy and
    /// there is no PDF fixture in this repository, so everything the self test can assert
    /// about anchoring stops at the needle. The measurements that decided the design — 97% of
    /// paragraphs located, ambiguity the norm, the ordering pass changing 42–58% of
    /// placements — were all taken against PDF-*imported* patents, where the parse and the
    /// PDF are the same document.
    ///
    /// The case nobody has measured is the common one: a patent fetched by number, whose text
    /// came from Google's HTML and whose PDF came from `patentimages`. Those two can differ —
    /// US10123456B2 claim 5 reads "wherein fon ling the internal matrix" in Google's OCR — and
    /// a needle taken from one and looked for in the other is exactly where this would fail.
    /// This is how anyone checks, on any patent in any library, without a network, a model or
    /// a checked-in fixture.
    static func anchor(_ numbers: [String]) async -> Bool {
        let library = LibraryService()
        library.load()

        var ok = true
        for spelling in numbers {
            guard let requested = PatentNumberParser.parse(spelling) else {
                print("\(spelling): not a patent number")
                ok = false
                continue
            }
            guard
                let patent = library.patents.first(where: {
                    $0.key.country == requested.country && $0.key.serial == requested.serial
                })
            else {
                print("\(requested.display) is not in the library — fetch it first")
                ok = false
                continue
            }
            guard case .onDisk(let file) = library.pdf.state(for: patent) else {
                print(
                    "\(patent.key.display): no PDF on disk — open it in the reader once, or "
                        + "import the file")
                ok = false
                continue
            }
            guard let document = PDFDocument(url: file) else {
                print("\(patent.key.display): PDFKit could not open \(file.lastPathComponent)")
                ok = false
                continue
            }

            let map = PatentPDFMap(patent: patent)
            await map.build(in: document)
            guard let report = map.report else {
                print("\(patent.key.display): the walk was cancelled")
                ok = false
                continue
            }

            print("\(patent.key.display) — \(document.pageCount) pages")
            print(
                "  placed \(report.placedParagraphs)/\(report.totalParagraphs) paragraphs · "
                    + "claims \(report.placedClaims)/\(report.totalClaims) · "
                    + "ambiguous \(report.ambiguous) · monotonic changed \(report.corrected)")
            let unanchorable =
                (report.totalParagraphs - report.anchoredParagraphs)
                + (report.totalClaims - report.anchoredClaims)
            print(
                String(
                    format: "  %d too short to anchor · %d fell back · %.2fs",
                    unanchorable, report.fellBack, report.seconds))
            if !map.unplaced.isEmpty {
                // Named rather than counted, and capped rather than truncated silently: the
                // interesting question about a miss is always *which* one, because a run of
                // consecutive misses is a different bug from a scattering of them.
                let named = map.unplaced.prefix(20).map {
                    Citation.chipLabel($0, numbering: patent.numbering)
                }
                print(
                    "  not found: " + named.joined(separator: ", ")
                        + (map.unplaced.count > 20
                            ? " … and \(map.unplaced.count - 20) more" : ""))
            }
        }
        return ok
    }
}
