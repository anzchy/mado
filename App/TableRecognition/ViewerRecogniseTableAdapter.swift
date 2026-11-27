import AppKit
import MadoApplication
import MadoCore

/// View › 识别表格… on the viewer's image (#874): the consent sheet naming the real host, the working sheet with
/// Cancel, and the result panel. One adapter per viewer window; the flow model owns the rules.
@MainActor final class ViewerRecogniseTableAdapter {
    typealias FlowFactory = @MainActor (any TableClipboardWriting, @escaping @MainActor () -> Void) -> RecogniseTableFlow
    weak var controller: CanvasWindowController?
    var pasteboard: NSPasteboard = .general
    /// The App's settings, keychain, transport and consent store; tests inject fakes.
    var makeFlow: FlowFactory = { _, _ in fatalError("stub") }
    var presentConsent: @MainActor (NSWindow?, NSAlert, @escaping @MainActor (Bool) -> Void) -> Void = { _, _, _ in }
    var presentWorking: @MainActor (NSWindow?, NSAlert, @escaping @MainActor () -> Void) -> Void = { _, _, _ in }
    var dismissWorking: @MainActor (NSWindow?, NSAlert) -> Void = { _, _ in }
    var presentNotice: @MainActor (NSWindow?, NSAlert) -> Void = { _, _ in }
    private(set) var flow: RecogniseTableFlow?
    private(set) var panel: RecognisedTablePanel?
    private(set) var runTask: Task<Void, Never>?

    init(controller: CanvasWindowController) { self.controller = controller }

    var canStart: Bool { false }
    func start() {}

    static func consentAlert(host: String) -> NSAlert { NSAlert() }
    static func workingAlert(host: String) -> NSAlert { NSAlert() }
    static func noticeAlert(for state: RecogniseTableState) -> NSAlert? { nil }
}

extension CanvasWindowController {
    var canRecogniseTableFromMenu: Bool { recogniseTableAdapter.canStart }
    func recogniseTable() { recogniseTableAdapter.start() }
}
