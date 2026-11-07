import Foundation
import MadoCore

public struct ViewerRetryIntent: Sendable {
    public let fileURL: URL
    public let accessRequest: AccessRequest?
    public init(fileURL: URL, accessRequest: AccessRequest?) {
        self.fileURL = fileURL; self.accessRequest = accessRequest
    }
    public func reopen(using action: (URL, AccessRequest?) -> Void) { action(fileURL, accessRequest) }
}
