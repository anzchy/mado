import Foundation

@MainActor public protocol PathCopying: AnyObject {
    func copyPaths(_ urls: [URL])
}
