// Copyright © 2026 Apple Inc.

import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// The handful of places where AppKit and UIKit genuinely differ.
///
/// Everything the reader draws is otherwise the same code on both platforms, and the
/// point of this file is to keep it that way: the platform split lives here and in the
/// two places where the *layout* differs (`ContentView`'s container, and
/// `DocumentReaderView`'s pointer gestures), not scattered through the view bodies.
///
/// What is deliberately **not** here, because it needed no shim: `.help`,
/// `.controlSize`, `.buttonStyle(.borderless)`, `.menuIndicator`,
/// `.listStyle(.sidebar)`, `.focusEffectDisabled`, `.textSelection`,
/// `.textFieldStyle(.plain)`, `.keyboardShortcut`, and the whole CoreText path in
/// `ReaderFontLibrary`. All of them are available on both.

/// The concrete font class, which is what `ReaderFont` needs to ask the system for a
/// text style's point size. `NSFont.TextStyle` and `UIFont.TextStyle` spell their
/// cases identically, so only the lookup call itself has to be written twice.
#if os(macOS)
    typealias PlatformFont = NSFont
#else
    typealias PlatformFont = UIFont
#endif

/// Whether shift is held *right now*.
///
/// Read from the event state rather than through `TapGesture().modifiers(.shift)`,
/// which is unreliable, and because SwiftUI does not report modifiers on a move
/// command at all. `false` on iOS: a hardware keyboard can hold shift, but there is
/// no UIKit equivalent of `NSEvent.modifierFlags` to poll outside an event, and the
/// long press on a row's **number margin** in `DocumentReaderView` is the touch
/// affordance that replaces shift-click anyway. The margin rather than anywhere in the
/// row, because the prose is selectable text and a long press on it belongs to the
/// system's character selection.
var isShiftKeyDown: Bool {
    #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
    #else
        false
    #endif
}

/// Writes the pasteboard directly.
///
/// macOS otherwise copies through `.onCopyCommand`, which hands the responder chain an
/// `NSItemProvider` rather than writing the pasteboard itself — but a menu item is not a
/// responder-chain command, so the word-lookup menu's Copy needs this on both platforms.
/// `clearContents()` first, because `NSPasteboard` appends to whatever the last owner left.
func copyToPasteboard(_ text: String) {
    #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    #else
        UIPasteboard.general.string = text
    #endif
}

/// Whether MLX has a GPU to talk to.
///
/// `false` only on the iOS Simulator, and the reason this has to be asked *before* the
/// fact rather than caught after is that the failure is not recoverable. The first touch
/// of any `MLX.Memory` knob constructs `mlx::core::metal::Device`, which on the Simulator
/// calls `abort()` from C++ by way of `std::__libcpp_verbose_abort`, where no Swift
/// `catch` and no `LoadState.failed` can reach it. Unguarded, the app does not merely
/// fail to annotate on the Simulator: it dies on launch, taking the reader, the corpus
/// and every bit of layout that has nothing to do with the model down with it.
///
/// So the load refuses early and says so in the header instead, which leaves the
/// Simulator good for the UI work it is actually good for.
var hasMLXDevice: Bool {
    #if targetEnvironment(simulator)
        false
    #else
        true
    #endif
}

extension View {
    /// Prose the reader can select characters in, on both platforms.
    ///
    /// A shim rather than `.textSelection(.enabled)` at each of the three call sites, because
    /// the *interesting* fact is which text is **not** selectable — a heading, which is a
    /// handle rather than prose — and naming that requires naming this.
    ///
    /// What it took to get here is worth recording, because the obvious diagnosis was wrong
    /// twice. Turning selection on collided with the row sweep: one long press on a phone
    /// produced grab handles *and* a five-row selection band, two selections of two different
    /// things from one gesture. It also looked as though selectable text had broken scrolling —
    /// a slow drag over the prose selected characters and moved the document not one point.
    /// It had not. With selection turned back off the same drag still failed to scroll, and
    /// still swept rows: the culprit was `SweepRecognizer`'s own long press, which a synthesized
    /// drag arms because it dwells at its start point where a finger keeps moving. Scrolling was
    /// never the text's fault, and the arbitration in `DocumentReaderView` is what fixes the
    /// collision that was.
    func selectableProse() -> some View {
        textSelection(.enabled)
    }

    /// `Menu` ignores `.buttonStyle(.borderless)`, hence `.menuStyle` on macOS. And
    /// `BorderlessButtonMenuStyle` is macOS-only, so iOS keeps the default style and
    /// takes the indicator alone. In a navigation bar the default style is already
    /// the borderless one.
    func borderlessMenu() -> some View {
        #if os(macOS)
            menuStyle(.borderlessButton).menuIndicator(.hidden)
        #else
            menuIndicator(.hidden)
        #endif
    }
}

extension AttributedString {
    /// Sets a hover tooltip on a run, where the platform has hovering.
    ///
    /// `AttributeScopes.AppKitAttributes.toolTip` is macOS-only, which is right — a phone
    /// has no pointer to hover with — so this is a no-op on iOS. A shim rather than an
    /// `#if` at each of the four call sites, all of which are in `Text`-based views that
    /// are otherwise identical on both platforms.
    ///
    /// What this means for iOS is worth being plain about: the citation chips' tooltips
    /// explain *why* an unretrieved citation does not click, and a phone reader does not
    /// get that explanation. There is no per-run accessibility label on `AttributedString`
    /// to put it in instead. The verdict is still visible — the chip is grey and does not
    /// respond — but the reason is macOS-only until there is somewhere to say it.
    mutating func setToolTip(_ text: String, on range: Range<AttributedString.Index>) {
        #if os(macOS)
            self[range].toolTip = text
        #endif
    }
}
