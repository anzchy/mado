import SwiftUI

/// The panel's content (CACHE-04, native exception): design tokens for type, spacing and colour.
public struct DiagnosticsPanelView: View {
    let model: DiagnosticsPanelModel
    public init(model: DiagnosticsPanelModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignMetrics.spacing[4]) {
                ForEach(model.sections) { section in
                    VStack(alignment: .leading, spacing: DesignMetrics.spacing[1]) {
                        Self.sectionTitle(section.title)
                        ForEach(section.rows) { row in
                            HStack(spacing: DesignMetrics.spacing[2]) {
                                Text(LocalizedStringKey(row.title))
                                    .foregroundStyle(DesignColor.textSecondary.color)
                                Spacer(minLength: DesignMetrics.spacing[2])
                                value(row.value)
                                    .monospacedDigit()
                                    .foregroundStyle(DesignColor.textPrimary.color)
                            }
                            .font(Font(DesignMetrics.font("ui")))
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("diagnostics.\(row.id)")
                        }
                        if let note = section.note {
                            Text(LocalizedStringKey(note))
                                .font(Font(DesignMetrics.font("uiSmall")))
                                .foregroundStyle(DesignColor.textSecondary.color)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("diagnostics.\(section.id).note")
                        }
                    }
                }
            }
            .padding(DesignMetrics.spacing[3])
        }
        .frame(minWidth: 300, minHeight: 360)
        .background(DesignColor.popoverBackground.color)
    }

    /// A heading for VoiceOver's heading navigation.
    static func sectionTitle(_ title: String) -> some View {
        Text(LocalizedStringKey(title))
            .font(Font(DesignMetrics.font("uiLarge")).weight(.semibold))
            .foregroundStyle(DesignColor.textPrimary.color)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(Text(LocalizedStringKey(title)))
    }

    /// Only the Unknown marker is a localization key; counts and sizes are already formatted.
    private func value(_ text: String) -> Text {
        text == DiagnosticsPanelModel.unknown ? Text(LocalizedStringKey(text)) : Text(verbatim: text)
    }
}
