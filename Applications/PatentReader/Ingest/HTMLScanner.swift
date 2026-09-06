// Copyright © 2026 Apple Inc.

import Foundation

/// A small, non-validating HTML reader, sufficient for one machine-generated page and
/// deliberately no more.
///
/// **Why not a dependency.** SwiftSoup would parse this page and a thousand others, and
/// that generality is the argument against it here: this app reads exactly one page
/// shape, produced by one generator, and every element it cares about is listed in
/// `GooglePatentsParser`'s table. A parser that only sees what it was told to look for
/// cannot be quietly changed by a redesign that adds nodes — it either finds the five
/// shapes or it fails loudly — where a general DOM invites "walk the children and see
/// what turns up", which is how markup drift becomes a subtly wrong document instead of
/// an error. This repo also keeps its dependency list short, and the whole reader is
/// under 200 lines.
///
/// If a future fixture proves the markup irregular in a way this cannot follow, SwiftSoup
/// is the fallback and that decision should be *recorded here* rather than taken
/// quietly, because it reverses the paragraph above.
///
/// What it deliberately does not do: entity-aware attribute values beyond the five named
/// entities and numeric references, `<script>`/`<style>` content, namespaces, or error
/// recovery of any kind. Nothing on this page needs them.
enum HTMLScanner {

    /// One element and its subtree. `text` is non-nil only for a text node, which
    /// carries no name and no children.
    struct Node: Sendable {
        var name: String = ""
        var attributes: [String: String] = [:]
        var children: [Node] = []
        var text: String?

        var isText: Bool { text != nil }

        subscript(attribute: String) -> String? { attributes[attribute] }

        /// Whether this element carries `class="…"` containing `value` as a whole
        /// class token. Substring matching would make `description-paragraph` match
        /// `description-paragraph-continued`, which is exactly the kind of near-miss
        /// that produces a document that looks right and is not.
        func hasClass(_ value: String) -> Bool {
            attributes["class"]?
                .split(whereSeparator: \.isWhitespace)
                .contains(where: { $0 == value }) ?? false
        }
    }

    /// Elements with no closing tag. A `<meta>` treated as an open element swallows the
    /// rest of the document into itself.
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
        "param", "source", "track", "wbr",
    ]

    /// Elements the page leaves unclosed, which the stack has to close on its own when
    /// a sibling of the same name opens. Google Patents closes its `div`s properly; the
    /// classification lists are where `<li>` runs on.
    private static let selfClosingOnSibling: Set<String> = ["li", "p", "option"]

    /// Parses `html` into a forest of nodes.
    ///
    /// A forest and not one root, because the useful call site hands in a *slice* — the
    /// description section, the claims section — rather than the whole page, which keeps
    /// this off the 215 KB of chrome around them.
    static func parse(_ html: Substring) -> [Node] {
        var roots: [Node] = []
        var stack: [Node] = []

        func append(_ node: Node) {
            if stack.isEmpty {
                roots.append(node)
            } else {
                stack[stack.count - 1].children.append(node)
            }
        }

        func closeTop() {
            guard let finished = stack.popLast() else { return }
            append(finished)
        }

        var index = html.startIndex
        var textStart = index

        func flushText(upTo end: Substring.Index) {
            guard textStart < end else { return }
            let raw = String(html[textStart ..< end])
            guard !raw.isEmpty else { return }
            append(Node(text: decodeEntities(raw)))
        }

        while let open = html[index...].firstIndex(of: "<") {
            flushText(upTo: open)

            // A comment, a doctype, or a CDATA-alike: skipped whole, never entered.
            if html[open...].hasPrefix("<!--") {
                guard let end = html.range(of: "-->", range: open ..< html.endIndex) else {
                    break
                }
                index = end.upperBound
                textStart = index
                continue
            }
            if html[open...].hasPrefix("<!") {
                guard let end = html[open...].firstIndex(of: ">") else { break }
                index = html.index(after: end)
                textStart = index
                continue
            }

            guard let close = html[open...].firstIndex(of: ">") else { break }
            let inside = html[html.index(after: open) ..< close]
            index = html.index(after: close)
            textStart = index

            if inside.hasPrefix("/") {
                let name = String(inside.dropFirst()).trimmingCharacters(in: .whitespaces)
                    .lowercased()
                // Close up to and including the matching open element. An unmatched
                // closing tag closes nothing rather than unwinding the whole stack,
                // which is what keeps one stray `</b>` from ending the document.
                guard stack.contains(where: { $0.name == name }) else { continue }
                while let top = stack.last {
                    closeTop()
                    if top.name == name { break }
                }
                continue
            }

            let (name, attributes, isSelfClosed) = parseTag(inside)
            guard !name.isEmpty else { continue }

            if selfClosingOnSibling.contains(name), stack.last?.name == name {
                closeTop()
            }

            let node = Node(name: name, attributes: attributes)
            if isSelfClosed || voidElements.contains(name) {
                append(node)
            } else if name == "script" || name == "style" {
                // Raw-text elements: their content may contain `<`, so it is skipped by
                // string search rather than by tokenizing.
                if let end = html.range(of: "</\(name)", range: index ..< html.endIndex) {
                    index = end.lowerBound
                    textStart = index
                }
                append(node)
            } else {
                stack.append(node)
            }
        }

        flushText(upTo: html.endIndex)
        while !stack.isEmpty { closeTop() }
        return roots
    }

    /// `name`, attributes, and whether the tag closed itself, from the text between the
    /// angle brackets.
    private static func parseTag(
        _ inside: Substring
    ) -> (String, [String: String], Bool) {
        var body = inside
        var selfClosed = false
        if body.hasSuffix("/") {
            selfClosed = true
            body = body.dropLast()
        }

        let scanner = Scanner(string: String(body))
        scanner.charactersToBeSkipped = .whitespacesAndNewlines
        guard let name = scanner.scanUpToCharacters(from: .whitespacesAndNewlines)
        else { return ("", [:], selfClosed) }

        var attributes: [String: String] = [:]
        while !scanner.isAtEnd {
            guard let key = scanner.scanUpToCharacters(from: CharacterSet(charactersIn: "= \t\n\r"))
            else { break }
            guard scanner.scanString("=") != nil else {
                // A valueless attribute (`itemscope`, `repeat`). Recorded as empty so a
                // caller can test for presence.
                attributes[key.lowercased()] = ""
                continue
            }
            let value: String?
            if scanner.scanString("\"") != nil {
                value = scanner.scanUpToString("\"") ?? ""
                _ = scanner.scanString("\"")
            } else if scanner.scanString("'") != nil {
                value = scanner.scanUpToString("'") ?? ""
                _ = scanner.scanString("'")
            } else {
                value = scanner.scanUpToCharacters(from: .whitespacesAndNewlines) ?? ""
            }
            attributes[key.lowercased()] = decodeEntities(value ?? "")
        }
        return (name.lowercased(), attributes, selfClosed)
    }

    // MARK: - Entities

    /// The five named entities every document uses, plus the handful this page actually
    /// emits, plus numeric references.
    ///
    /// A full HTML5 entity table is 2,231 names and would be the largest file in the
    /// target. These are the ones present in the fixtures; anything else is left as
    /// literal text, which is visibly wrong rather than silently wrong — `&hellip;`
    /// showing through is a bug report, where a mangled character is not.
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "mdash": "—", "ndash": "–", "hellip": "…",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "deg": "°", "micro": "µ", "plusmn": "±", "times": "×", "divide": "÷",
        "frac12": "½", "frac14": "¼", "frac34": "¾", "sup2": "²", "sup3": "³",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "mu": "μ", "pi": "π",
        "sigma": "σ", "omega": "ω", "Delta": "Δ", "Omega": "Ω",
        "le": "≤", "ge": "≥", "ne": "≠", "asymp": "≈", "prime": "′", "Prime": "″",
        "trade": "™", "reg": "®", "copy": "©", "sect": "§", "para": "¶", "bull": "•",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var out = ""
        out.reserveCapacity(text.count)
        var rest = Substring(text)

        while let start = rest.firstIndex(of: "&") {
            out += rest[rest.startIndex ..< start]
            rest = rest[rest.index(after: start)...]

            // An entity is short; a bare ampersand in prose ("R&D and the like") must
            // not eat the rest of the paragraph looking for a semicolon.
            let window = rest.prefix(12)
            guard let semicolon = window.firstIndex(of: ";") else {
                out.append("&")
                continue
            }
            let name = String(rest[rest.startIndex ..< semicolon])
            if let decoded = decode(entityNamed: name) {
                out += decoded
                rest = rest[rest.index(after: semicolon)...]
            } else {
                out.append("&")
            }
        }
        out += rest
        return out
    }

    private static func decode(entityNamed name: String) -> String? {
        if let mapped = namedEntities[name] { return mapped }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let value: UInt32?
        if digits.first == "x" || digits.first == "X" {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits)
        }
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }
}

