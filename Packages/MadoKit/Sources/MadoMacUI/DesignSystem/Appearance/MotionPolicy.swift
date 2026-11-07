import Observation
import SwiftUI

@MainActor public protocol ReduceMotionSource: AnyObject {
    var reduceMotion: Bool { get }
    var onChange: (@MainActor () -> Void)? { get set }
}

@MainActor @Observable public final class MotionPolicy {
    private let source: any ReduceMotionSource
    public private(set) var reduceMotion: Bool
    public init(source: any ReduceMotionSource) {
        self.source = source
        reduceMotion = source.reduceMotion
        source.onChange = { [weak self] in
            guard let self else { return }
            self.reduceMotion = self.source.reduceMotion
        }
    }
}

public struct MotionPolicyContent<Content: View>: View {
    private let policy: MotionPolicy?
    private let content: Content
    @Environment(\.designReduceMotion) private var inherited
    public init(policy: MotionPolicy?, @ViewBuilder content: () -> Content) {
        self.policy = policy
        self.content = content()
    }
    public var body: some View {
        content.environment(\.designReduceMotion, policy?.reduceMotion ?? inherited)
    }
}
