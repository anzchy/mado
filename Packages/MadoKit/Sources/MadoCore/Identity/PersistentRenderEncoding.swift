extension RenderKey {
    /// Cross-launch encoding for P3-03 to SHA-256 into disk cache filenames; nil means skip persistence.
    /// Only root-relative ItemIDs survive launches. Resource/ephemeral IDs and resource revision bytes
    /// are session-only. Refuse such keys rather than dropping a token that distinguishes replacements.
    /// A future durable content revision can extend this versioned contract; none is invented here.
    public var persistentEncoding: String? {
        guard itemID.stableEncoding.hasPrefix("id1:root:"), revision.resourceIdentifier == nil else { return nil }
        return "rkp1|" + stableEncoding.dropFirst(4)
    }
}
