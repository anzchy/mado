import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MadoApplication
import MadoCore

public enum InspectorPanelLayout {
    public static func width(for windowWidth: CGFloat) -> CGFloat {
        if windowWidth <= 720 { return 220 }
        if windowWidth <= 1050 { return 195 }
        return 220
    }
    public static func overlaysContent(at windowWidth: CGFloat) -> Bool { windowWidth <= 720 }
    public static func labelWidth(_ label: String) -> CGFloat {
        48 // pages 16/34: .inspector dl grid-template-columns: 48px 1fr
    }
    public static func labelWidth(_ labels: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12)
        let widest = labels.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        return max(48, widest)
    }
    public static func frame(in bounds: NSRect, grid: Bool) -> NSRect {
        let width = min(Self.width(for: bounds.width), bounds.width)
        if overlaysContent(at: bounds.width) {
            return NSRect(x: bounds.maxX - width, y: bounds.minY + 38,
                          width: width, height: max(0, bounds.height - 125))
        }
        return NSRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height)
    }
}

/// A single Inspector metadata row shared by the English and Chinese panels.
struct InspectorFieldRow: View {
    let label: String
    let value: String
    let id: String
    let columnWidth: CGFloat?
    init(label: String, value: String, id: String, columnWidth: CGFloat? = nil) {
        self.label = label; self.value = value; self.id = id; self.columnWidth = columnWidth
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(label).foregroundStyle(DesignColor.textSecondary.color)
                .frame(width: columnWidth ?? InspectorPanelLayout.labelWidth(label), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            // Keep the pinned 7 pt gap; the panel shares a measured localized label column.
            Text(value).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DesignColor.textPrimary.color).multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("inspector.\(id)")
        }
        .font(.system(size: 12))
    }
}

/// Pages 16/34 share the same hierarchy; DesignColor resolves the window appearance.
public struct InspectorPanel: View {
    static func shouldFocusCloseButton(_ focus: FocusContext, allows: Bool) -> Bool {
        focus == .panel || (focus == .textInput && allows)
    }
    @Bindable public var model: InspectorModel
    public let session: ViewerSession
    let translations: [String: String]
    public let topInset: CGFloat
    public let close: () -> Void
    public let restoreCanvasFocus: () -> Void
    public let updateFocus: (FocusContext) -> Void
    public let allowsCloseFocus: () -> Bool

    public init(model: InspectorModel, session: ViewerSession, translations: [String: String] = [:],
                topInset: CGFloat = 0,
                close: @escaping () -> Void,
                restoreCanvasFocus: @escaping () -> Void, updateFocus: @escaping (FocusContext) -> Void,
                allowsCloseFocus: @escaping () -> Bool = { true }) {
        self.model = model; self.session = session; self.translations = translations; self.close = close
        self.topInset = topInset
        self.restoreCanvasFocus = restoreCanvasFocus; self.updateFocus = updateFocus
        self.allowsCloseFocus = allowsCloseFocus
    }

    private func localized(_ key: String) -> String {
        if let translated = translations[key] { return translated }
        switch key {
        case "Image Information": return String(localized: "Image Information")
        case "Dimensions": return String(localized: "Dimensions")
        case "Type": return String(localized: "Type")
        case "Created": return String(localized: "Created")
        case "Modified": return String(localized: "Modified")
        case "Size": return String(localized: "Size")
        case "Unknown": return String(localized: "Unknown")
        case "Loading…": return String(localized: "Loading…")
        case "No Permission": return String(localized: "No Permission")
        case "Unreadable": return String(localized: "Unreadable")
        default: return key
        }
    }

