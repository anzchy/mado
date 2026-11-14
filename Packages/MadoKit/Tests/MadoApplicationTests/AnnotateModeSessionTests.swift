import CoreGraphics
import Foundation
import Testing
import MadoCore
@testable import MadoApplication

// #690 (P7-11) WI-4: Annotate Mode in the Session — entry, browsing off, leaving with unsaved marks, saving.

@MainActor private final class AnnotateHost: AnnotateSaveHost {
    var hasImage = true
    var saves: [AnnotateSaveRequest] = []
    var presented: [ItemID] = []
    var returnedToGrid = 0
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? { nil }
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    var inspector: [Bool] = []
    func showInspector(_ visible: Bool) { inspector.append(visible) }
    func presentGridItem(_ id: ItemID) { presented.append(id) }
    func returnToGrid() { returnedToGrid += 1 }
    func performAnnotatedCopySave(_ request: AnnotateSaveRequest) { saves.append(request) }
}

@MainActor private struct Showing {
    let session: ViewerSession
    let host: AnnotateHost
    let loadHost: LoadHost
    let ids: [ItemID]
    let router = CommandRouter(implementedCommands: Set(CommandID.allCases))
    static let url = URL(fileURLWithPath: "/photos/photo.jpg")
    /// The Session holds its hosts weakly; tests that keep only the Session still need them.
    static var keepAlive: [AnyObject] = []

    /// A folder Preview Set on ids[1], its image settled (`.showing`).
    static func make() async -> Showing {
        let host = AnnotateHost(), loadHost = LoadHost()
        let session = ViewerSession(host: host)
        session.imageLoader.host = loadHost
        let ids = sessionItems()
        session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: nil)
        session.select(ids[1])
        CommandRouter(implementedCommands: Set(CommandID.allCases)).route(.preview, from: .key, to: session)
        session.openImage(url, maximumPixelSize: 512) {
            try await AccessImageSource.open(.fileGrant(url), access: LoadLeases(), pipeline: LoadPipeline())
        }
        await session.imageLoader.loadTask?.value
        keepAlive += [host, loadHost]
        return Showing(session: session, host: host, loadHost: loadHost, ids: ids)
    }
}

private func mk(_ i: Int) -> AnnotationMark { AnnotationMark(rect: CGRect(x: i, y: i, width: 10, height: 10)) }

private let browsingCommands: Set<CommandID> = [.previous, .next, .preview, .enter, .search, .open]

