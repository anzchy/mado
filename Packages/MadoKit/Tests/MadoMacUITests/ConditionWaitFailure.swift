/// Package tests preserve the shared wait error text without App-only diagnostics.
/// The AppTests target supplies its own hook that prints a redacted AppKit snapshot.
nonisolated func conditionWaitFailure(_ description: String) -> ConditionWaitError {
    ConditionWaitError(description: description)
}
