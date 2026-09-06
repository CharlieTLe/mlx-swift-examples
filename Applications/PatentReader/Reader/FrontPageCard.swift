// Copyright © 2026 Apple Inc.

import SwiftUI

/// The patent's front page, as a card above the document.
///
/// A patent's first page is a form: number, dates, assignee, inventors, classification,
/// abstract. Reproducing it as a card rather than as more paragraphs is what tells a
/// reader at a glance whose patent this is and when it issued — which is most of what
/// they need before reading a word of the specification, and all of what they need to
/// decide it is the wrong document.
///
/// Collapsible and persisted, because a reader deep in the detailed description does not
/// want to scroll past a form to get back to it — and because at a compact width the
/// card would otherwise fill the screen on arrival.
@MainActor
struct FrontPageCard: View {
    let patent: Patent

    @AppStorage("showsFrontPage") private var isExpanded = true
    @Environment(\.readerTypeface) private var typeface

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(patent.title)
                        .font(typeface.frontPageTitle)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isExpanded ? "Hide the front page" : "Show the front page")

            Text(patent.key.display)
                .font(typeface.frontPageDetail.monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if isExpanded {
                details
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Published", patent.publicationDate)
            row("Filed", patent.priorityDate)
            row("Assignee", patent.assignee)
            row(
                "Inventors",
                patent.inventors.isEmpty ? nil : patent.inventors.joined(separator: ", "))

            if !patent.classifications.isEmpty {
                classifications
            }

            if !patent.abstract.isEmpty {
                Text(patent.abstract)
                    .font(typeface.body)
                    .textSelection(.enabled)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        // The same left-rule idiom the answer pane uses for the passage
                        // it is glossing: this is the patent's own summary of itself,
                        // quoted, rather than the app's prose.
                        Rectangle().fill(.quaternary).frame(width: 2)
                    }
                    .padding(.top, 4)
            }

            // Where the document came from, and anything the importer had to admit to.
            // Small, last, and never hidden — a patent that came in through the PDF path
            // with reconstructed numbering should say so somewhere the reader will see it
            // before quoting from it.
            provenance
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label.uppercased())
                    .font(typeface.frontPageLabel)
                    .tracking(0.4)
                    .foregroundStyle(.tertiary)
                    .frame(width: 76, alignment: .leading)
                Text(value)
                    .font(typeface.frontPageDetail)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// CPC codes as chips, each with the office's own gloss underneath.
    ///
    /// Only the **leaf** codes are shown — the ones with a slash, `H05K7/20336` — even
    /// though the parser keeps the whole hierarchy. The hierarchy is what makes the leaf
    /// intelligible and it is four rows of "ELECTRICITY" to say so; the leaf is the one a
    /// reader would search on. The parents stay in the model for whoever wants them.
    @ViewBuilder
    private var classifications: some View {
        let leaves = patent.classifications.filter { $0.code.contains("/") }.prefix(6)
        if !leaves.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("CLASSIFICATION")
                    .font(typeface.frontPageLabel)
                    .tracking(0.4)
                    .foregroundStyle(.tertiary)
                ForEach(Array(leaves), id: \.code) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.code)
                            .font(typeface.frontPageDetail.monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        Text(entry.description.lowercased())
                            .font(typeface.frontPageDetail)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var provenance: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(
                sourceDescription,
                systemImage: patent.source.kind == .googlePatentsHTML
                    ? "arrow.down.circle" : "doc"
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)

            if let note = patent.source.note {
                Label(note, systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.top, 4)
    }

    private var sourceDescription: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let when = formatter.string(from: patent.source.retrieved)
        switch patent.source.kind {
        case .googlePatentsHTML: return "Google Patents, \(when)"
        case .pdf: return "Imported from a PDF, \(when)"
        case .plainText: return "Imported from text, \(when)"
        }
    }
}
