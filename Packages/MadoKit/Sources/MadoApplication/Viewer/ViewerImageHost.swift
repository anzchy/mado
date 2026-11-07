import Foundation
import MadoCore

/// Native effects only. The load owner decides which result may be presented.
@MainActor public protocol ViewerImageHost: AnyObject {
    func beginImageOpening()
    func installImage(_ image: DecodedImage, fileURL: URL)
    func imageLoadFailed(_ error: any Error)
}
