import AppKit

@main
@MainActor
enum MadoAppMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        #if DEBUG && PICSEE_UI_TEST_FIXTURE
        delegate.updates = nil
        #else
        delegate.updates = SparkleUpdatePort()
        #endif
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
