/// Replaces the sole pending wakeup; nil cancels it. Native adapters own no hide rules.
@MainActor public protocol ViewerChromeScheduling: AnyObject {
    func replace(deadline: Double?, action: @escaping @MainActor () -> Void)
}
