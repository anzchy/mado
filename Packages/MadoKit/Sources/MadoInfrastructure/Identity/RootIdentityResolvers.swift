import Foundation
import MadoCore

/// App-wide registry. Leases supply scope; this registry never grants access.
actor RootIdentityResolvers {
    static let shared = RootIdentityResolvers()
    private struct RegisteredRoot {
        let url: URL
        let resource: FileResourceIdentity?
        let resolver: FileItemIdentityResolver
    }
    private var roots: [AccessRootID: RegisteredRoot] = [:]
    func resolver(for root: ItemIdentityRoot) async -> FileItemIdentityResolver {
        let resource = try? URLIdentityResourceReader().identity(for: root.url)
        if let existing = roots[root.id] {
            if existing.url != root.url {
                let sameDirectory = existing.resource != nil && existing.resource == resource
                let oldGoneWithUnknownIdentity = !FileManager.default.fileExists(atPath: existing.url.path)
                    && (existing.resource == nil || resource == nil)
                if sameDirectory || oldGoneWithUnknownIdentity {
                    await existing.resolver.rebase(to: root)
                    roots[root.id] = RegisteredRoot(url: root.url, resource: resource, resolver: existing.resolver)
                    return existing.resolver
                }
                let replacement = FileItemIdentityResolver(root: root)
                roots[root.id] = RegisteredRoot(url: root.url, resource: resource, resolver: replacement)
                return replacement
            }
            return existing.resolver
        }
        let resolver = FileItemIdentityResolver(root: root)
        roots[root.id] = RegisteredRoot(url: root.url, resource: resource, resolver: resolver)
        return resolver
    }
}
