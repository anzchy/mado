/// Retains only pixels already accepted by a consumer; this port never delivers cached content.
public protocol ImagePresentationPinning: Sendable {
    /// True acquired one reference; false acquired none and must not be paired with an unpin.
    @discardableResult func pin(_ key: RenderKey, image: DecodedImage) async -> Bool
    func unpin(_ key: RenderKey) async
}
