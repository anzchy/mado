import Foundation
import MadoCore

/// Command zoom uses the visible canvas pointer, or the centre for panel actions.
public enum CommandZoomAnchor {
    public static func resolve(entry: CommandEntry, pointer: CGPoint?, pointerOverPanel: Bool,
                               centre: CGPoint) -> CGPoint {
        if entry == .button || pointerOverPanel { return centre }
        return pointer ?? centre
    }
}
