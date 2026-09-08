// Copyright © 2026 Apple Inc.

import PDFKit
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Painting an answer's evidence onto the office's own document.
///
/// # IN MEMORY ONLY. `.source.pdf` IS NEVER REWRITTEN.
///
/// There is no `write(to:)` here, no `dataRepresentation()`, no autosave, and there must
/// never be. Those bytes are the ones `NOTICE.md` describes and the ones this app promises
/// are the office's: a reader who exports the PDF, mails it to counsel or hashes it must get
/// back exactly what was published. `PDFAnnotation` objects added to a `PDFPage` live in the
/// in-memory document and touch the file only if somebody asks the document to save itself.
/// Nobody does. The manual checklist `cmp`s the file before and after a session of
/// highlighting for exactly this reason.
///
/// ## Why one annotation per line
///
/// Not an optimisation — the opposite, it makes more objects. A multi-line `PDFSelection`'s
/// `bounds(for:)` is the union of its lines, and on a two-column grant the union of a
/// paragraph that runs down the left column is a rectangle that also covers the right one.
/// `selectionsByLine()` gives back one selection per printed line, each of whose bounds is
/// the line it is actually on.
///
/// ## Why it tracks what it added
///
/// An office PDF ships its own annotations: link annotations over the citation list, widget
/// annotations on a filled form, the odd stamp. Clearing `page.annotations` wholesale to tidy
/// up would vandalise the document on screen and there would be no way back short of
/// re-reading the file. So every annotation this type creates is kept, and only those are
/// removed.
@MainActor
final class PatentPDFMarks {

    /// Exactly what was added, and where. Never `page.annotations`.
    private var added: [(page: PDFPage, annotation: PDFAnnotation)] = []

    /// The last plan drawn, so an unchanged plan costs one dictionary comparison.
    ///
    /// `HighlightPlan` is `Equatable` for this: `PDFView.update` runs on every SwiftUI pass,
    /// and rebuilding a few hundred annotations at that rate would be visible.
    private var applied: [CitationTarget: HighlightRole] = [:]

    /// Which document the marks are on. Annotations belong to `PDFPage` objects, so a
    /// reloaded document has different pages and the marks have to be drawn again — the
    /// identity comparison is what notices.
    private weak var drawn: PDFDocument?

    /// Draws the difference between the last plan and this one.
    func apply(
        _ plan: HighlightPlan, from map: PatentPDFMap, numbering: Numbering,
        to document: PDFDocument, redrawing view: PDFView
    ) {
        guard drawn !== document || applied != plan.roles else { return }

        clear()
        drawn = document
        applied = plan.roles

        for (target, role) in plan.roles {
            guard let selection = map.selection(for: target) else { continue }
            let label = Citation.chipLabel(target, numbering: numbering)
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let bounds = line.bounds(for: page)
                    guard bounds.width > 0, bounds.height > 0 else { continue }
                    let annotation = mark(bounds: bounds, role: role, label: label)
                    page.addAnnotation(annotation)
                    added.append((page, annotation))
                }
            }
        }

        // PDFKit does not reliably redraw after `addAnnotation` on a page that is already
        // laid out. Both, because which one is enough has varied by release and neither
        // costs anything.
        view.layoutDocumentView()
        #if os(macOS)
            view.setNeedsDisplay(view.bounds)
        #else
            view.setNeedsDisplay()
        #endif
    }

    /// Takes back every annotation this type added, and nothing else.
    func clear() {
        for (page, annotation) in added { page.removeAnnotation(annotation) }
        added = []
        applied = [:]
        drawn = nil
    }

    deinit {
        // `added` holds the pages, so the annotations outlive this object unless they are
        // taken off. Non-isolated, and every touch here is on objects nothing else holds a
        // reference to by the time this runs.
        MainActor.assumeIsolated {
            for (page, annotation) in added { page.removeAnnotation(annotation) }
        }
    }

    /// One line's mark.
    ///
    /// **The subtype choice is here and nowhere else**, deliberately: `.highlight` measured
    /// translucent on this SDK — a page rendered with and without one went from 0.188 to
    /// 0.201 surviving dark pixels, so the text underneath is still there — but highlight
    /// compositing is version-dependent, and if a future release paints it opaque the swap
    /// to `.underline` is this one line.
    private func mark(bounds: CGRect, role: HighlightRole, label: String) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        annotation.color = Self.colour(role)
        // Surfaced as a tooltip on macOS only, exactly as `PlatformCompat.setToolTip`
        // documents for the citation chips: a phone has no pointer to hover with, and there
        // is nowhere else on an annotation to say this.
        annotation.contents = "\(label) — \(Self.reason(role))"
        // A reader must not be able to drag, resize or delete the app's evidence, and a
        // printed copy is the office's document rather than this app's reading of it.
        annotation.isReadOnly = true
        annotation.shouldPrint = false
        return annotation
    }

    /// The three channels' one colour rule.
    ///
    /// Retrieved is deliberately quieter than a find hit's `yellow 0.30`: "the model was
    /// shown this" is weaker evidence than "you searched for this", and the document should
    /// say so without the reader having to be told.
    private static func colour(_ role: HighlightRole) -> PlatformColor {
        switch role {
        case .retrieved: .systemYellow.withAlphaComponent(0.18)
        case .cited: .systemYellow.withAlphaComponent(0.42)
        case .focused: PlatformColor.readerAccent.withAlphaComponent(0.30)
        }
    }

    private static func reason(_ role: HighlightRole) -> String {
        switch role {
        case .retrieved: "one of the passages the model was shown"
        case .cited: "cited in the answer"
        case .focused: "the passage you asked for"
        }
    }
}

/// The concrete colour class, and the accent.
///
/// Here rather than in `PlatformCompat.swift` for `PatentPDFView`'s reason next door: this
/// file is already the one place in the app that talks to PDFKit's drawing, and the two
/// superclass names belong with it rather than in a file whose job is to keep the rest of
/// the app platform-free.
#if os(macOS)
    typealias PlatformColor = NSColor

    extension NSColor {
        static var readerAccent: NSColor { .controlAccentColor }
    }
#else
    typealias PlatformColor = UIColor

    extension UIColor {
        static var readerAccent: UIColor { .tintColor }
    }
#endif
