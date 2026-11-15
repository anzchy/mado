import Carbon.HIToolbox
import MadoApplication

/// Global capture shortcuts through Carbon hotkeys (ADR-0018): they work in the sandbox and need neither Accessibility
/// nor Input Monitoring. Registered exclusive, so a combo another app already holds is refused and Settings can say so.
@MainActor final class CarbonHotKeyRegistrar: CaptureHotKeyRegistrarPort {
    private static let signature: OSType = 0x4D41_444F  // 'MADO'
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var pressed: (UInt32) -> Void = { _ in }

    /// Starts delivering presses; `pressed` receives the hotkey id.
    func install(_ pressed: @escaping (UInt32) -> Void) {
        self.pressed = pressed
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, let context else { return status }
            let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { registrar.deliver(id) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func deliver(_ id: EventHotKeyID) {
        guard id.signature == Self.signature else { return }
        pressed(id.id)
    }

    func register(_ combo: CaptureKeyCombo, id: UInt32) -> Bool {
        unregister(id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, Self.carbonModifiers(combo.modifiers),
                                         EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }

    func unregister(id: UInt32) {
        guard let ref = refs.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
    }

    func unregisterAll() {
        for id in Array(refs.keys) { unregister(id: id) }
    }

    static func carbonModifiers(_ modifiers: CaptureKeyModifiers) -> UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        return UInt32(flags)
    }
}
