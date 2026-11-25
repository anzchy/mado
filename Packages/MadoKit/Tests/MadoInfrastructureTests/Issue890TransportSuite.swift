import Testing

/// #890: every real-transport test drives `Stub890`'s shared state, so they run one at a time. The tests live in
/// extensions, one file per work item.
@Suite(.serialized) struct Issue890TransportTests {}
