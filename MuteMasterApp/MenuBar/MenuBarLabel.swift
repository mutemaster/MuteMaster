//
//  MenuBarLabel.swift
//  The icon shown in the system menu bar (next to the clock). Two SF Symbols reflect live state:
//  microphone (input) and speaker (output), each switching to its "slash" variant when muted.
//
//  The menu-bar status item only reliably renders a SINGLE view as its label: an HStack of two
//  Images shows just the first glyph, and two inline images in a Text render blank on some macOS
//  versions. So we rasterize the two-symbol HStack into ONE template NSImage with ImageRenderer
//  and hand that to MenuBarExtra — both icons then appear, and `isTemplate` lets the system tint
//  them to match the menu bar (light/dark).
//

import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        Image(nsImage: Self.renderIcon(inputMuted: state.inputMuted, outputMuted: state.outputMuted))
            .renderingMode(.template)
    }

    @MainActor
    private static func renderIcon(inputMuted: Bool, outputMuted: Bool) -> NSImage {
        // Active  → bold FILLED disc (.circle.fill): a solid circle with the glyph knocked out.
        // Muted   → thin OUTLINE circle + slash (.slash.circle): the filled/hollow inversion makes
        //           the muted state obvious at a glance.
        let mic = inputMuted ? "mic.slash.circle" : "mic.circle.fill"
        let speaker = outputMuted ? "speaker.slash.circle" : "speaker.wave.2.circle.fill"

        let content = HStack(spacing: 1.5) {   // gap between glyphs == glyph-to-pill padding below
            Image(systemName: mic)
            Image(systemName: speaker)
        }
        .font(.system(size: 17))   // full, readable glyph size
        // Equal padding on all sides puts each glyph's center on the capsule end-cap's arc center,
        // so the gap is even all the way around the rounded ends. Kept tight (1.5pt) so the pill
        // hugs the icons and the whole thing still fits the menu-bar height.
        .padding(1.5)
        .foregroundStyle(.black)   // template uses alpha only; color is irrelevant
        // Thin pill outline grouping the two icons. strokeBorder draws inside the bounds so the
        // line isn't clipped by the rendered image edges.
        .overlay(Capsule().strokeBorder(.black, lineWidth: 1.0))

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true    // adapt to menu-bar appearance
        return image
    }
}
