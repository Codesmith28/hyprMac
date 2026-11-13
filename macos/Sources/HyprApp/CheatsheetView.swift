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
            .padding(.vertical, 4)
            if !extras.isEmpty { extrasSection }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 720)
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

    /// Opt-in actions and mouse gestures: compact cells, no animation. Keycaps when bound, the
    /// `keys.<name>` to set in init.lua when not.
    private var extrasSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 6) {
                Text("More").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text("· keys.* entries are unbound: set them in init.lua")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .leading), count: 3),
                      alignment: .leading, spacing: 4) {
                ForEach(extras) { ExtraCell(extra: $0) }
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 10)
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
        .padding(.horizontal, 16).padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue(entry.keys.map { $0.joined(separator: " ") }.joined(separator: ", or "))
    }
}

private struct ExtraCell: View {
    let extra: CheatsheetExtra

    var body: some View {
        HStack(spacing: 3) {
            Text(extra.title).font(.system(size: 11.5)).foregroundStyle(unbound ? .secondary : .primary).lineLimit(1)
            Spacer(minLength: 6)
            switch extra.binding {
            case .keys(let caps):
                ForEach(Array(caps.enumerated()), id: \.offset) { _, c in KeyCap(c, compact: true) }
            case .unbound(let key):
                Text("keys.\(key)").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
            case .gesture(let how):
                Text(how).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(minHeight: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(extra.title)
        .accessibilityValue(value)
    }

    private var unbound: Bool { if case .unbound = extra.binding { true } else { false } }

    private var value: String {
        switch extra.binding {
        case .keys(let caps): caps.joined(separator: " ")
        case .unbound(let key): "unbound, set keys.\(key) in init.lua"
        case .gesture(let how): how
        }
    }
}

struct KeyCap: View {
    let text: String
    let compact: Bool
    init(_ text: String, compact: Bool = false) { self.text = text; self.compact = compact }

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 10 : 11, weight: .medium, design: .rounded))
            .frame(minWidth: compact ? 18 : 22, minHeight: compact ? 18 : 22)
            .padding(.horizontal, text.count > 1 ? 5 : 0)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
    }
}
