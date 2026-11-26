import AppKit
import MadoApplication
import MadoMacUI

/// What the 表格识别 group needs: the settings model, how to show the consent dialog, and the help pages.
struct TableRecognitionSettingsEnvironment {
    typealias ConsentPresenter = CloudRecognitionSettingsEnvironment.ConsentPresenter
    let model: TableRecognitionSettingsModel
    let presentConsent: ConsentPresenter

    /// The App's keychain, defaults and real transport, and a sheet on the Settings window.
    @MainActor static var live: TableRecognitionSettingsEnvironment {
        TableRecognitionSettingsEnvironment(model: CloudRecognitionAppServices.tableSettingsModel) { window, alert, answer in
            if let window {
                alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
            } else {
                answer(alert.runModal() == .alertFirstButtonReturn)
            }
        }
    }

    /// For a Settings window built without the App's services (tests, fixtures): nothing is read from the keychain
    /// or the network, every request is refused, and the consent dialog is answered 取消.
    static func inMemory() -> TableRecognitionSettingsEnvironment {
        TableRecognitionSettingsEnvironment(
            model: TableRecognitionSettingsModel(cloud: MemoryCloud(), preferences: MemoryPreferences(),
                                                 keys: TableRecognitionKeyStore(secrets: MemorySecrets()),
                                                 transport: RefusingTransport()),
            presentConsent: { _, _, answer in answer(false) })
    }

    private actor MemorySecrets: CloudSecretStorePort {
        var items: [String: String] = [:]
        func secret(service: String, account: String) async throws(CloudSecretStoreError) -> String? { items[account] }
        func setSecret(_ value: String, service: String, account: String) async throws(CloudSecretStoreError) {
            items[account] = value
        }
        func removeSecret(service: String, account: String) async throws(CloudSecretStoreError) { items[account] = nil }
    }

    private actor MemoryCloud: CloudRecognitionPreferencePort {
        func isEnabled() async -> Bool { false }
        func setEnabled(_ enabled: Bool) async {}
        func consentRecord() async -> CloudRecognitionConsentRecord? { nil }
        func setConsentRecord(_ record: CloudRecognitionConsentRecord) async {}
    }

    private actor MemoryPreferences: TableRecognitionPreferencePort {
        var stored = TableRecognitionStoredSettings.defaults
        var consents: [String: Bool] = [:]
        func storedSettings() async -> TableRecognitionStoredSettings { stored }
        func setStoredSettings(_ settings: TableRecognitionStoredSettings) async { stored = settings }
        func consent(forHost host: String) async -> Bool? { consents[host] }
        func setConsent(_ granted: Bool?, forHost host: String) async { consents[host] = granted }
    }

    private struct RefusingTransport: HTTPTransport {
        func send(_ request: URLRequest, to destination: HTTPDestination) async throws -> HTTPResponse {
            throw URLError(.notConnectedToInternet)
        }
    }
}

/// Settings › 截图 › 表格识别 (#871, state 35 `?section=capture&scroll=table&case=…`, spec #866 decisions 5–7, 13,
/// 15). It sits after 文字识别 and has no switch of its own: the one Allow Cloud Recognition switch covers it. Every
/// row stays editable with that switch off. One short hint per row; the steps and the privacy text are on the help
/// site, opened in the default browser.
@MainActor final class TableRecognitionSettingsGroup: NSView {
    /// Help pages (`site/`, GitHub Pages).
    static let keyHelpURL = URL(string: "https://anzchy.github.io/mado/deepseek-key.html")!
    static let privacyURL = URL(string: "https://anzchy.github.io/mado/cloud-recognition.html")!
    static let costURL = URL(string: "https://anzchy.github.io/mado/deepseek-key.html")!

    static let hostHint = "Images are sent here only after you click Recognise Table."
    static let testNote = "Sends a built-in sample, not your images; may be charged."
    static let costHint = "May use your service account's balance; check the service for charges."