    private var unavailable: String {
        switch model.value {
        case .loading: localized("Loading…")
        case .noPermission: localized("No Permission")
        case .unreadable: localized("Unreadable")
        case .unknown, .known: localized("Unknown")
        }
    }
    private func field(_ value: String?) -> String { value ?? unavailable }
    private var metadata: InspectorMetadata? {
        if case .known(let value) = model.value { value } else { nil }
    }
    static func typeName(_ identifier: String) -> String {
        if let ext = UTType(identifier)?.preferredFilenameExtension { return ext.uppercased() }
        return identifier
    }
    private var labelColumnWidth: CGFloat {
        InspectorPanelLayout.labelWidth(["Dimensions", "Type", "Created", "Modified", "Size"].map(localized))
    }
    private func row(_ label: String, _ value: String, id: String) -> some View {
        InspectorFieldRow(label: label, value: value, id: id, columnWidth: labelColumnWidth)
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: localized("Image Information")).font(.system(size: 13, weight: .medium))
                Spacer()
                InspectorCloseControl(focused: Self.shouldFocusCloseButton(session.inspectorFocus.focus,
                    allows: allowsCloseFocus()),
                    close: close, updateFocus: updateFocus, restoreCanvasFocus: restoreCanvasFocus)
                    .frame(width: 24, height: 24)
            }
            .frame(height: 36)
            .padding(.bottom, 12)
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(DesignColor.sidebarBackground.color)
                if let data = metadata?.thumbnailData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .accessibilityLabel(Text("Image Preview"))
                } else {
                    Image(systemName: "photo").foregroundStyle(DesignColor.textSecondary.color)
                }
            }
            .frame(height: 120)
            .accessibilityIdentifier("inspector.preview")
            Text(verbatim: model.name ?? unavailable)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignColor.textPrimary.color)
                .lineLimit(2).truncationMode(.middle)
                .padding(.top, 14)
                .accessibilityIdentifier("inspector.item-name")
            VStack(spacing: 13) {
                row(localized("Dimensions"), field(metadata.flatMap { value in
                    guard let w = value.pixelWidth, let h = value.pixelHeight else { return nil }
                    return "\(w) × \(h)"
                }), id: "dimensions")
                row(localized("Type"), field(metadata?.typeIdentifier.map(Self.typeName)), id: "type")
                row(localized("Created"), field(metadata?.creationDate?.formatted(date: .numeric, time: .omitted)), id: "created")
                row(localized("Modified"), field(metadata?.modificationDate?.formatted(date: .numeric, time: .omitted)), id: "modified")
                row(localized("Size"), field(metadata?.byteSize.map {
                    ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                }), id: "size")
            }
            .padding(.top, 19)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17)
        .padding(.top, topInset)
        .padding(.bottom, 18)
        .frame(minWidth: 0, idealWidth: 220, maxWidth: .infinity)
        .background(DesignColor.canvasBackground.color)
        .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 8)
        .overlay(alignment: .leading) { Rectangle().fill(DesignColor.divider.color).frame(width: 1) }
    }
}

private final class InspectorFocusButton: NSButton {
    var onFocus: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

private struct InspectorCloseControl: NSViewRepresentable {
    let focused: Bool
    let close: () -> Void
    let updateFocus: (FocusContext) -> Void
    let restoreCanvasFocus: () -> Void

    final class Coordinator: NSObject {
        var close: () -> Void = {}
        @objc func performClose() { close() }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> InspectorFocusButton {
        let button = InspectorFocusButton()
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        button.isBordered = false
        button.focusRingType = .exterior
        button.setAccessibilityLabel(String(localized: "Close Inspector"))
        button.setAccessibilityIdentifier("inspector.close")
        button.target = context.coordinator
        button.action = #selector(Coordinator.performClose)
        return button
    }
    func updateNSView(_ button: InspectorFocusButton, context: Context) {
        context.coordinator.close = close
        button.onFocus = { updateFocus(.panel) }
        if focused, button.window?.firstResponder !== button {
            button.window?.makeFirstResponder(button)
        } else if !focused, button.window?.firstResponder === button {
            restoreCanvasFocus()
        }
    }
}
