import AppKit
import MadoApplication

struct CaptureFilterPlan {
    enum Target { case display(UInt32), window(UInt32) }
    let target: Target
    let excludedIDs: Set<UInt32>
    enum Failure: Error, Equatable { case missingExcludedWindow, missingTargetWindow }

    struct ResolvedWindows<Window> {
        let targetWindow: Window?
        let excludedWindows: [Window]
    }

    static func resolve(_ request: CaptureRequest, availableWindowIDs: Set<UInt32>) throws -> Self {
        guard request.excludedWindowIDs.isSubset(of: availableWindowIDs) else { throw Failure.missingExcludedWindow }
        switch request.target {
        case let .fullScreen(id), let .region(_, id, _, _):
            return Self(target: .display(id), excludedIDs: request.excludedWindowIDs)
        case let .window(id):
            guard availableWindowIDs.contains(id), !request.excludedWindowIDs.contains(id) else {
                throw Failure.missingTargetWindow
            }
            return Self(target: .window(id), excludedIDs: request.excludedWindowIDs)
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
        return ResolvedWindows(targetWindow: target, excludedWindows: excluded)
    }
}

enum CaptureRequestFromWindows {
    static func make(target: CaptureRequest.Target, bars: [NSWindow], overlays: [NSWindow]) -> CaptureRequest {
        CaptureRequest(target: target,
                       barWindowIDs: Set(bars.compactMap { UInt32(exactly: $0.windowNumber) }),
                       overlayWindowIDs: Set(overlays.compactMap { UInt32(exactly: $0.windowNumber) }))
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