    /// The note beside Test (owner 2026-11-24), and without a key the reason Test is unavailable.
    static func testHint(localize: (String) -> String, hasKey: Bool) -> String {
        let note = localize(testNote)
        guard !hasKey else { return note }
        return note + (note.hasSuffix("。") ? "" : " ") + localize("Save a key to test.")
    }

    /// The plain words for each Test result (state 35 MSG table; spec #866 stories 16–22).
    static func message(_ status: TableRecognitionTestStatus) -> String? {
        switch status {
        case .testing: "Testing…"
        case .passed: "Test passed: the sample table can be recognised."
        case .keyRejected: "The key was not accepted. Replace the key."
        case .addressUnreachable: "Can't connect to this address. Check the address under Advanced."
        case .modelCannotReadImages: "This model doesn't support images. Choose another model."
        case .offline: "Can't connect to the internet. Check the network and try again."
        case .quotaOrBalance: "Not enough balance. Check your service account."
        case .undetermined: "Test failed."
        case .cloudOff: "Cloud Recognition is off. Nothing was sent."
        }
    }

    /// The consent dialog before the first request to a host (state 41 `case=consent`, adapted to the Test). The
    /// consent it records covers that host for images too, so it says so.
    static func consentAlert(host: String, localize: (String) -> String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(format: localize("Send images to %@ to recognise tables?"), host)
        alert.informativeText = localize("Images leave your Mac, are processed by that service, and its privacy policy applies. You can turn off Cloud Recognition in Settings at any time. Consent covers only this server; a different address asks again. Test sends only the built-in sample.")
        alert.addButton(withTitle: localize("Agree and Test"))
        alert.addButton(withTitle: localize("Cancel"))
        return alert
    }

    private let environment: TableRecognitionSettingsEnvironment
    private let localize: (String) -> String
    private let openURL: (URL) -> Void
    private let rowWidth: CGFloat
    private let labelWidth: CGFloat
    private let valueX: CGFloat
    private var valueWidth: CGFloat { rowWidth - valueX }

    private let service = NSPopUpButton(frame: .zero, pullsDown: false)
    private let keyField = NSSecureTextField()
    private var saveKey: NSButton!
    private let savedKey: NSTextField
    private let savedPill: NSTextField
    private var replaceKey: NSButton!
    private var removeKey: NSButton!
    private let keyHint: NSTextField
    private var keyHelp: NSButton!
    private let keyMessage: NSTextField
    private let host: NSTextField
    private let hostHint: NSTextField
    private var privacy: NSButton!
    private var testButton: NSButton!
    private let spinner = NSProgressIndicator()
    private let testStatus: NSTextField
    private let testHint: NSTextField
    private var advanced: NSButton!
    private let address = NSTextField()
    private let addressHint: NSTextField
    private let modelField = NSTextField()
    private let modelHint: NSTextField
    private let costHint: NSTextField
    private var costLink: NSButton!
    private var labels: [String: NSTextField] = [:]

    private var state: TableRecognitionSettingsState?
    private var advancedOpen = false
    private var replacing = false
    private var testTask: Task<Void, Never>?
    private var refreshID = 0
    private var busy = false

