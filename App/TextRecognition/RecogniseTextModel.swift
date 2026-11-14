import Foundation
import MadoApplication

@MainActor
protocol TextPasteboardWriting: AnyObject {
    @discardableResult func copy(_ text: String) -> Bool
}

enum RecogniseTextNotice: Equatable {
    case copied(count: Int, engine: TextRecognitionEngine)
    case noText
    case failed
}

@MainActor
final class RecogniseTextModel {
    private(set) var notice: RecogniseTextNotice?
    private(set) var panelText: String?
    private(set) var engine: TextRecognitionEngine?
    private(set) var copiedConfirmation = false
    private(set) var isRunning = false
    private var recognisedText: String?
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private var confirmationGeneration = UUID()
    private var closed = false
    private let recognise: @Sendable (Data) async throws -> TextRecognitionResult
    private let pasteboard: TextPasteboardWriting
    private let isCurrent: @MainActor (UUID) -> Bool
    private let onChange: @MainActor () -> Void
    private let scheduleConfirmationReset: (@escaping @MainActor () -> Void) -> Void

    init(recognise: @escaping @Sendable (Data) async throws -> TextRecognitionResult,
         pasteboard: TextPasteboardWriting,
         isCurrent: @escaping @MainActor (UUID) -> Bool,
         onChange: @escaping @MainActor () -> Void = {},
         scheduleConfirmationReset: @escaping (@escaping @MainActor () -> Void) -> Void = { action in
             Task { try? await Task.sleep(for: .seconds(2)); action() }
         }) {
        self.recognise = recognise
        self.pasteboard = pasteboard
        self.isCurrent = isCurrent
        self.onChange = onChange
        self.scheduleConfirmationReset = scheduleConfirmationReset
    }

    @discardableResult func start(_ image: Data, identity: UUID) -> Task<Void, Never> {
        task?.cancel()
        runID = UUID()
        let thisRun = runID
        closed = false
        notice = nil
        panelText = nil
        recognisedText = nil
        engine = nil
        copiedConfirmation = false
        confirmationGeneration = UUID()
        isRunning = true
        onChange()
        let recognise = self.recognise
        let next = Task { [weak self] in
            defer {
                if let self, self.runID == thisRun {
                    self.isRunning = false
                    self.onChange()
                }
            }
            do {
                let result = try await recognise(image)
                guard let self, !Task.isCancelled, !self.closed,
                      self.runID == thisRun, self.isCurrent(identity) else { return }
                if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.notice = .noText
                } else {
                    if self.pasteboard.copy(result.text) {
                        self.recognisedText = result.text
                        self.engine = result.engine
                        self.notice = .copied(count: result.text.count, engine: result.engine)
                    } else {
                        self.notice = .failed
                    }
                }
            } catch {
                guard let self, !Task.isCancelled, !self.closed,
                      self.runID == thisRun, self.isCurrent(identity) else { return }
                if error is CancellationError || (error as? TextRecognitionError) == .cancelled {
                    self.notice = nil
                } else {
                    self.notice = .failed
                }
            }
        }
        task = next
        return next
    }

    func close() {
        closed = true
        runID = UUID()
        task?.cancel(); task = nil
        isRunning = false
        notice = nil
        panelText = nil
        recognisedText = nil
        engine = nil
        confirmationGeneration = UUID()
        onChange()
    }
    func openPanel() {
        guard case .copied = notice, let recognisedText else { return }
        panelText = recognisedText
        notice = nil
        onChange()
    }
    func closePanel() {
        panelText = nil
        copiedConfirmation = false
        confirmationGeneration = UUID()
        onChange()
    }
    func dismissNotice() {
        notice = nil
        onChange()
    }
    func edit(_ text: String) {
        guard panelText != nil else { return }
        panelText = text
        copiedConfirmation = false
        confirmationGeneration = UUID()
        onChange()
    }
    func copyEditedText() {
        guard let panelText else { return }
        guard pasteboard.copy(panelText) else { return }
        copiedConfirmation = true
        confirmationGeneration = UUID()
        let generation = confirmationGeneration
        scheduleConfirmationReset { [weak self] in
            guard let self, self.confirmationGeneration == generation, self.panelText != nil else { return }
            self.copiedConfirmation = false
            self.onChange()
        }
        onChange()
    }
}
