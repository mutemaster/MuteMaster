//
//  AcknowledgementsView.swift
//  Shows the bundled THIRD-PARTY-NOTICES.md so the required open-source license notices travel with
//  the distributed app (not just the repo). Opened from the menu in its own window.
//
//  Like the shortcuts window, it flips the activation policy to .regular while open so this
//  menu-bar (accessory) app can show a focusable, scrollable window, then back to .accessory.
//

import SwiftUI
import AppKit

struct AcknowledgementsView: View {
    @State private var text: String = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "No notices found." : text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .frame(width: 580, height: 460)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            loadNotices()
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    private func loadNotices() {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        text = contents
    }
}
