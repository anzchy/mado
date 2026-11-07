import Foundation

/// Preserves observed access refusals across cache adapters; cache damage is unrelated.
public enum AccessReadFailure {
    public static func isPermissionDenied(_ error: any Error) -> Bool {
        isPermissionDenied(error as NSError, depth: 0)
    }
    private static func isPermissionDenied(_ error: NSError, depth: Int) -> Bool {
        guard depth < 16 else { return false }
        if error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoPermission.rawValue { return true }
        if error.domain == NSPOSIXErrorDomain && [1, 13].contains(error.code) { return true }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return isPermissionDenied(underlying, depth: depth + 1)
    }
}