@Test(.timeLimit(.minutes(2))) @MainActor func annotateEntryConditionsTable() async {
    let statuses: [(ViewerImageStatus, Bool)] = [
        (.showing, true), (.detailLimited, true), (.empty, false), (.loading("a"), false), (.readingFolder, false),
        (.failed(.access, "a"), false), (.failed(.corruptImage, "a"), false), (.noMatches, false), (.emptyFolder, false),
        (.folderScanFailed("r", "f"), false),
    ]
    for (status, expected) in statuses {
        #expect(AnnotateModeState.canEnter(mode: .viewing, hasImage: true, status: status, focus: .canvas) == expected,
                "\(status)")
    }
    #expect(!AnnotateModeState.canEnter(mode: .browsing, hasImage: true, status: .showing, focus: .canvas))
    #expect(!AnnotateModeState.canEnter(mode: .viewing, hasImage: false, status: .showing, focus: .canvas))
    #expect(!AnnotateModeState.canEnter(mode: .viewing, hasImage: true, status: .showing, focus: .textInput))
    #expect(AnnotateModeState.canEnter(mode: .viewing, hasImage: true, status: .showing, focus: .tools))

    let showing = await Showing.make()
    let session = showing.session
    #expect(session.imageStatus == .showing)
    #expect(session.canEnterAnnotateMode)
    session.setInspectorVisible(true)
    session.updateFocus(.textInput)
    #expect(!session.canEnterAnnotateMode, "never while typing")
    session.enterAnnotateMode()
    #expect(session.annotateMode == nil)
    session.updateFocus(.canvas)
    session.enterAnnotateMode()
    #expect(session.annotateMode?.itemID == showing.ids[1])
    #expect(session.annotateMode?.fileURL == Showing.url)
    #expect(session.isAnnotating)

    let grid = ViewerSession(host: AnnotateHost())
    grid.beginBrowsing(items: sessionItems(), sourceVersion: .init(1), scrollAnchor: nil)
    #expect(!grid.canEnterAnnotateMode)
    grid.enterAnnotateMode()
    #expect(grid.annotateMode == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateReEnterIsNoOp() async {
    let session = await Showing.make().session
    session.enterAnnotateMode()
    session.addAnnotationMark(mk(1))
    let before = session.annotateMode
    session.enterAnnotateMode()
    #expect(session.annotateMode == before)
    #expect(session.annotateMode?.document.marks == [mk(1)])
    #expect(session.annotateMode?.prompt == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateDisablesBrowsingKeepsZoom() async {
    let showing = await Showing.make()
    let session = showing.session
    let enabledBefore = CommandID.allCases.map { session.isEnabled($0) }
    let returnBefore = session.canReturnToSource
    #expect(session.isEnabled(.next) && returnBefore, "the fixture can browse before entry")
    session.enterAnnotateMode()
    var random = AnnotationRandom(seed: 7)
    var fresh = 0
    for step in 0..<50 {
        switch Int.random(in: 0..<3, using: &random) {
        case 0: fresh += 1; session.addAnnotationMark(mk(fresh))
        case 1: session.undoAnnotation()
        default: session.redoAnnotation()
        }
        for command in CommandID.allCases {
            if browsingCommands.contains(command) { #expect(!session.isEnabled(command), "step \(step): \(command)") }
        }
        for command: CommandID in [.zoomIn, .zoomOut, .fit, .actualPixels] {
            #expect(session.isEnabled(command), "step \(step): \(command)")
        }
        #expect(!showing.router.route(.next, from: .key, to: session))
        #expect(!showing.router.route(.previous, from: .key, to: session))
        #expect(!session.canReturnToSource)
        #expect(session.currentItemID == showing.ids[1])
    }
    #expect(showing.host.presented == [showing.ids[1]], "only the entry preview presented")
    if session.requestLeaveAnnotateMode(.escape) == .ask { session.resolveAnnotatePrompt(.discard) }
    #expect(session.annotateMode == nil)
    #expect(CommandID.allCases.map { session.isEnabled($0) } == enabledBefore)
    #expect(session.canReturnToSource == returnBefore)
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateEscapeWithoutUnsavedExits() async {
    let showing = await Showing.make()
    let session = showing.session
    session.enterAnnotateMode()
    #expect(session.requestLeaveAnnotateMode(.escape) == .proceed)
    #expect(session.annotateMode == nil)
    session.enterAnnotateMode()
    #expect(session.isEnabled(.escape))
    #expect(showing.router.route(.escape, from: .key, to: session), "Esc reaches the mode first")
    #expect(session.annotateMode == nil)
    #expect(session.mode == .viewing && session.currentItemID == showing.ids[1], "Esc left the mode, not the image")
    #expect(showing.host.returnedToGrid == 0)
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateEscapeWithUnsavedPromptsAndResolves() async {
    let showing = await Showing.make()
    let session = showing.session
    session.enterAnnotateMode()
    session.addAnnotationMark(mk(1))
    #expect(showing.router.route(.escape, from: .key, to: session))
    #expect(session.annotateMode?.prompt == .escape)
    #expect(session.resolveAnnotatePrompt(.cancel) == .refused)
    #expect(session.annotateMode?.document.marks == [mk(1)])
    #expect(session.annotateMode?.prompt == nil)
    #expect(session.requestLeaveAnnotateMode(.escape) == .ask)
    #expect(session.resolveAnnotatePrompt(.discard) == .proceed)
    #expect(session.annotateMode == nil)
    session.enterAnnotateMode()
    session.addAnnotationMark(mk(2))
    #expect(session.requestLeaveAnnotateMode(.escape) == .ask)
    #expect(session.resolveAnnotatePrompt(.save) == .saving)
    #expect(session.annotateMode != nil, "Save exits only after the write")
    #expect(showing.host.saves.count == 1)
    #expect(showing.host.saves.first?.marks == [mk(2)])
    #expect(session.annotateSaveFinished(.saved(URL(fileURLWithPath: "/photos/photo-annotated.jpg"))) == .proceed)
    #expect(session.annotateMode == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateCancelPreservesStateForEveryReason() async {
    let showing = await Showing.make()
    let session = showing.session
    for reason in AnnotateLeaveReason.allCases {
        for seed in UInt64(0)..<20 {
            session.enterAnnotateMode()
            var random = AnnotationRandom(seed: seed)
            var fresh = 0
            for _ in 0..<Int.random(in: 1...8, using: &random) {
                switch Int.random(in: 0..<3, using: &random) {
                case 0, 1: fresh += 1; session.addAnnotationMark(mk(fresh))
                default: session.undoAnnotation()
                }
            }
            fresh += 1; session.addAnnotationMark(mk(fresh))
            let mode = session.annotateMode, item = session.currentItemID
            let set = session.previewSet, status = session.imageStatus
            #expect(session.requestLeaveAnnotateMode(reason) == .ask, "\(reason) seed \(seed)")
            #expect(session.annotateMode?.prompt == reason)
            #expect(session.resolveAnnotatePrompt(.cancel) == .refused, "\(reason) seed \(seed)")
            #expect(session.annotateMode == mode, "\(reason) seed \(seed)")
            #expect(session.annotateMode?.prompt == nil)
            #expect(session.currentItemID == item && session.previewSet == set && session.imageStatus == status)
            #expect(session.resolveAnnotatePrompt(.discard) == .refused, "no prompt pending: nothing to resolve")
            #expect(session.annotateMode == mode)
            #expect(session.requestLeaveAnnotateMode(reason) == .ask)
            #expect(session.resolveAnnotatePrompt(.discard) == .proceed)
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateLeaveOutcomeForEveryReason() async {
    let showing = await Showing.make()
    let session = showing.session
    let saved = URL(fileURLWithPath: "/photos/photo-annotated.jpg")
    for reason in AnnotateLeaveReason.allCases {
        session.enterAnnotateMode(); session.addAnnotationMark(mk(1))
        #expect(session.requestLeaveAnnotateMode(reason) == .ask)
        #expect(session.resolveAnnotatePrompt(.discard) == .proceed, "\(reason)")
        #expect(session.annotateMode == nil)

        session.enterAnnotateMode(); session.addAnnotationMark(mk(1))
        #expect(session.requestLeaveAnnotateMode(reason) == .ask)
        #expect(session.resolveAnnotatePrompt(.save) == .saving)
        #expect(session.annotateSaveFinished(.saved(saved)) == .proceed, "\(reason)")
        #expect(session.annotateMode == nil)

        for failure: AnnotateSaveResult in [.failed(.diskFull), .panelCancelled] {
            session.enterAnnotateMode(); session.addAnnotationMark(mk(1))
            #expect(session.requestLeaveAnnotateMode(reason) == .ask)
            #expect(session.resolveAnnotatePrompt(.save) == .saving)
            #expect(session.annotateSaveFinished(failure) == .refused, "\(reason) \(failure)")
            #expect(session.annotateMode?.document.marks == [mk(1)])
            #expect(session.annotateMode?.isSaving == false)
            #expect(session.requestLeaveAnnotateMode(reason) == .ask)
            session.resolveAnnotatePrompt(.discard)
        }
    }
    session.enterAnnotateMode()
    #expect(session.requestLeaveAnnotateMode(.quitApp) == .proceed, "nothing unsaved: quit goes on")
    #expect(session.requestLeaveAnnotateMode(.closeWindow) == .proceed, "outside the mode nothing asks")
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateFailedOrCancelledSaveKeepsMarks() async {
    let showing = await Showing.make()
    let session = showing.session
    for (result, error) in [(AnnotateSaveResult.panelCancelled, AnnotatedCopyError?.none),
                            (.failed(.sourceMissing), .sourceMissing), (.failed(.accessLost), .accessLost)] {
        session.enterAnnotateMode(); session.addAnnotationMark(mk(1))
        #expect(session.requestLeaveAnnotateMode(.escape) == .ask)
        session.resolveAnnotatePrompt(.save)
        session.annotateSaveFinished(result)
        #expect(session.annotateMode != nil, "\(result)")
        #expect(session.annotateMode?.document.marks == [mk(1)])
        #expect(session.annotateMode?.document.hasUnsavedMarks == true)
        #expect(session.annotateMode?.lastSaveError == error, "\(result)")
        #expect(session.currentItemID == showing.ids[1])
        session.requestLeaveAnnotateMode(.escape); session.resolveAnnotatePrompt(.discard)
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotatePermissionDeniedReplansToPanel() async {
    let showing = await Showing.make()
    let session = showing.session
    let folder = URL(fileURLWithPath: "/photos", isDirectory: true)
    session.enterAnnotateMode(); session.addAnnotationMark(mk(1))
    #expect(session.saveAnnotatedCopy())
    #expect(showing.host.saves.last?.destination(folder: folder, name: "photo-annotated.jpg", access: .accessRoot)
        == .direct(folder: folder, name: "photo-annotated.jpg"))
    session.annotateSaveFinished(.failed(.permissionDenied))
    #expect(session.annotateMode?.directRefused == true)
    #expect(session.annotateMode?.document.marks == [mk(1)])
    #expect(session.saveAnnotatedCopy())
    #expect(showing.host.saves.count == 2)
    #expect(showing.host.saves.last?.destination(folder: folder, name: "photo-annotated.jpg", access: .accessRoot)
        == .savePanel(folder: folder, name: "photo-annotated.jpg"))
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateOnlyPermissionErrorsReplanToPanel() async {
    let showing = await Showing.make()
    let session = showing.session
    let others: [AnnotatedCopyError] = [.sourceMissing, .accessLost, .diskFull, .writeFailed, .encodeFailed,
                                        .folderMissing, .nameExhausted, .sourceIsTarget]
    for error in others {
        session.enterAnnotateMode(); session.addAnnotationMark(mk(1))
        session.saveAnnotatedCopy()
        session.annotateSaveFinished(.failed(error))
        #expect(session.annotateMode?.directRefused == false, "\(error)")
        session.saveAnnotatedCopy()
        #expect(showing.host.saves.last?.directRefused == false, "\(error)")
        session.annotateSaveFinished(.panelCancelled)
        session.requestLeaveAnnotateMode(.escape); session.resolveAnnotatePrompt(.discard)
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateImageChangeRequestAsks() async {
    let showing = await Showing.make()
    let session = showing.session
    session.enterAnnotateMode(); session.addAnnotationMark(mk(1))
    #expect(session.requestLeaveAnnotateMode(.changeImage) == .ask)
    #expect(session.currentItemID == showing.ids[1])
    #expect(session.isAnnotating)
    #expect(session.resolveAnnotatePrompt(.discard) == .proceed)
    #expect(!session.isAnnotating)
    session.enterAnnotateMode(); session.addAnnotationMark(mk(1))
    session.saveAnnotatedCopy(); session.annotateSaveFinished(.saved(URL(fileURLWithPath: "/photos/a.jpg")))
    #expect(session.requestLeaveAnnotateMode(.changeImage) == .proceed, "saved: exits at once")
    #expect(!session.isAnnotating)
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateSaveSuccessKeepsModeAndSet() async {
    let showing = await Showing.make()
    let session = showing.session
    session.enterAnnotateMode(); session.addAnnotationMark(mk(1))
    let first = URL(fileURLWithPath: "/photos/photo-annotated.jpg")
    let second = URL(fileURLWithPath: "/photos/photo-annotated-2.jpg")
    #expect(session.saveAnnotatedCopy())
    #expect(session.annotateSaveFinished(.saved(first)) == nil, "a plain ⌘S completes no leave")
    #expect(session.saveAnnotatedCopy())
    session.annotateSaveFinished(.saved(second))
    #expect(session.isAnnotating)
    #expect(session.annotateMode?.document.marks == [mk(1)])
    #expect(session.annotateMode?.document.hasUnsavedMarks == false)
    #expect(session.annotateMode?.lastSavedURL == second)
    #expect(session.annotateMode?.lastSaveError == nil)
    #expect(session.previewSet?.itemIDs == showing.ids)
    #expect(session.currentItemID == showing.ids[1])
    #expect(showing.host.saves.count == 2)
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateSourceDeletionDoesNotAdvance() async {
    let showing = await Showing.make()
    let session = showing.session
    let survivors = showing.ids.filter { $0 != showing.ids[1] }
    session.enterAnnotateMode(); session.addAnnotationMark(mk(1))
    #expect(session.allowsFolderScanPresentation == false)
    session.updateItems(survivors, sourceVersion: .init(2))
    #expect(session.currentItemID == showing.ids[1])
    #expect(session.isAnnotating)
    #expect(session.annotateMode?.document.marks == [mk(1)])
    #expect(showing.host.presented == [showing.ids[1]])
    session.requestLeaveAnnotateMode(.escape); session.resolveAnnotatePrompt(.discard)
    #expect(session.currentItemID == showing.ids[2], "after exit the successor rule applies")
    #expect(showing.host.presented.last == showing.ids[2])
    #expect(session.previewSet?.itemIDs == survivors)
}

@Test(.timeLimit(.minutes(2))) func annotateKeyPolicyTable() {
    func act(_ key: AnnotateKey, _ mods: AnnotateKeyModifiers = [], active: Bool = true, typing: Bool = false)
        -> AnnotateKeyAction? { AnnotateKeyPolicy.action(key: key, modifiers: mods, active: active, typing: typing) }
    #expect(act(.character("r")) == .selectRectangle)
    #expect(act(.character("R"), .shift) == .selectRectangle, "A2: case-insensitive")
    #expect(act(.character("r"), typing: true) == nil)
    #expect(act(.character("r"), active: false) == nil)
    #expect(act(.character("r"), .command) == nil)
    #expect(act(.character("r"), .option) == nil)
    #expect(act(.character("z"), .command) == .undo)
    #expect(act(.character("Z"), [.command, .shift]) == .redo)
    #expect(act(.character("z")) == nil)
    #expect(act(.character("z"), [.command, .control]) == nil)
    #expect(act(.escape) == .requestLeave)
    #expect(act(.escape, .shift) == nil)
    #expect(act(.escape, typing: true) == nil, "the text field keeps its Esc")
    // Addendum 5.6 (page 39, 2026-11-14): ←/→/↑/↓ nudge the selected mark, ten pixels with Shift; never change images.
    let steps: [(AnnotateKey, Int, Int)] = [(.leftArrow, -1, 0), (.rightArrow, 1, 0), (.upArrow, 0, -1), (.downArrow, 0, 1)]
    for (arrow, dx, dy) in steps {
        #expect(act(arrow) == .nudge(dx: dx, dy: dy), "\(arrow)")
        #expect(act(arrow, .shift) == .nudge(dx: dx * 10, dy: dy * 10), "\(arrow)")
        #expect(act(arrow, .command) == nil, "\(arrow)")
    }
    #expect(act(.character("e"), .command, active: false) == nil, "⌘E is left to the menu")
    #expect(act(.character("e"), .command) == nil)
    #expect(act(.character("x")) == nil)
}

@Test(.timeLimit(.minutes(2))) func annotateKeyPolicyNeverConsumesOutsideMode() {
    let keys: [AnnotateKey] = [.escape, .leftArrow, .rightArrow, .upArrow, .downArrow]
        + "rRzZeEaq1 ←".map { .character(String($0)) }
    for seed in UInt64(0)..<500 {
        var random = AnnotationRandom(seed: seed)
        let key = keys.randomElement(using: &random)!
        let mods = AnnotateKeyModifiers(rawValue: Int.random(in: 0..<16, using: &random))
        let typing = Bool.random(using: &random)
        #expect(AnnotateKeyPolicy.action(key: key, modifiers: mods, active: false, typing: typing) == nil, "seed \(seed)")
        if typing { #expect(AnnotateKeyPolicy.action(key: key, modifiers: mods, active: true, typing: true) == nil) }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateRSelectsRectangleOnlyInMode() async {
    let session = await Showing.make().session
    session.selectAnnotateTool(.rectangle)
    #expect(session.annotateMode == nil)
    session.enterAnnotateMode()
    // Page 39's pinned bare URL shows the rectangle tool pressed on entry (addendum 2026-11-14).
    #expect(session.annotateMode?.tool == .rectangle)
    session.selectAnnotateTool(.select)
    #expect(session.annotateMode?.tool == .select)
    session.selectAnnotateTool(.rectangle)
    #expect(session.annotateMode?.tool == .rectangle)
    session.addAnnotationMark(mk(1))
    #expect(session.undoAnnotation())
    #expect(session.annotateMode?.document.marks == [])
    #expect(session.redoAnnotation())
    #expect(session.annotateMode?.document.marks == [mk(1)])
    session.requestLeaveAnnotateMode(.escape); session.resolveAnnotatePrompt(.discard)
    session.addAnnotationMark(mk(2))
    #expect(!session.undoAnnotation() && !session.redoAnnotation())
    #expect(session.annotateMode == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateCopyDoesNotChangeUnsaved() async throws {
    let session = await Showing.make().session
    let context = try #require(CGContext(data: nil, width: 6, height: 4, bitsPerComponent: 8, bytesPerRow: 24,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    session.enterAnnotateMode(); session.addAnnotationMark(mk(1))
    let before = session.annotateMode
    let copy = try session.flattenAnnotations(onto: image, orientation: 6)
    #expect(copy.width == 4 && copy.height == 6, "upright size")
    #expect(session.annotateMode == before)
    #expect(session.annotateMode?.document.hasUnsavedMarks == true)
    let plain = try AnnotationFlattener.flatten(image, orientation: 6, marks: [mk(1)])
    #expect(copy.dataProvider?.data as Data? == plain.dataProvider?.data as Data?, "the marks are drawn")
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateOpenDisabledWhileActive() async {
    let showing = await Showing.make()
    let session = showing.session
    #expect(session.isEnabled(.open))
    session.enterAnnotateMode()
    #expect(!session.isEnabled(.open))
    #expect(!showing.router.route(.open, from: .menu, to: session))
    session.requestLeaveAnnotateMode(.escape)
    #expect(session.isEnabled(.open))
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateEditDuringSaveStaysUnsaved() async {
    let showing = await Showing.make()
    let session = showing.session
    let url = URL(fileURLWithPath: "/photos/photo-annotated.jpg")
    session.enterAnnotateMode(); session.addAnnotationMark(mk(1))
    session.saveAnnotatedCopy()
    #expect(!session.canSaveAnnotatedCopy, "one save at a time")
    session.addAnnotationMark(mk(2))
    session.annotateSaveFinished(.saved(url))
    #expect(session.annotateMode?.document.hasUnsavedMarks == true)
    #expect(session.requestLeaveAnnotateMode(.escape) == .ask)
    session.resolveAnnotatePrompt(.discard)

    session.enterAnnotateMode(); session.addAnnotationMark(mk(1)); session.addAnnotationMark(mk(2))
    session.saveAnnotatedCopy()
    session.undoAnnotation()
    session.annotateSaveFinished(.saved(url))
    #expect(session.annotateMode?.document.hasUnsavedMarks == true)
    #expect(session.requestLeaveAnnotateMode(.escape) == .ask)
    session.resolveAnnotatePrompt(.discard)
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateSaveEnablement() async {
    let showing = await Showing.make()
    let session = showing.session
    #expect(!session.canSaveAnnotatedCopy)
    #expect(!session.saveAnnotatedCopy())
    session.enterAnnotateMode()
    #expect(!session.canSaveAnnotatedCopy)
    #expect(!session.saveAnnotatedCopy())
    session.addAnnotationMark(mk(1))
    #expect(session.canSaveAnnotatedCopy)
    session.undoAnnotation()
    #expect(!session.canSaveAnnotatedCopy)
    #expect(!session.saveAnnotatedCopy())
    #expect(showing.host.saves.isEmpty)
    #expect(session.annotateSaveFinished(.saved(URL(fileURLWithPath: "/x"))) == nil, "no save in flight")
    #expect(session.annotateMode?.lastSavedURL == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateFlattenOutsideModeIsPlainUpright() async throws {
    let session = await Showing.make().session
    let context = try #require(CGContext(data: nil, width: 6, height: 4, bitsPerComponent: 8, bytesPerRow: 24,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 3, height: 4))
    let image = try #require(context.makeImage())
    let copy = try session.flattenAnnotations(onto: image, orientation: 6)
    let plain = try AnnotationFlattener.flatten(image, orientation: 6, marks: [])
    #expect(copy.width == 4 && copy.height == 6)
    #expect(copy.dataProvider?.data as Data? == plain.dataProvider?.data as Data?, "no marks outside the mode")
}

// MARK: - #690 WI-5: the select tool, selection and nudge (addendum 5.5, 5.6)

private let photoSize = CGSize(width: 1600, height: 2400)

@Test(.timeLimit(.minutes(2))) @MainActor func annotateEnterSelectsRectangle() async {
    let session = await Showing.make().session
    session.enterAnnotateMode()
    #expect(session.annotateMode?.tool == .rectangle)
    #expect(session.annotateMode?.selectedMark == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateNewMarkIsSelected() async {
    let session = await Showing.make().session
    session.enterAnnotateMode()
    session.addAnnotationMark(mk(1))
    #expect(session.annotateMode?.selectedMark == 0)
    session.addAnnotationMark(mk(2))
    #expect(session.annotateMode?.selectedMark == 1)
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateSelectAndClearSelection() async {
    let session = await Showing.make().session
    session.selectAnnotationMark(0)
    #expect(session.annotateMode == nil, "nothing outside the mode")
    session.enterAnnotateMode()
    session.addAnnotationMark(mk(1)); session.addAnnotationMark(mk(2))
    session.selectAnnotationMark(0)
    #expect(session.annotateMode?.selectedMark == 0)
    session.selectAnnotationMark(nil)
    #expect(session.annotateMode?.selectedMark == nil)
    session.selectAnnotationMark(1)
    session.selectAnnotationMark(5)
    #expect(session.annotateMode?.selectedMark == 1, "an index outside the marks is ignored")
    session.selectAnnotationMark(-1)
    #expect(session.annotateMode?.selectedMark == 1)
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateNudgeMovesSelectedOnly() async {
    let showing = await Showing.make()
    let session = showing.session
    session.enterAnnotateMode()
    session.addAnnotationMark(mk(100)); session.addAnnotationMark(mk(200))
    session.selectAnnotationMark(0)
    let presented = showing.host.presented
    #expect(session.nudgeSelectedAnnotation(dx: 1, dy: 0, imageSize: photoSize))
    #expect(session.annotateMode?.document.marks.map(\.rect.origin) == [CGPoint(x: 101, y: 100), CGPoint(x: 200, y: 200)])
    #expect(session.annotateMode?.document.marks.map(\.rect.size) == [CGSize(width: 10, height: 10), CGSize(width: 10, height: 10)])
    #expect(session.annotateMode?.selectedMark == 0)
    #expect(session.currentItemID == showing.ids[1] && session.imageLoader.fileURL == Showing.url)
    #expect(showing.host.presented == presented)
    #expect(session.annotateMode?.document.hasUnsavedMarks == true)
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateNudgeWithoutSelectionChangesNothing() async {
    let showing = await Showing.make()
    let session = showing.session
    session.enterAnnotateMode()
    session.addAnnotationMark(mk(100))
    session.selectAnnotationMark(nil)
    let before = session.annotateMode
    let presented = showing.host.presented
    #expect(!session.nudgeSelectedAnnotation(dx: 1, dy: 0, imageSize: photoSize))
    #expect(session.annotateMode == before)
    #expect(session.currentItemID == showing.ids[1] && showing.host.presented == presented)
    _ = session.requestLeaveAnnotateMode(.escape); session.resolveAnnotatePrompt(.discard)
    #expect(!session.nudgeSelectedAnnotation(dx: 1, dy: 0, imageSize: photoSize), "nothing outside the mode")
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateNudgeIsUndoable() async {
    let session = await Showing.make().session
    session.enterAnnotateMode()
    session.addAnnotationMark(mk(100))
    for _ in 0..<3 { session.nudgeSelectedAnnotation(dx: 0, dy: 10, imageSize: photoSize) }
    #expect(session.annotateMode?.document.marks.first?.rect.origin == CGPoint(x: 100, y: 130))
    for _ in 0..<3 { session.undoAnnotation() }
    #expect(session.annotateMode?.document.marks == [mk(100)])
    for _ in 0..<3 { session.redoAnnotation() }
    #expect(session.annotateMode?.document.marks.first?.rect.origin == CGPoint(x: 100, y: 130))
    #expect(session.annotateMode?.document.marks.count == 1)
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateUndoRemovingSelectedClearsSelection() async {
    let session = await Showing.make().session
    session.enterAnnotateMode()
    session.addAnnotationMark(mk(1))
    #expect(session.annotateMode?.selectedMark == 0)
    session.undoAnnotation()
    #expect(session.annotateMode?.document.marks == [])
    #expect(session.annotateMode?.selectedMark == nil)
    session.redoAnnotation()
    let selected = session.annotateMode?.selectedMark
    #expect(selected == nil || selected == 0)
}

@Test(.timeLimit(.minutes(2))) func annotationDocumentReplaceUndoable() {
    var document = AnnotationDocument()
    document.add(mk(1))
    let r1 = document.replace(at: 0, with: mk(7))
    #expect(r1)
    #expect(document.marks == [mk(7)] && document.hasUnsavedMarks)
    let r2 = document.undo()
    #expect(r2)
    #expect(document.marks == [mk(1)])
    let r3 = document.redo()
    #expect(r3)
    #expect(document.marks == [mk(7)])
    let undo = document.canUndo, redo = document.canRedo
    let r4 = document.replace(at: 3, with: mk(9))
    #expect(!r4)
    let r5 = document.replace(at: -1, with: mk(9))
    #expect(!r5)
    #expect(document.marks == [mk(7)] && document.canUndo == undo && document.canRedo == redo)
    document.markSaved()
    let r6 = document.replace(at: 0, with: mk(8))
    #expect(r6)
    #expect(document.hasUnsavedMarks, "a replacement is a change")
}

@Test(.timeLimit(.minutes(2))) @MainActor func annotateSelectionInvariantProperty() async {
    let showing = await Showing.make()
    let session = showing.session
    for seed in UInt64(1)...300 {
        session.enterAnnotateMode()
        var random = AnnotationRandom(seed: seed)
        for _ in 0..<40 {
            switch Int.random(in: 0..<6, using: &random) {
            case 0: session.addAnnotationMark(mk(Int.random(in: 0...1500, using: &random)))
            case 1:
                let index = Int.random(in: -1...5, using: &random)
                session.selectAnnotationMark(index < 0 ? nil : index)
            case 2: session.nudgeSelectedAnnotation(dx: Int.random(in: -10...10, using: &random),
                                                    dy: Int.random(in: -10...10, using: &random), imageSize: photoSize)
            case 3: session.undoAnnotation()
            case 4: session.redoAnnotation()
            default: session.selectAnnotateTool(Bool.random(using: &random) ? .select : .rectangle)
            }
            let state = session.annotateMode
            #expect(state?.selectedMark.map { $0 >= 0 && $0 < state!.document.marks.count } ?? true, "seed \(seed)")
            #expect(state?.document.marks.allSatisfy { CGRect(origin: .zero, size: photoSize).contains($0.rect) } == true,
                    "seed \(seed)")
            #expect(session.currentItemID == showing.ids[1], "seed \(seed)")
        }
        while session.undoAnnotation() {}
        #expect(session.annotateMode?.document.marks == [], "seed \(seed)")
        _ = session.requestLeaveAnnotateMode(.escape); session.resolveAnnotatePrompt(.discard)
    }
}

@Test(.timeLimit(.minutes(2))) func annotateKeyPolicyVAndNudges() {
    func act(_ key: AnnotateKey, _ mods: AnnotateKeyModifiers = [], active: Bool = true, typing: Bool = false)
        -> AnnotateKeyAction? { AnnotateKeyPolicy.action(key: key, modifiers: mods, active: active, typing: typing) }
    #expect(act(.character("v")) == .selectTool)
    #expect(act(.character("V"), .shift) == .selectTool)
    #expect(act(.character("v"), typing: true) == nil)
    #expect(act(.character("v"), active: false) == nil)
    #expect(act(.character("v"), .command) == nil)
    #expect(act(.character("v"), .option) == nil)
    #expect(act(.character("v"), .control) == nil)
    #expect(act(.leftArrow) == .nudge(dx: -1, dy: 0))
    #expect(act(.upArrow, .shift) == .nudge(dx: 0, dy: -10))
    #expect(act(.downArrow, .option) == nil)
    #expect(act(.rightArrow, typing: true) == nil)
}

@Test(.timeLimit(.minutes(2))) func annotateKeyPolicyVNeverConsumedOutsideMode() {
    let keys: [AnnotateKey] = [.leftArrow, .rightArrow, .upArrow, .downArrow] + "vVrR".map { .character(String($0)) }
    let all: [AnnotateKeyModifiers] = [[], .shift, .command, .option, .control, [.command, .shift]]
    for seed in UInt64(0)..<500 {
        var random = AnnotationRandom(seed: seed)
        let key = keys[Int.random(in: 0..<keys.count, using: &random)]
        let mods = all[Int.random(in: 0..<all.count, using: &random)]
        #expect(AnnotateKeyPolicy.action(key: key, modifiers: mods, active: false, typing: false) == nil, "seed \(seed)")
        #expect(AnnotateKeyPolicy.action(key: key, modifiers: mods, active: true, typing: true) == nil, "seed \(seed)")
    }
}

/// #690 fix r1 (gpt M2): the Inspector closes on entering and stays closed while annotating, so page 39's strip and
/// image reserve never sit under it.
@Test(.timeLimit(.minutes(2))) @MainActor func issue690EnteringClosesTheInspector() async {
    let showing = await Showing.make()
    let session = showing.session
    session.setInspectorVisible(true)
    #expect(session.isEnabled(.inspector))
    showing.host.inspector = []
    session.enterAnnotateMode()
    #expect(session.isAnnotating)
    #expect(!session.inspectorFocus.isVisible)
    #expect(showing.host.inspector == [false])
    #expect(!session.isEnabled(.inspector))
    #expect(!showing.router.route(.inspector, from: .key, to: session))
    #expect(!session.inspectorFocus.isVisible)
    _ = session.requestLeaveAnnotateMode(.escape)
    #expect(session.isEnabled(.inspector))
    // Entering with the Inspector already closed does not tell the host again.
    showing.host.inspector = []
    session.enterAnnotateMode()
    #expect(showing.host.inspector.isEmpty)
}
