import AppKit
import MadoCore
@testable import MadoApplication
@testable import MadoMacUI

enum StatesRequest: Equatable {
    case unspecified, file(URL), root(AccessRootID, URL)
    init(_ request: AccessRequest?) {
        switch request {
        case .fileGrant(let url): self = .file(url)
        case .root(let root, let url): self = .root(root, url)
        case nil: self = .unspecified
        }
    }
}

actor StatesLeases: AccessLeasing {
    var requests: [AccessRequest] = []
    func acquire(_ request: AccessRequest) -> AccessLease {
        requests.append(request)
        switch request {
        case .fileGrant(let url): return AccessLease(url: url, rootID: nil)
        case .root(let root, let url): return AccessLease(url: url, rootID: root)
        }
    }
    func release(_ lease: AccessLease) {}
}

actor StatesPipeline: ImagePipeline {
    let root = AccessRootID()
    var decodedNames: [String] = []
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize,
            renderKey: RenderKey(itemID: .rootRelative(rootID: root, relativePath: fileURL.lastPathComponent),
                revision: FileRevision(byteCount: 1, modificationDate: nil), maximumPixelSize: maximumPixelSize))
    }
    func image(for request: ImageDecodeRequest) throws -> DecodedImage {
        let name = request.fileURL.lastPathComponent
        decodedNames.append(name)
        if name == "B.jpg" { throw ImageLoadError(.corruptImage) }
        if name == "limited.png" && !request.isPreview { throw ImageLoadError(.resourceLimit) }
        let context = CGContext(data: nil, width: request.maximumPixelSize, height: 1,
            bitsPerComponent: 8, bytesPerRow: request.maximumPixelSize * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(request.maximumPixelSize), height: 1))
        return DecodedImage(image: context.makeImage()!, sourcePixelSize: CGSize(width: 512, height: 512),
            revision: request.renderKey!.revision, itemID: request.renderKey!.itemID)
    }
}

@MainActor final class StatesNativeHost: ViewerImageHost, ViewerSessionNavigationHost {
    weak var canvas: CanvasView?
    weak var window: NSWindow?
    var canNavigate = false
    var navigation: [NavigationDirection] = []
    var installs = 0
    var failures = 0
    var opens = 0
    var hasImage: Bool { canvas?.hasImage == true }
    func beginImageOpening() { canvas?.beginOpening(); window?.title = "Mado" }
    func installImage(_ image: DecodedImage, fileURL: URL) {
        installs += 1; canvas?.install(image); window?.title = fileURL.lastPathComponent
    }
    func imageLoadFailed(_ error: any Error) {
        failures += 1; canvas?.showFailure(); window?.title = "Mado"
    }
    func performCanvas(_ command: CommandID, from entry: CommandEntry) { _ = canvas?.apply(command, from: entry) }
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? { canvas?.apply(command, from: entry) }
    func requestOpen() { opens += 1 }
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
    func navigate(_ direction: NavigationDirection) { navigation.append(direction) }
}

/// Real native views and package state; this adapter does not prove App controller wiring.
@MainActor final class StatesScene {
    let session = ViewerSession()
    let host = StatesNativeHost()
    let window: NSWindow
    let content: NSView
    let canvas: CanvasView
    let state: ViewerStateHost
    let chrome: ViewerChromeOverlay
    init(width: CGFloat = 960) {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: width, height: 640)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        content = NSView(frame: frame)
        canvas = CanvasView(frame: frame, session: session)
        state = ViewerStateHost(frame: frame, session: session)
        chrome = ViewerChromeOverlay(frame: frame, session: session)
        chrome.installTestMenus()
        host.canvas = canvas; host.window = window
        session.host = host; session.imageLoader.host = host
        let session = session
        canvas.openingGeneration = { session.imageLoader.generation }
        content.addSubview(canvas); content.addSubview(state); content.addSubview(chrome)
        window.contentView = content
        state.subviews.compactMap { $0 as? FirstLaunchView }.first?.pinAccessibility()
    }
    @discardableResult func open(_ file: URL, request: AccessRequest? = nil,
        pipeline: StatesPipeline, leases: StatesLeases) -> Task<Void, Never>? {
        session.openImage(file, maximumPixelSize: 512) {
            try await AccessImageSource.open(request ?? .fileGrant(file), access: leases, pipeline: pipeline)
        }
        return session.imageLoader.loadTask
    }
}

extension FirstLaunchView {
    /// B4 tests never read the host's accessibility settings (CI runners report Reduce Motion and
    /// Reduce Transparency on). The posted change drives the view's own refresh, redoing its first styling.
    func pinAccessibility(reduceMotion: Bool = false, reduceTransparency: Bool = false) {
        reduceMotionOverride = reduceMotion
        reduceTransparencyOverride = reduceTransparency
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        layoutSubtreeIfNeeded()
    }
}

extension ViewerChromeOverlay {
    /// The App installs a menu presenter and the 更多 provider; 更多 is a control only while both exist (#444).
    func installTestMenus() {
        menuPresenter = RecordingMenuPresenter()
        moreMenuProvider = { NSMenu() }
    }
}
