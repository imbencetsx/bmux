import SwiftUI

/// Shared presets retain their original hex values so existing accents match.
struct WorkspaceAccent: Identifiable {
    let name: String
    let hex: String

    var id: String { hex }
    var color: Color { EngineSettings.color(fromHex: hex) ?? .gray }

    static let all: [WorkspaceAccent] = [
        .init(name: "Blue", hex: "#4DA3FF"),
        .init(name: "Teal", hex: "#2DD4BF"),
        .init(name: "Green", hex: "#7ED957"),
        .init(name: "Yellow", hex: "#F7C948"),
        .init(name: "Orange", hex: "#FF9F43"),
        .init(name: "Pink", hex: "#F472B6"),
        .init(name: "Purple", hex: "#A78BFA"),
        .init(name: "Red", hex: "#FF6B6B"),
        .init(name: "Cyan", hex: "#5AC8FA"),
        .init(name: "Indigo", hex: "#787AFF"),
        .init(name: "Brown", hex: "#AC8E68"),
        .init(name: "Gray", hex: "#98989D"),
        .init(name: "White", hex: "#FFFFFF"),
        .init(name: "Black", hex: "#000000"),
    ]
}

/// Preset swatches and the native macOS color well, backed by one selection.
struct WorkspaceColorPicker: View {
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 8)], spacing: 8) {
                swatch("No color", color: Color(nsColor: .controlBackgroundColor), hex: nil)
                ForEach(WorkspaceAccent.all) { accent in
                    swatch(accent.name, color: accent.color, hex: accent.hex)
                }
            }

            Divider()

            ColorPicker("Custom color", selection: customColor, supportsOpacity: false)
                .help("Choose any color using the macOS color picker")

            Text(selectionDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func swatch(_ name: String, color: Color, hex: String?) -> some View {
        let selected = selection?.uppercased() == hex?.uppercased()
        return Button {
            selection = hex
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
                    .overlay {
                        if hex == nil {
                            Image(systemName: "slash.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(4)
                    .overlay(Circle().strokeBorder(.primary, lineWidth: selected ? 2 : 0))
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(selected ? "\(name) (current)" : name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { EngineSettings.color(fromHex: selection ?? "") ?? .accentColor },
            set: { selection = EngineSettings.hex(from: $0) }
        )
    }

    private var selectionDescription: String {
        guard let selection else { return "No color · hides the workspace stripe" }
        let name = WorkspaceAccent.all.first { $0.hex.caseInsensitiveCompare(selection) == .orderedSame }?.name ?? "Custom"
        return "\(name) · \(selection.uppercased())"
    }
}

/// Resolve the current workspace on every read, including native color-panel edits.
struct WorkspaceColorControls: View {
    @EnvironmentObject private var manager: WorkspaceManager
    let workspaceID: UUID

    var body: some View {
        WorkspaceColorPicker(selection: Binding(
            get: { manager.workspaces.first { $0.id == workspaceID }?.colorHex },
            set: { manager.setColor(workspaceID, to: $0) }
        ))
    }
}

struct WorkspaceColorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Workspace color").font(.headline)
                Text(workspace.name).foregroundStyle(.secondary)
            }
            WorkspaceColorControls(workspaceID: workspace.id)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
