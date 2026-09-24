import SwiftUI

// MARK: - Bridging Optional Settings to Controls

/// Sliders/steppers need non-optional bindings; settings keep `nil` for
/// "Ghostty default". Prefer explicit per-control bindings (a generic
/// bridge trips Sendable warnings); this helper stays only as
/// documentation of the pattern.
// NOTE: intentionally no generic helper here — see FontPane for the
// explicit optional-slider pattern.

// MARK: - Picking Optional Theme Colors

/// A color well bound to an optional hex override: picking sets the
/// override, Default clears it back to the preset color.
struct HexColorRow: View {
    var title: String
    var hex: Binding<String?>
    var fallbackHex: String

    var body: some View {
        HStack {
            ColorPicker(title, selection: colorBinding, supportsOpacity: false)
            Spacer()
            Text(shortCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fontDesign(.monospaced)
            Button("Default") { hex.wrappedValue = nil }
                .disabled(hex.wrappedValue == nil)
        }
        .help(hex.wrappedValue == nil ? "\(title): preset color" : "\(title): override \(hex.wrappedValue ?? "")")
    }

    private var shortCaption: String {
        if let h = EngineSettings.normalizedHex(hex.wrappedValue) { return h }
        return EngineSettings.normalizedHex(fallbackHex) ?? "—"
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                EngineSettings.color(fromHex: hex.wrappedValue ?? "")
                    ?? EngineSettings.color(fromHex: fallbackHex)
                    ?? Color.gray
            },
            set: { hex.wrappedValue = EngineSettings.hex(from: $0) }
        )
    }
}

// MARK: - Explaining Settings

/// Quiet caption under a control.
struct SettingNote: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
