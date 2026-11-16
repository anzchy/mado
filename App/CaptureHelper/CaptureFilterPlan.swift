import AppKit
import MadoApplication

struct CaptureFilterPlan {
    enum Target { case display(UInt32), window(UInt32) }
    let target: Target
    let excludedIDs: Set<UInt32>
    enum Failure: Error, Equatable { case missingExcludedWindow, missingTargetWindow }

    struct ResolvedWindows<Window> {
        let plan: CaptureFilterPlan
        let targetWindow: Window?
        let excludedWindows: [Window]
    }

    /// A visible bar window must still exist, or the capture could show it. A thumbnail may close after
    /// the request is made; like an overlay or a never-shown helper window, it only needs exclusion while listed.
    static func resolve(_ request: CaptureRequest, availableWindowIDs: Set<UInt32>) throws -> Self {
        guard request.barWindowIDs.isSubset(of: availableWindowIDs) else { throw Failure.missingExcludedWindow }
        let excluded = request.excludedWindowIDs.intersection(availableWindowIDs)
        switch request.target {
        case let .fullScreen(id), let .region(_, id, _, _):
            return Self(target: .display(id), excludedIDs: excluded)
        case let .window(id):
            guard availableWindowIDs.contains(id), !request.excludedWindowIDs.contains(id) else {
                throw Failure.missingTargetWindow
            }
            return Self(target: .window(id), excludedIDs: excluded)
        }
    }

    static func resolveWindows<Window>(_ request: CaptureRequest, windows: [Window],
                                       id: (Window) -> UInt32) throws -> ResolvedWindows<Window> {
        let plan = try resolve(request, availableWindowIDs: Set(windows.map(id)))
        let excluded = windows.filter { plan.excludedIDs.contains(id($0)) }
        let target: Window?
        switch plan.target {
        case .display: target = nil
        case let .window(windowID): target = windows.first { id($0) == windowID }
        }
        return ResolvedWindows(plan: plan, targetWindow: target, excludedWindows: excluded)
    }
}

enum CaptureRequestFromWindows {
    /// Only bar windows on screen are required; a bar window never ordered in (the status panel before its
    /// first message) and a thumbnail are excluded if SCK lists them and otherwise skipped, like an overlay.
    @MainActor static func make(target: CaptureRequest.Target, bars: [NSWindow], thumbnails: [NSWindow] = [],
                                overlays: [NSWindow]) -> CaptureRequest {
        let shown = bars.filter(\.isVisible)
        let optional = overlays + thumbnails + bars.filter { !$0.isVisible }
        return CaptureRequest(target: target,
                              barWindowIDs: Set(shown.compactMap { UInt32(exactly: $0.windowNumber) }),
                              overlayWindowIDs: Set(optional.compactMap { UInt32(exactly: $0.windowNumber) }))
    }
}

@MainActor final class CaptureSelectionAdmission {
    private(set) var isLoading = false
    func begin() -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        return true
    }
    func end() { isLoading = false }
}
