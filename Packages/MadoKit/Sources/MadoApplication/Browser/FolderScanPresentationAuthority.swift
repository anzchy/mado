/// Authority for automatic scan effects belongs to all originating request lifetimes.
@MainActor public struct FolderScanPresentationAuthority {
    private let access: AccessOperation
    private let input: AccessOperation
    private let originatingTask: Task<Void, Never>?
    public init(access: AccessOperation, input: AccessOperation, originatingTask: Task<Void, Never>?) {
        self.access = access; self.input = input; self.originatingTask = originatingTask
    }
    public var isCurrent: Bool { access.isCurrent && input.isCurrent && originatingTask?.isCancelled != true }
}
