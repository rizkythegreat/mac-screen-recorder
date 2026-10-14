import SwiftUI

/// Shared chrome; the recording's own canvas styling is independent of the editor.
enum StudioTheme {
    static let accent = Color(red: 0.63, green: 0.56, blue: 0.88)
    static let canvas = Color(red: 0.075, green: 0.078, blue: 0.086)
    static let surface = Color(red: 0.105, green: 0.109, blue: 0.121)
    static let raised = Color(red: 0.145, green: 0.149, blue: 0.165)
    static let line = Color.white.opacity(0.075)
}

struct Panel<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            content
                .font(.system(size: 12))
                .controlSize(.small)
        }
        .padding(.horizontal, 18).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { StudioTheme.line.frame(height: 1) }
    }
}

struct StudioToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        ToolbarLabel(configuration: configuration, enabled: enabled)
    }

    private struct ToolbarLabel: View {
        let configuration: ButtonStyle.Configuration
        let enabled: Bool
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(enabled ? Color.white.opacity(0.85) : Color.white.opacity(0.24))
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(enabled ? (configuration.isPressed ? 0.12 : hovering ? 0.06 : 0) : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onHover { hovering = $0 }
        }
    }
}