    init(width: CGFloat, labelWidth: CGFloat, valueX: CGFloat, environment: TableRecognitionSettingsEnvironment,
         localize: @escaping (String) -> String, openURL: @escaping (URL) -> Void) {
        self.environment = environment
        self.localize = localize
        self.openURL = openURL
        self.rowWidth = width
        self.labelWidth = labelWidth
        self.valueX = valueX
        savedKey = Self.text("")
        savedPill = Self.text("")
        keyHint = Self.text("", muted: true)
        keyMessage = Self.text("")
        host = Self.text("")
        hostHint = Self.text("", muted: true)
        testStatus = Self.text("")
        testHint = Self.text("", muted: true)
        addressHint = Self.text("", muted: true)
        modelHint = Self.text("", muted: true)
        costHint = Self.text("", muted: true)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        setAccessibilityIdentifier("settings.capture.table")
        build()
        frame.size.height = tallestHeight()
        // Until the first state arrives the group shows the no-key arrangement, never a saved key it has not read.
        for view in [savedKey, savedPill, replaceKey!, removeKey!, spinner, keyMessage] as [NSView] { view.isHidden = true }
        for view in [labels["address"]!, address, addressHint, labels["model"]!, modelField, modelHint] as [NSView] {
            view.isHidden = true
        }
        layoutRows()
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private static func text(_ value: String, muted: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = DesignMetrics.font("uiSmall")
        field.textColor = muted ? DesignColor.textSecondary.nsColor : DesignColor.textPrimary.nsColor
        field.isSelectable = false
        return field
    }

    private func button(_ title: String, id: String, action: Selector) -> NSButton {
        let button = NSButton(title: localize(title), target: self, action: action)
        button.font = DesignMetrics.font("uiSmall")
        button.setAccessibilityIdentifier(id)
        button.frame.size = NSSize(width: button.intrinsicContentSize.width.rounded(.up) + 12, height: 24)
        addSubview(button)
        return button
    }

    private func link(_ title: String, id: String, url: URL) -> NSButton {
        let link = HelpLinkButton(title: localize(title)) { [weak self] in self?.openURL(url) }
        link.setAccessibilityIdentifier(id)
        link.frame.size = NSSize(width: link.intrinsicContentSize.width.rounded(.up), height: 16)
        addSubview(link)
        return link
    }

    private func build() {
        let divider = NSBox(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 1))
        divider.boxType = .separator
        addSubview(divider)
        let title = Self.text(localize("Table Recognition"), muted: true)
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 0, y: 14, width: rowWidth, height: 20)
        addSubview(title)
        for (key, text) in [("service", "Service"), ("key", "Access Key"), ("host", "Images Sent To"), ("test", "Test"),
                            ("address", "Address"), ("model", "Model")] {
            let label = Self.text(localize(text))
            label.alignment = .right
            label.maximumNumberOfLines = 1
            label.setAccessibilityIdentifier("settings.capture.table-label-\(key)")
            addSubview(label)
            labels[key] = label
        }

        service.addItem(withTitle: "DeepSeek")
        service.addItem(withTitle: localize("Custom"))
        service.font = DesignMetrics.font("uiSmall")
        service.target = self
        service.action = #selector(changeService(_:))
        service.setAccessibilityLabel(localize("Table Recognition Service"))
        service.setAccessibilityIdentifier("settings.capture.table-service")
        service.frame.size = NSSize(width: 140, height: 24)
        addSubview(service)

