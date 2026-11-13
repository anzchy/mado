import Foundation

@MainActor public protocol FileRevealing: AnyObject {
    func reveal(_ urls: [URL])
}
