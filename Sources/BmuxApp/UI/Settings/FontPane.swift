import AppKit
import SwiftUI

// MARK: - Picking Fonts

/// Monospaced family list (filtered from installed fonts), live preview,
/// size slider, synthetic-bold controls. Family "" and size nil both mean
/// Ghostty defaults — the engine keys are omitted, never zeroed.
struct FontPane: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var query: String = ""

    private static let previewSize: CGFloat = 15
    private static let previewText = "Agile zebras vex $SHELL -l // 0123456789"

    var body: some View {
        Form {
            Section("Family") {
                TextField("Search fonts", text: $query)
                    .textFieldStyle(.roundedBorder)
                List(selection: familySelection) {
                    Text("System Default")
                        .tag("")
                    ForEach(filteredFamilies, id: \.self) { family in
                        Text(family)
                            .font(Font(MonospaceFonts.nsFont(family: family, size: 12)))
                            .tag(family)
                    }
                }
                .frame(minHeight: 180)
                SettingNote(text: "Monospaced families only. Empty search shows all \(MonospaceFonts.cachedFamilies.count).")
            }

            Section("Preview") {
                Text(Self.previewText)
                    .font(Font(MonospaceFonts.nsFont(family: settings.current.fontFamily, size: previewPointSize)))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: .rect(cornerRadius: 8))
                    .textSelection(.enabled)
            }

            Section("Size") {
                Toggle("Custom size", isOn: customSizeEnabled)
                HStack {
                    Text("Size")
                    Slider(
                        value: Binding(
                            get: { Double(settings.current.fontSize ?? 12) },
                            set: { settings.current.fontSize = Float($0) }
                        ),
                        in: 8...32, step: 0.5
                    )
                    .disabled(settings.current.fontSize == nil)
                    Text(sizeCaption)
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
            }

            Section("Weight") {
                Toggle("Thicken strokes (synthetic bold)", isOn: $settings.current.fontThicken)
                HStack {
                    Text("Strength")
                    Slider(
                        value: thickenStrength,
                        in: 0...255, step: 1
                    )
                    .disabled(!settings.current.fontThicken)
                    Button("Default") { settings.current.fontThickenStrength = nil }
                        .disabled(settings.current.fontThickenStrength == nil)
                }
                SettingNote(text: settings.current.fontThickenStrength == nil
                    ? "Strength: Ghostty default."
                    : "Strength: \(settings.current.fontThickenStrength ?? 0).")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Font")
        .padding()
    }

    // MARK: - Bindings

    private var familySelection: Binding<String> {
        Binding(
            get: { settings.current.fontFamily },
            set: { settings.current.fontFamily = $0 }
        )
    }

    private var filteredFamilies: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return MonospaceFonts.cachedFamilies }
        return MonospaceFonts.cachedFamilies.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    private var previewPointSize: CGFloat {
        CGFloat(settings.current.fontSize ?? 13)
    }

    private var sizeCaption: String {
        if let size = settings.current.fontSize { return String(format: "%.1f pt", size) }
        return "Default"
    }

    private var customSizeEnabled: Binding<Bool> {
        Binding(
            get: { settings.current.fontSize != nil },
            set: { settings.current.fontSize = $0 ? 12 : nil }
        )
    }

    private var thickenStrength: Binding<Double> {
        Binding(
            get: { Double(settings.current.fontThickenStrength ?? 255) },
            set: { settings.current.fontThickenStrength = Int($0.rounded()) }
        )
    }
}

// MARK: - Picking Cursor Shapes

struct CursorPane: View {
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        Form {
            Section("Shape") {
                Picker("Style", selection: $settings.current.cursorStyle) {
                    ForEach(CursorStyleSetting.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Blink", isOn: $settings.current.cursorBlink)
            }

            Section("Opacity") {
                HStack {
                    Text("Cursor opacity")
                    Slider(value: $settings.current.cursorOpacity, in: 0...1, step: 0.01)
                    Text("\(Int((settings.current.cursorOpacity * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                SettingNote(text: "0% hides the cursor entirely.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Cursor")
        .padding()
    }
}

// MARK: - Listing Monospaced Fonts

/// Installed families filtered to fixed-pitch members. Computed once —
/// `availableMembers` is not cheap.
enum MonospaceFonts {
    static let cachedFamilies: [String] = compute()

    static func nsFont(family: String, size: CGFloat) -> NSFont {
        let trimmed = family.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let font = NSFont(name: trimmed, size: size) {
            return font
        }
        if !trimmed.isEmpty, let font = NSFontManager.shared.font(
            withFamily: trimmed, traits: [], weight: 5, size: size
        ) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func compute() -> [String] {
        var out: [String] = []
        let mask = NSFontTraitMask.fixedPitchFontMask.rawValue
        for family in NSFontManager.shared.availableFontFamilies {
            let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
            let fixed = members.contains { member in
                guard member.count > 3, let traits = member[3] as? NSNumber else { return false }
                return traits.uintValue & mask != 0
            }
            if fixed { out.append(family) }
        }
        for staple in ["SF Mono", "Menlo", "Monaco", "Courier New"] {
            if !out.contains(staple), NSFontManager.shared.availableFontFamilies.contains(staple) {
                out.append(staple)
            }
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// MARK: - Binding Numeric Sliders

private extension Binding where Value == Float {
    /// Sliders speak Double; the setting is Float.
    func asDouble() -> Binding<Double> {
        Binding<Double>(
            get: { Double(wrappedValue) },
            set: { wrappedValue = Float($0) }
        )
    }
}
