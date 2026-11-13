import SwiftUI

/// The cheatsheet card: one row per shortcut — animation, name, keycaps.
struct CheatsheetView: View {
    let entries: [CheatsheetEntry]
    let extras: [CheatsheetExtra]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                    CheatsheetRow(entry: entry)
                    if i < entries.count - 1 { Divider().opacity(0.3).padding(.leading, 120) }
                }
            }
            .padding(.vertical, 6)
            if !extras.isEmpty { extrasSection }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 600)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard shortcuts")
    }

    private var header: some View {
        HStack {
            Text("Keyboard Shortcuts").font(.system(size: 15, weight: .semibold))
            Spacer()
            Text("hyprMac").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    /// Bound opt-in actions (resize, zoom, …): compact rows, no animation.
    private var extrasSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().opacity(0.5)
            Text("Also bound").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 4)
            ForEach(extras) { extra in
                HStack(spacing: 4) {
                    Text(extra.title).font(.system(size: 12))
                    Spacer(minLength: 12)
                    ForEach(Array(extra.keys.enumerated()), id: \.offset) { _, c in KeyCap(c) }
                }
                .padding(.leading, 20).padding(.trailing, 16).padding(.vertical, 3)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(extra.title)
                .accessibilityValue(extra.keys.joined(separator: " "))
            }
        }
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("Press").foregroundStyle(.secondary)
            KeyCap("Esc")
            Text("to close · change shortcuts in init.lua").foregroundStyle(.secondary)
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 20).padding(.vertical, 10)
    }
}

private struct CheatsheetRow: View {
    let entry: CheatsheetEntry

    var body: some View {
        HStack(spacing: 16) {
            ShortcutIllustration(kind: entry.illustration)
                .frame(width: 88, height: 56)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.system(size: 13, weight: .medium))
                Text(entry.detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 5) {
                ForEach(Array(entry.keys.enumerated()), id: \.offset) { _, caps in
                    HStack(spacing: 4) {
                        ForEach(Array(caps.enumerated()), id: \.offset) { _, c in KeyCap(c) }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue(entry.keys.map { $0.joined(separator: " ") }.joined(separator: ", or "))
    }
}

struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, text.count > 1 ? 5 : 0)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
    }
}
