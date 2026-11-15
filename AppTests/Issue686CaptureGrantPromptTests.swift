import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

// #686 P7-10 CAP-02, decision 3.4 / AC-1–3: a Capture opened in Mado shows at once; ←/→ asks for the Capture Folder
// only when it is not an Access Root, worded for Captures; a decline keeps the one Capture and is not asked again in
// the session; a grant is an ordinary Access Root.

@MainActor private final class Motion686: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

private final class FolderRecord686: @unchecked Sendable {
    var record: CaptureFolderRecord?
    init(_ record: CaptureFolderRecord?) { self.record = record }
}

@MainActor private final class Requests686 {
    var all: [FolderGrantPromptRequest] = []
}

@MainActor private struct Capture686Rig {
    let base: URL, captures: URL, capture: URL, rootsFile: URL
    let files: FileAccess
    let controller: CanvasWindowController, window: NSWindow
    let requests = Requests686()
    let record: FolderRecord686

    /// `captureFolder: true` publishes `captures` as the Capture Folder in the (fake) App Group record.
    init(captureFolder: Bool = true) throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("capture686-\(UUID())", isDirectory: true)
        captures = base.appendingPathComponent("Captures", isDirectory: true)
        try fm.createDirectory(at: captures, withIntermediateDirectories: true)
        let asset = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
        let data = try Data(contentsOf: asset)
        for name in ["mado-20261115100000.png", "mado-20261115100001.png", "mado-20261115100002.png"] {
            try data.write(to: captures.appendingPathComponent(name))
        }
        capture = captures.appendingPathComponent("mado-20261115100001.png")
        rootsFile = base.appendingPathComponent("roots.json")
        let scope = SystemSecurityScope()
        files = try FileAccess(scope: scope, bookmarks: scope, store: BookmarkStore(url: rootsFile), buildSHA: "issue686")
        let services = AccessServices(files: files, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(), watch: WatchHub(access: files, source: FSEventSource(), scheduler: DispatchWatchScheduler()),
            selectionScope: scope)
        controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
            accessServices: Task { services }, motionPolicy: MotionPolicy(source: Motion686()))
        window = try #require(controller.window)
        let display = captureFolder ? captures.path : "~/Downloads"
        let record = FolderRecord686(CaptureFolderRecord(bookmark: Data([1]), display: display, fellBack: false))
        self.record = record
        controller.captureFolderGate = CaptureFolderGrantGate(record: { record.record },
                                                              home: URL(fileURLWithPath: "/Users/nobody686"))
        let requests = requests
        controller.folderGrantRequestOverride = { requests.all.append($0) }
    }

    func within2s(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            window.update()
            try await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Lets queued work run, for checks that something did not happen.
    func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

    func open(_ url: URL) async throws {
        controller.openInput([url])
        #expect(try await within2s { window.title == url.lastPathComponent }, "\(url.lastPathComponent) shows")
    }

    func remove() {
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        window.close()
        try? FileManager.default.removeItem(at: base)
    }
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue686CaptureOpensWithoutPromptAndPagingAsksWithCaptureWording() async throws {
    let rig = try Capture686Rig()
    defer { rig.remove() }
    try await rig.open(rig.capture)
    try await rig.settle()
    #expect(rig.requests.all.isEmpty, "no prompt on open")
    rig.controller.navigate(.next)
    #expect(try await rig.within2s { rig.requests.all.count == 1 })
    let request = try #require(rig.requests.all.first)
    #expect(request.wording == .capture)
    #expect(request.folder.standardizedFileURL.path == rig.captures.path)
    #expect(!request.mismatch)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue686DeclineKeepsTheCaptureAndIsNotAskedAgain() async throws {
    let rig = try Capture686Rig()
    defer { rig.remove() }
    try await rig.open(rig.capture)
    rig.controller.navigate(.next)
    #expect(try await rig.within2s { rig.requests.all.count == 1 })
    try #require(rig.requests.all.first).declined()
    rig.controller.navigate(.next)
    rig.controller.navigate(.previous)
    try await rig.settle()
    #expect(rig.requests.all.count == 1, "no repeated prompt for the same folder in the session")
    #expect(rig.window.title == rig.capture.lastPathComponent, "the one Capture stays open")
    #expect(rig.window.attachedSheet == nil)
    #expect(await rig.files.records().isEmpty, "nothing granted")
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue686GrantMakesAnOrdinaryAccessRootAndLaterCapturesPageAtOnce() async throws {
    let rig = try Capture686Rig()
    defer { rig.remove() }
    try await rig.open(rig.capture)
    rig.controller.navigate(.next)
    #expect(try await rig.within2s { rig.requests.all.count == 1 })
    try #require(rig.requests.all.first).selected(rig.captures)
    #expect(try await rig.within2s { rig.window.title == "mado-20261115100002.png" }, "the grant pages on")
    let roots = await rig.files.records()
    #expect(roots.count == 1)
    #expect(roots.first?.displayName == "Captures")
    // A later Capture from the same folder pages at once, without a prompt.
    let later = rig.captures.appendingPathComponent("mado-20261115100003.png")
    try FileManager.default.copyItem(at: rig.capture, to: later)
    try await rig.open(later)
    rig.controller.navigate(.previous)
    #expect(try await rig.within2s { rig.window.title != later.lastPathComponent })
    #expect(rig.requests.all.count == 1)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue686OtherFoldersKeepTheGenericPromptAndAskAgain() async throws {
    let rig = try Capture686Rig(captureFolder: false)
    defer { rig.remove() }
    try await rig.open(rig.capture)
    rig.controller.navigate(.next)
    #expect(try await rig.within2s { rig.requests.all.count == 1 })
    #expect(rig.requests.all.first?.wording == .generic)
    try #require(rig.requests.all.first).declined()
    rig.controller.navigate(.next)
    #expect(try await rig.within2s { rig.requests.all.count == 2 }, "an ordinary folder asks again, as before")
    #expect(rig.requests.all.last?.wording == .generic)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue686PromptTextsUseCaptureWording() throws {
    let zh = try captureCatalog("zh-Hans")
    let en = try captureCatalog("en")
    let folder = URL(fileURLWithPath: "/Users/someone/Pictures/截图", isDirectory: true)
    let zhCapture = FolderGrantPrompt.texts(folder: folder, mismatch: false, wording: .capture,
                                            localize: { zh[$0] ?? "<missing \($0)>" })
    #expect(zhCapture.title == "浏览其他截图需要授权截图文件夹")
    #expect(zhCapture.message == "授权“截图”后，可以用 ←/→ 翻看其他截图。")
    let enCapture = FolderGrantPrompt.texts(folder: folder, mismatch: false, wording: .capture,
                                            localize: { en[$0] ?? "<missing \($0)>" })
    #expect(enCapture.title == "Browsing Other Captures Needs Folder Access")
    #expect(enCapture.message == "Grant access to “截图” to page through your other captures with ←/→.")
    let generic = FolderGrantPrompt.texts(folder: folder, mismatch: false, wording: .generic,
                                          localize: { en[$0] ?? "<missing \($0)>" })
    #expect(generic.title == "Browsing Needs Folder Access")
    #expect(generic.message == "To browse images in “截图”, grant access to its folder.")
    let mismatch = FolderGrantPrompt.texts(folder: folder, mismatch: true, wording: .capture,
                                           localize: { en[$0] ?? "<missing \($0)>" })
    #expect(mismatch.title == "Folder Does Not Contain This Image")
}