extension HTMLScanner.Node {
    /// Every descendant element with the given tag name, in document order.
    func descendants(named name: String) -> [HTMLScanner.Node] {
        var found: [HTMLScanner.Node] = []
        for child in children where !child.isText {
            if child.name == name { found.append(child) }
            found += child.descendants(named: name)
        }
        return found
    }

    /// Every descendant element carrying the given class token, in document order.
    ///
    /// Does **not** descend into a match, which matters: `div.claim` wraps a nested
    /// `div.claim` in this markup, and a search that recursed into hits would report the
    /// same claim twice. A caller that wants the inner one asks the outer one for it.
    func descendants(class value: String) -> [HTMLScanner.Node] {
        var found: [HTMLScanner.Node] = []
        for child in children where !child.isText {
            if child.hasClass(value) {
                found.append(child)
            } else {
                found += child.descendants(class: value)
            }
        }
        return found
    }

    /// The subtree's text, with inline tags removed and whitespace collapsed.
    ///
    /// Whitespace collapse is not cosmetic. The source sets a paragraph across a dozen
    /// physical lines with the indentation of the generator's own template, and a
    /// paragraph carrying that arrives in the prompt as a dozen newlines of nothing —
    /// tokens paid for whitespace, and a passage that reads as a list when it is prose.
    var textContent: String {
        var out = ""
        collectText(into: &out)
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Elements that separate the text either side of them.
    ///
    /// The inverse — treating every element as a separator — is what this started as,
    /// and it is wrong in a way that shows up in the prompt: the claims are full of
    /// `<claim-ref>claim 1</claim-ref>,` and `<b>1</b>.`, so a space after every child
    /// produces "claim 1 ," and "1 ." in text the model is asked to read closely and the
    /// reader is asked to quote. Listing the block elements instead leaves inline markup
    /// invisible, which is what it is.
    private static let blockElements: Set<String> = [
        "div", "p", "li", "ul", "ol", "tr", "td", "th", "table", "section", "article",
        "heading", "abstract", "claim-statement", "blockquote", "br", "dd", "dt", "dl",
        "h1", "h2", "h3", "h4", "h5", "h6", "figure", "figcaption", "maths",
    ]

    private func collectText(into out: inout String) {
        if let text {
            out += text
            return
        }
        for child in children {
            child.collectText(into: &out)
            if !child.isText, Self.blockElements.contains(child.name) { out += " " }
        }
    }
}