        keyField.placeholderString = localize("Paste the access key (API Key)")
        keyField.setAccessibilityLabel(localize("Access Key"))
        keyField.font = DesignMetrics.font("uiSmall")
        keyField.usesSingleLineMode = true
        keyField.cell?.isScrollable = true
        keyField.setAccessibilityIdentifier("settings.capture.table-key")
        addSubview(keyField)
        saveKey = button("Save to Keychain", id: "settings.capture.table-save", action: #selector(save(_:)))
        savedKey.font = DesignMetrics.font("uiSmall", monospaced: true)
        savedKey.maximumNumberOfLines = 1
        savedKey.setAccessibilityIdentifier("settings.capture.table-saved-key")
        addSubview(savedKey)
        savedPill.stringValue = localize("Saved to Keychain")
        savedPill.maximumNumberOfLines = 1
        savedPill.alignment = .center
        savedPill.wantsLayer = true
        savedPill.layer?.cornerRadius = 9
        savedPill.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.14).cgColor
        savedPill.textColor = NSColor.systemGreen
        savedPill.setAccessibilityIdentifier("settings.capture.table-key-pill")
        savedPill.frame.size = NSSize(width: savedPill.intrinsicContentSize.width.rounded(.up) + 14, height: 18)
        addSubview(savedPill)
        replaceKey = button("Replace…", id: "settings.capture.table-replace", action: #selector(replace(_:)))
        removeKey = button("Remove", id: "settings.capture.table-remove", action: #selector(remove(_:)))
        removeKey.contentTintColor = DesignColor.error.nsColor
        removeKey.attributedTitle = NSAttributedString(string: removeKey.title, attributes: [
            .font: DesignMetrics.font("uiSmall"), .foregroundColor: DesignColor.error.nsColor
        ])
        keyHint.stringValue = localize("No key yet?")
        keyHint.maximumNumberOfLines = 1
        keyHint.setAccessibilityIdentifier("settings.capture.table-key-hint")
        addSubview(keyHint)
        keyHelp = link("How to Get One ↗", id: "settings.capture.table-key-help", url: Self.keyHelpURL)
        keyMessage.textColor = DesignColor.errorText.nsColor
        keyMessage.maximumNumberOfLines = 1
        keyMessage.setAccessibilityIdentifier("settings.capture.table-key-message")
        addSubview(keyMessage)

        host.font = DesignMetrics.font("uiSmall", monospaced: true)
        host.maximumNumberOfLines = 1
        host.lineBreakMode = .byTruncatingMiddle
        host.setAccessibilityIdentifier("settings.capture.table-host")
        addSubview(host)
        hostHint.stringValue = localize(Self.hostHint)
        hostHint.maximumNumberOfLines = 2
        hostHint.setAccessibilityIdentifier("settings.capture.table-host-hint")
        addSubview(hostHint)
        privacy = link("Privacy ↗", id: "settings.capture.table-privacy", url: Self.privacyURL)

        testButton = button("Test", id: "settings.capture.table-test", action: #selector(test(_:)))
        let widest = [localize("Test"), localize("Cancel")].map {
            ($0 as NSString).size(withAttributes: [.font: DesignMetrics.font("uiSmall")]).width.rounded(.up)
        }.max()!
        testButton.frame.size.width = widest + 28
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.frame.size = NSSize(width: 14, height: 14)
        spinner.setAccessibilityIdentifier("settings.capture.table-test-spinner")
        addSubview(spinner)
        testStatus.maximumNumberOfLines = 1
        testStatus.setAccessibilityIdentifier("settings.capture.table-test-status")
        addSubview(testStatus)
        testHint.maximumNumberOfLines = 2
        testHint.stringValue = Self.testHint(localize: localize, hasKey: false)
        testHint.setAccessibilityIdentifier("settings.capture.table-test-hint")
        addSubview(testHint)

        advanced = NSButton(title: localize("Advanced"), target: self, action: #selector(toggleAdvanced(_:)))
        advanced.bezelStyle = .disclosure
        advanced.setButtonType(.pushOnPushOff)
        advanced.title = ""
        advanced.setAccessibilityLabel(localize("Advanced"))
        advanced.setAccessibilityIdentifier("settings.capture.table-advanced")
        advanced.frame.size = NSSize(width: 16, height: 16)
        addSubview(advanced)
        let advancedTitle = Self.text(localize("Advanced"))
        advancedTitle.maximumNumberOfLines = 1
        advancedTitle.setAccessibilityIdentifier("settings.capture.table-advanced-title")
        addSubview(advancedTitle)
        labels["advancedTitle"] = advancedTitle

        for (field, placeholder, label, id) in [
            (address, "https://… (required, OpenAI-compatible)", "Service Address", "settings.capture.table-address"),
            (modelField, "Model name (must read images)", "Model", "settings.capture.table-model"),
        ] {
            field.placeholderString = localize(placeholder)
            field.setAccessibilityLabel(localize(label))
            field.font = DesignMetrics.font("uiSmall")
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
            field.cell?.sendsActionOnEndEditing = true
            field.target = self
            field.action = field === address ? #selector(commitAddress(_:)) : #selector(commitModel(_:))
            field.setAccessibilityIdentifier(id)
            addSubview(field)
        }
        addressHint.maximumNumberOfLines = 2
        addressHint.stringValue = localize("Changing the address needs the key saved and consent given again.")
        addressHint.setAccessibilityIdentifier("settings.capture.table-address-hint")
        addSubview(addressHint)
        modelHint.stringValue = localize("Test again after changing the model.")
        modelHint.maximumNumberOfLines = 2
        modelHint.setAccessibilityIdentifier("settings.capture.table-model-hint")
        addSubview(modelHint)
        costHint.stringValue = localize(Self.costHint)
        costHint.maximumNumberOfLines = 2
        costHint.setAccessibilityIdentifier("settings.capture.table-cost")
        addSubview(costHint)
        costLink = link("Learn More ↗", id: "settings.capture.table-cost-link", url: Self.costURL)
    }

    /// Room for the tallest arrangement (Advanced open), so the group never changes the form's height; when
    /// Advanced is closed the spare room is below the cost line.
    private func tallestHeight() -> CGFloat {
        let saved = (advancedOpen, keyMessage.stringValue)
        advancedOpen = true
        keyMessage.stringValue = localize("The key could not be removed from the keychain.")
        let height = layoutRows()
        (advancedOpen, keyMessage.stringValue) = saved
        return height + 16
    }

    private func width(of field: NSTextField) -> CGFloat {
        field.attributedStringValue.size().width.rounded(.up) + 4
    }

    /// Places a hint in the value column, at most two lines; returns its bottom.
    private func place(_ hint: NSTextField, top: CGFloat) -> CGFloat {
        let height = hint.stringValue.isEmpty ? 16
            : min(32, hint.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: valueWidth,
                                                            height: .greatestFiniteMagnitude)).height.rounded(.up))
        hint.frame = NSRect(x: valueX, y: top, width: valueWidth, height: height)
        return top + height
    }

    /// A hint and its link: on one line when both fit (state 35), otherwise the link goes under the hint. Returns
    /// the bottom.
    private func hintLine(_ hint: NSTextField, link: NSButton, top: CGFloat) -> CGFloat {
        let hintWidth = width(of: hint)
        if hintWidth + 2 + link.frame.width <= valueWidth {
            hint.frame = NSRect(x: valueX, y: top, width: hintWidth, height: 16)
            link.frame.origin = NSPoint(x: valueX + hintWidth + 2, y: top)
            return top + 16
        }
        let bottom = place(hint, top: top)
        link.frame.origin = NSPoint(x: valueX, y: bottom)
        return bottom + 16
    }

    /// Lays the rows out top to bottom for the current state; returns the bottom of the last row.
    @discardableResult private func layoutRows() -> CGFloat {
        func label(_ key: String, top: CGFloat) {
            labels[key]!.frame = NSRect(x: 0, y: top + 4, width: labelWidth, height: 18)
        }
        let hasKey = (state?.hasKey ?? false) && !replacing
        let custom = state?.preset == .custom
        var top: CGFloat = 46
        label("service", top: top)
        service.frame.origin = NSPoint(x: valueX, y: top)
        top += 24 + 14

        label("key", top: top)
        if hasKey {
            savedKey.frame = NSRect(x: valueX, y: top + 4, width: width(of: savedKey), height: 18)
            savedPill.frame.origin = NSPoint(x: savedKey.frame.maxX + 6, y: top + 3)
            replaceKey.frame.origin = NSPoint(x: savedPill.frame.maxX + 8, y: top)
            removeKey.frame.origin = NSPoint(x: replaceKey.frame.maxX + 6, y: top)
        } else {
            let fieldWidth = min(240, valueWidth - saveKey.frame.width - 8)
            keyField.frame = NSRect(x: valueX, y: top, width: fieldWidth, height: 24)
            saveKey.frame.origin = NSPoint(x: keyField.frame.maxX + 8, y: top)
        }
        top += 24 + 4
        if !custom { top = hintLine(keyHint, link: keyHelp, top: top) }
        if !keyMessage.stringValue.isEmpty {
            keyMessage.frame = NSRect(x: valueX, y: top + 2, width: valueWidth, height: 16)
            top += 18
        }
        top += 14

        label("host", top: top)
        host.frame = NSRect(x: valueX, y: top + 4, width: valueWidth, height: 18)
        top += 24 + 2
        top = hintLine(hostHint, link: privacy, top: top) + 14

        label("test", top: top)
        testButton.frame.origin = NSPoint(x: valueX, y: top)
        var statusX = testButton.frame.maxX + 8
        if testTask != nil {
            spinner.frame.origin = NSPoint(x: statusX, y: top + 5)
            statusX += 20
        }
        testStatus.frame = NSRect(x: statusX, y: top + 4, width: max(0, rowWidth - statusX), height: 18)
        top += 24 + 2
        top = place(testHint, top: top) + 14

        advanced.frame.origin = NSPoint(x: valueX, y: top + 1)
        labels["advancedTitle"]!.frame = NSRect(x: valueX + 20, y: top, width: 160, height: 18)
        top += 18 + 14

        if advancedOpen {
            label("address", top: top)
            address.frame = NSRect(x: valueX, y: top, width: min(320, valueWidth), height: 24)
            top += 24 + 2
            top = place(addressHint, top: top) + 14
            label("model", top: top)
            modelField.frame = NSRect(x: valueX, y: top, width: min(320, valueWidth), height: 24)
            top += 24 + 2
            top = place(modelHint, top: top) + 14
        }
        return hintLine(costHint, link: costLink, top: top)
    }

    func refresh() {
        refreshID += 1
        let id = refreshID
        Task {
            let state = await environment.model.state()
            guard id == refreshID else { return }
            show(state)
        }
    }

    private func show(_ state: TableRecognitionSettingsState) {
        self.state = state
        let custom = state.preset == .custom
        if custom && state.advancedRequired { advancedOpen = true }
        if !state.hasKey { replacing = false }
        let hasKey = state.hasKey && !replacing
        service.selectItem(at: custom ? 1 : 0)
        for view in [keyField, saveKey!] as [NSView] { view.isHidden = hasKey }
        for view in [savedKey, savedPill, replaceKey!, removeKey!] as [NSView] { view.isHidden = !hasKey }
        savedKey.stringValue = state.maskedKey ?? ""
        keyHint.isHidden = custom
        keyHelp.isHidden = custom
        keyMessage.isHidden = keyMessage.stringValue.isEmpty
        host.stringValue = state.host ?? localize("(Enter the address first)")
        host.textColor = state.host == nil ? DesignColor.textSecondary.nsColor : DesignColor.textPrimary.nsColor
        let testing = testTask != nil
        testButton.title = localize(testing ? "Cancel" : "Test")
        testButton.isEnabled = testing || state.canTest
        spinner.isHidden = !testing
        if testing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        let status: TableRecognitionTestStatus? = testing ? .testing : state.test
        testStatus.stringValue = status.flatMap(Self.message).map { message in
            switch status {
            case .passed?: "✓ " + localize(message)
            case .testing?, nil: localize(message)
            default: "⚠ " + localize(message)
            }
        } ?? ""
        testStatus.textColor = switch status {
        case .passed?: NSColor.systemGreen
        case .testing?, nil: DesignColor.textSecondary.nsColor
        default: DesignColor.errorText.nsColor
        }
        testHint.stringValue = Self.testHint(localize: localize, hasKey: state.hasKey)
        advanced.state = advancedOpen ? .on : .off
        for view in [labels["address"]!, address, addressHint, labels["model"]!, modelField, modelHint] as [NSView] {
            view.isHidden = !advancedOpen
        }
        if address.currentEditor() == nil { address.stringValue = state.address }
        if modelField.currentEditor() == nil { modelField.stringValue = state.model }
        address.placeholderString = localize("https://… (required, OpenAI-compatible)")
        addressHint.stringValue = localize(custom ? "A custom service needs an address and a model."
                                                  : "Changing the address needs the key saved and consent given again.")
        layoutRows()
    }

    /// One change at a time; each ends by reading the model back.
    private func perform(_ work: @escaping @MainActor () async -> Void) {
        guard !busy else { refresh(); return }
        busy = true
        Task {
            await work()
            busy = false
            refreshID += 1
            show(await environment.model.state())
        }
    }

    private func setKeyMessage(_ text: String) {
        keyMessage.stringValue = text
        if let state { show(state) }
    }

    @objc private func changeService(_ sender: NSPopUpButton) {
        let preset: TableRecognitionPreset = sender.indexOfSelectedItem == 1 ? .custom : .deepSeek
        setKeyMessage("")
        if preset == .custom { advancedOpen = true }
        perform { [self] in await environment.model.selectPreset(preset) }
    }

    @objc private func save(_ sender: NSButton) {
        let key = keyField.stringValue
        setKeyMessage("")
        perform { [self] in
            do throws(CloudKeyError) {
                try await environment.model.saveKey(key)
                keyField.stringValue = ""
                replacing = false
            } catch .emptyKey {
                setKeyMessage(localize("Enter the access key."))
            } catch {
                setKeyMessage(localize("The key could not be saved to the keychain."))
            }
        }
    }

    @objc private func replace(_ sender: NSButton) {
        replacing = true
        setKeyMessage("")
        window?.makeFirstResponder(keyField)
    }

    @objc private func remove(_ sender: NSButton) {
        setKeyMessage("")
        perform { [self] in
            do throws(CloudKeyError) { try await environment.model.removeKey() }
            catch { setKeyMessage(localize("The key could not be removed from the keychain.")) }
        }
    }

    @objc private func toggleAdvanced(_ sender: NSButton) {
        advancedOpen = sender.state == .on || state?.advancedRequired == true
        if let state { show(state) }
    }

    @objc private func commitAddress(_ sender: NSTextField) {
        let value = sender.stringValue
        guard value != state?.address else { return }
        perform { [self] in await environment.model.setAddress(value) }
    }

    @objc private func commitModel(_ sender: NSTextField) {
        let value = sender.stringValue
        guard value != state?.model else { return }
        perform { [self] in await environment.model.setModel(value) }
    }

    @objc private func test(_ sender: NSButton) {
        if let running = testTask {
            running.cancel()
            return
        }
        let model = environment.model
        testTask = Task { [weak self] in
            var outcome = await model.test()
            if case .needsConsent(let host) = outcome, !Task.isCancelled, let self {
                let alert = Self.consentAlert(host: host, localize: localize)
                let agreed = await withCheckedContinuation { continuation in
                    self.environment.presentConsent(self.window, alert) { continuation.resume(returning: $0) }
                }
                await model.answerConsent(granted: agreed, host: host)
                if agreed && !Task.isCancelled { outcome = await model.test() }
            }
            _ = outcome
            self?.testTask = nil
            self?.refresh()
        }
        if let state { show(state) }
    }
}

/// A text link in the accent colour (settings.html `.link`); opens a help page in the default browser.
private final class HelpLinkButton: NSButton {
    private let open: () -> Void

    init(title: String, open: @escaping () -> Void) {
        self.open = open
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        font = DesignMetrics.font("uiSmall")
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: DesignMetrics.font("uiSmall"), .foregroundColor: DesignColor.accent.nsColor
        ])
        target = self
        action = #selector(follow(_:))
        setAccessibilityRole(.link)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    @objc private func follow(_ sender: Any?) { open() }
}
