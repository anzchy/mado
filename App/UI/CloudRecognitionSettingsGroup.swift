import AppKit
import MadoApplication
import MadoMacUI

/// What the 文字识别 group needs: the switch/consent/keys rules and how to show the consent dialog.
struct CloudRecognitionSettingsEnvironment {
    typealias ConsentPresenter = @MainActor (NSWindow?, NSAlert, @escaping @MainActor (Bool) -> Void) -> Void
    let model: CloudRecognitionSettingsModel
    let presentConsent: ConsentPresenter

    /// The App's macOS Keychain, defaults and a sheet on the Settings window.
    @MainActor static var live: CloudRecognitionSettingsEnvironment {
        CloudRecognitionSettingsEnvironment(model: CloudRecognitionAppServices.settingsModel) { window, alert, answer in
            if let window {
                alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
            } else {
                answer(alert.runModal() == .alertFirstButtonReturn)
            }
        }
    }

    /// For a Settings window built without the App's services (tests, fixtures): keys and answers live only in
    /// memory, the macOS Keychain is never read, and the consent dialog is answered 取消.
    static func inMemory() -> CloudRecognitionSettingsEnvironment {
        CloudRecognitionSettingsEnvironment(
            model: CloudRecognitionSettingsModel(preferences: MemoryPreferences(),
                                                 keys: BaiduCloudCredentialStore(secrets: MemorySecrets())),
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

    private actor MemoryPreferences: CloudRecognitionPreferencePort {
        var enabled = false
        var record: CloudRecognitionConsentRecord?
        func isEnabled() async -> Bool { enabled }
        func setEnabled(_ enabled: Bool) async { self.enabled = enabled }
        func consentRecord() async -> CloudRecognitionConsentRecord? { record }
        func setConsentRecord(_ record: CloudRecognitionConsentRecord) async { self.record = record }
    }
}

/// A flipped sibling of the text-recognition group, containing only the global cloud controls.
@MainActor final class CloudRecognitionHeaderGroup: NSView {
    override var isFlipped: Bool { true }
}

/// Settings › 截图 › 云识别 and 文字识别 (state 35, ADR-0019). The sibling cloud group owns the global switch;
/// the text group keeps its service, keys and a help link (#870). Both remain editable with the Capture Bar off
/// (owner 2026-11-13: 「文字识别不变灰」). Turning on requires keys and consent; removing keys turns it off.
@MainActor final class CloudRecognitionSettingsGroup: NSView {
    /// Baidu AI Open Platform Service Agreement (research 20261113-capture-ocr-tech.md D12).
    static let termsURL = URL(string: "https://ai.baidu.com/ai-doc/REFERENCE/kk3dwjg7d")!

    /// The help page with the Baidu account notes, the product to enable, the key steps and the terms (#870: these
    /// left Settings for one short line, spec #866). Opened in the default browser; Mado makes no request itself.
    static let keyHelpURL = URL(string: "https://anzchy.github.io/mado/baidu-key.html")!
    static let fallbackHint = "Without an access key, offline, or when the quota is used up, Recognise Text falls back to on-device recognition and says so; Recognise Table needs Cloud Recognition."

    /// No pinned design for the dialog itself: a standard informational NSAlert with the terms link as its
    /// accessory. The first button agrees.
    static func consentAlert(localize: (String) -> String, openURL: @escaping (URL) -> Void) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = localize("Use Baidu to recognise text?")
        alert.informativeText = localize("Only the image you ask to recognise is sent to Baidu after you agree for this service host and choose Recognise Text. Selecting text directly on an image always uses on-device recognition only. Baidu’s terms apply. Baidu text recognition needs a Baidu account with real-name verification; its documentation lists only mainland Chinese ID documents. How long Baidu keeps images and whether its service works outside mainland China are unconfirmed.")
        alert.addButton(withTitle: localize("Agree and Turn On"))
        alert.addButton(withTitle: localize("Cancel"))
        let link = TermsLinkButton(title: localize("Baidu Terms of Service"), open: { openURL(termsURL) })
        link.frame.size = link.intrinsicContentSize
        alert.accessoryView = link
        return alert
    }

    private let environment: CloudRecognitionSettingsEnvironment
    private let localize: (String) -> String
    private let openURL: (URL) -> Void
    private let cloudSwitch = NSSwitch()
    var cloudToggle: NSSwitch { cloudSwitch }
    private var serviceControl: NSPopUpButton!
    private(set) var cloudGroup: CloudRecognitionHeaderGroup!
    private let pill: NSTextField
    private let apiKey = NSTextField()
    private let secretKey = NSSecureTextField()
    private var save: NSButton!
    private let savedKeys: NSTextField
    private var remove: NSButton!
    private let message: NSTextField
    private var keysHint: NSTextField!
    private var keysLearn: NSButton!
    private var fallback: NSTextField!
    /// The 访问密钥 row's geometry, for `layoutKeyRows()`.
    private var keysRow = (top: CGFloat(0), valueX: CGFloat(0), valueWidth: CGFloat(0), width: CGFloat(0),
                           entryBottom: CGFloat(0))
    private var refreshID = 0
    private var busy = false

    /// `valueX` is the form's value column, relative to this group's left edge.
    init(width: CGFloat, labelWidth: CGFloat, valueX: CGFloat, environment: CloudRecognitionSettingsEnvironment,
         localize: @escaping (String) -> String, openURL: @escaping (URL) -> Void) {
        self.environment = environment
        self.localize = localize
        self.openURL = openURL
        pill = Self.text("", muted: true)
        savedKeys = Self.text("")
        message = Self.text("")
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        setAccessibilityIdentifier("settings.capture.ocr")
        build(width: width, labelWidth: labelWidth, valueX: valueX)
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func connectCloudSwitchToService() { cloudSwitch.nextKeyView = serviceControl }

    private static func text(_ value: String, muted: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = DesignMetrics.font("uiSmall")
        field.textColor = muted ? DesignColor.textSecondary.nsColor : DesignColor.textPrimary.nsColor
        field.isSelectable = false
        return field
    }

    private func build(width: CGFloat, labelWidth: CGFloat, valueX: CGFloat) {
        let valueWidth = width - valueX
        let divider = NSBox(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        divider.boxType = .separator
        addSubview(divider)
        let title = Self.text(localize("Cloud Recognition"), muted: true)
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 0, y: 14, width: width, height: 20)
        title.setAccessibilityIdentifier("settings.capture.cloud-heading")
        addSubview(title)

        func rowLabel(_ text: String, top: CGFloat) {
            let label = Self.text(localize(text))
            label.alignment = .right
            label.frame = NSRect(x: 0, y: top + 4, width: labelWidth, height: 18)
            addSubview(label)
        }
        func measured(_ field: NSTextField, top: CGFloat, x: CGFloat = valueX, width fieldWidth: CGFloat = valueWidth) -> CGFloat {
            let height = field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: fieldWidth, height: .greatestFiniteMagnitude)).height.rounded(.up)
            field.frame = NSRect(x: x, y: top, width: fieldWidth, height: height)
            addSubview(field)
            return top + height
        }

        // 云识别: switch, caption, status pill, short hint and shared privacy link.
        var top: CGFloat = 46
        rowLabel("Allow", top: top)
        let switchTitle = localize("Allow Cloud Recognition (Recognise Text, Recognise Table)")
        cloudSwitch.controlSize = .mini
        cloudSwitch.frame = NSRect(x: valueX, y: top + 3, width: 32, height: 18)
        cloudSwitch.target = self
        cloudSwitch.action = #selector(changeSwitch(_:))
        cloudSwitch.setAccessibilityIdentifier("settings.capture.ocr-cloud")
        cloudSwitch.setAccessibilityLabel(switchTitle)
        addSubview(cloudSwitch)
        let caption = Self.text(switchTitle)
        caption.maximumNumberOfLines = 2
        caption.setAccessibilityIdentifier("settings.capture.ocr-cloud.title")
        // Size for the current language; the English caption wraps, while the shorter Chinese one leaves room for the pill.
        func widest(_ texts: [String], font: NSFont?) -> CGFloat {
            texts.map { ($0 as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 12)]).width }
                .max()!.rounded(.up) + 4
        }
        let captionWidth = min(widest([switchTitle], font: caption.font), valueWidth - 40)
        caption.frame = NSRect(x: valueX + 40, y: top + 4, width: captionWidth, height: 36)
        addSubview(caption)
        pill.stringValue = localize("No Access Key")
        pill.maximumNumberOfLines = 1
        pill.alignment = .center
        pill.wantsLayer = true
        pill.drawsBackground = false
        pill.layer?.cornerRadius = 9
        pill.layer?.backgroundColor = DesignColor.hoverBackground.nsColor.cgColor
        pill.setAccessibilityIdentifier("settings.capture.ocr-pill")
        let pillWidth = widest([pill.stringValue, "No Access Key", "未填写访问密钥"], font: pill.font) + 10
        let pillInline = valueX + 40 + captionWidth + 8 + pillWidth <= width &&
            caption.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: captionWidth,
                                                     height: .greatestFiniteMagnitude)).height <= 18
        pill.frame = NSRect(x: pillInline ? valueX + 40 + captionWidth + 8 : valueX + 40,
                            y: pillInline ? top + 3 : top + 42, width: pillWidth, height: 18)
        addSubview(pill)
        top = pillInline ? top + 30 : top + 66
        let hint = Self.text(localize("Only when you click Recognise Text or Recognise Table is that image sent; selecting text on an image uses only on-device recognition."), muted: true)
        hint.maximumNumberOfLines = 2
        hint.setAccessibilityIdentifier("settings.capture.cloud-hint")
        let learn = TermsLinkButton(title: localize("Learn More ↗"), open: { [weak self] in
            self?.openURL(TableRecognitionSettingsGroup.privacyURL)
        })
        learn.setAccessibilityIdentifier("settings.capture.cloud-learn")
        let learnWidth = learn.intrinsicContentSize.width.rounded(.up)
        let hintWidth = width - learnWidth - 8
        let hintHeight = hint.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: hintWidth,
                                                               height: CGFloat.greatestFiniteMagnitude)).height.rounded(.up)
        hint.frame = NSRect(x: 0, y: top, width: hintWidth, height: hintHeight)
        addSubview(hint)
        learn.frame = NSRect(x: hint.frame.maxX + 8, y: top, width: learnWidth, height: 18)
        addSubview(learn)
        top += max(hintHeight, 18) + 12
        cloudGroup = CloudRecognitionHeaderGroup(frame: NSRect(x: 0, y: 0, width: width, height: top))
        cloudGroup.setAccessibilityIdentifier("settings.capture.cloud")
        for view in subviews { cloudGroup.addSubview(view) }

        // Text Recognition is a separate first-level group with its service, keys and help link.
        let textDivider = NSBox(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        textDivider.boxType = .separator
        addSubview(textDivider)
        let textTitle = Self.text(localize("Text Recognition"), muted: true)
        textTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        textTitle.frame = NSRect(x: 0, y: 14, width: width, height: 20)
        addSubview(textTitle)
        top = 46

        // 服务: one choice, 百度 OCR.
        rowLabel("Service", top: top)
        let service = NSPopUpButton(frame: NSRect(x: valueX, y: top, width: 140, height: 24), pullsDown: false)
        service.addItem(withTitle: localize("Baidu OCR"))
        service.font = DesignMetrics.font("uiSmall")
        service.setAccessibilityLabel(localize("Recognition Service"))
        service.setAccessibilityIdentifier("settings.capture.ocr-service")
        addSubview(service)
        serviceControl = service
        connectCloudSwitchToService()
        // #870 (state 35): the Baidu account notes, the product to enable (#832) and the terms live on the help page
        // behind 了解更多 on the keys line; the consent dialog still carries the disclosure and the terms link.
        top += 34

        // 密钥: two fields and 保存到钥匙串, or the masked keys and 移除密钥.
        rowLabel("Keys", top: top)
        for (field, placeholder, id) in [(apiKey as NSTextField, "API Key", "settings.capture.ocr-api-key"),
                                         (secretKey, "Secret Key", "settings.capture.ocr-secret-key")] {
            field.placeholderString = placeholder
            field.setAccessibilityLabel(placeholder)
            field.font = DesignMetrics.font("uiSmall")
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
            field.setAccessibilityIdentifier(id)
            addSubview(field)
        }
        remove = NSButton(title: localize("Remove Access Keys"), target: self, action: #selector(removeKeys(_:)))
        remove.font = DesignMetrics.font("uiSmall")
        remove.setAccessibilityIdentifier("settings.capture.ocr-remove")
        let removeWidth = remove.intrinsicContentSize.width.rounded(.up) + 12
        // 移除密钥 replaces the fields on the same row, so the fields stop short of it (no hidden overlap).
        let fieldWidth = min(150, (valueWidth - removeWidth - 16) / 2)
        apiKey.frame = NSRect(x: valueX, y: top, width: fieldWidth, height: 24)
        secretKey.frame = NSRect(x: valueX + fieldWidth + 8, y: top, width: fieldWidth, height: 24)
        save = NSButton(title: localize("Save to Keychain"), target: self, action: #selector(saveKeys(_:)))
        save.font = DesignMetrics.font("uiSmall")
        save.setAccessibilityIdentifier("settings.capture.ocr-save")
        let saveWidth = save.intrinsicContentSize.width.rounded(.up) + 12
        let saveInline = secretKey.frame.maxX + 8 + saveWidth <= width - removeWidth - 8
        save.frame = NSRect(x: saveInline ? secretKey.frame.maxX + 8 : valueX, y: saveInline ? top : top + 30,
                            width: saveWidth, height: 24)
        addSubview(save)
        remove.frame = NSRect(x: width - removeWidth, y: top, width: removeWidth, height: 24)
        addSubview(remove)
        savedKeys.maximumNumberOfLines = 1
        savedKeys.lineBreakMode = .byTruncatingMiddle
        savedKeys.setAccessibilityIdentifier("settings.capture.ocr-saved-keys")
        addSubview(savedKeys)
        keysRow = (top, valueX, valueWidth, width, save.frame.maxY)
        let keysHint = Self.text(localize("Keys are kept in the macOS Keychain."), muted: true)
        keysHint.setAccessibilityIdentifier("settings.capture.ocr-keys-hint")
        let keysLink = TermsLinkButton(title: localize("Learn More ↗"), open: { [weak self] in
            self?.openURL(Self.keyHelpURL)
        })
        keysLink.setAccessibilityIdentifier("settings.capture.ocr-learn")
        let keysLinkWidth = keysLink.intrinsicContentSize.width.rounded(.up)
        _ = measured(keysHint, top: 0, width: valueWidth - keysLinkWidth - 8)
        keysLink.frame = NSRect(x: keysHint.frame.maxX + 8, y: 0, width: keysLinkWidth, height: 18)
        addSubview(keysLink)
        self.keysHint = keysHint
        keysLearn = keysLink
        message.textColor = DesignColor.errorText.nsColor
        message.maximumNumberOfLines = 2
        message.setAccessibilityIdentifier("settings.capture.ocr-message")
        message.frame = NSRect(x: valueX, y: 0, width: valueWidth, height: 0)
        addSubview(message)
        let fallback = Self.text(localize(Self.fallbackHint), muted: true)
        fallback.setAccessibilityIdentifier("settings.capture.ocr-fallback-hint")
        _ = measured(fallback, top: 0)
        self.fallback = fallback
        // The group keeps the height of its tallest arrangement (移除密钥 under the key line, a two-line message);
        // the rows themselves move up when those are not shown, so any spare room is below the last note.
        let tallestKeys = max(save.frame.maxY, top + 26 + remove.frame.height) + 6
        frame.size.height = tallestKeys + max(keysHint.frame.height, 18) + 4 + 32 + 8 + fallback.frame.height + 16
        show(CloudRecognitionSettingsState(isOn: false, hasKeys: false, consent: .notAsked, maskedAPIKey: nil))
    }

    /// #689b dev1: the saved-key line shows in full (移除密钥 moves under it when both do not fit on one row), and
    /// the error slot takes room only while it holds a message.
    private func layoutKeyRows() {
        let row = keysRow
        var top = row.entryBottom + 6
        if !savedKeys.isHidden {
            let needed = savedKeys.attributedStringValue.size().width.rounded(.up) + 4
            let besideRemove = row.width - remove.frame.width - 8 - row.valueX
            if needed <= besideRemove {
                savedKeys.frame = NSRect(x: row.valueX, y: row.top + 4, width: besideRemove, height: 18)
                remove.frame.origin = NSPoint(x: row.width - remove.frame.width, y: row.top)
                top = max(row.entryBottom, row.top + remove.frame.height) + 6
            } else {
                savedKeys.frame = NSRect(x: row.valueX, y: row.top + 4, width: row.valueWidth, height: 18)
                remove.frame.origin = NSPoint(x: row.valueX, y: row.top + 26)
                top = remove.frame.maxY + 6
            }
        }
        keysHint.frame.origin.y = top
        keysLearn.frame.origin.y = top
        top = max(keysHint.frame.maxY, keysLearn.frame.maxY) + 4
        message.isHidden = message.stringValue.isEmpty
        if !message.isHidden {
            let height = message.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: row.valueWidth,
                                                                  height: .greatestFiniteMagnitude)).height.rounded(.up)
            message.frame = NSRect(x: row.valueX, y: top, width: row.valueWidth, height: min(height, 32))
            top = message.frame.maxY + 4
        }
        fallback.frame.origin.y = top + 4
    }

    private func setMessage(_ text: String) {
        message.stringValue = text
        layoutKeyRows()
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

    private func show(_ state: CloudRecognitionSettingsState) {
        cloudSwitch.state = state.isOn ? .on : .off
        pill.isHidden = state.hasKeys
        for view in [apiKey, secretKey, save!] as [NSView] { view.isHidden = state.hasKeys }
        savedKeys.isHidden = !state.hasKeys
        remove.isHidden = !state.hasKeys
        savedKeys.stringValue = state.maskedAPIKey.map {
            String(format: localize("API Key %1$@ · Secret Key %2$@"), $0, CloudKeyMask.hidden)
        } ?? ""
        layoutKeyRows()
    }

    /// One change at a time: each finishes by reading the model back, so the switch never shows a state the
    /// model does not hold.
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

    @objc private func changeSwitch(_ sender: NSSwitch) {
        let wantsOn = sender.state == .on
        sender.state = .off
        setMessage("")
        perform { [self] in
            guard wantsOn else { await environment.model.disable(); return }
            switch await environment.model.requestEnable() {
            case .enabled: break
            case .needsKeys: setMessage(localize("Save the access keys first."))
            case .needsConsent:
                let alert = Self.consentAlert(localize: localize, openURL: openURL)
                let agreed = await withCheckedContinuation { continuation in
                    environment.presentConsent(window, alert) { continuation.resume(returning: $0) }
                }
                if await environment.model.answerConsent(granted: agreed) == .needsKeys {
                    setMessage(localize("Save the access keys first."))
                }
            }
        }
    }

    @objc private func saveKeys(_ sender: NSButton) {
        let api = apiKey.stringValue
        let secret = secretKey.stringValue
        setMessage("")
        perform { [self] in
            do throws(CloudKeyError) {
                try await environment.model.saveKeys(apiKey: api, secretKey: secret)
                apiKey.stringValue = ""
                secretKey.stringValue = ""
            } catch .emptyKey {
                setMessage(localize("Enter both the API Key and the Secret Key."))
            } catch {
                setMessage(localize("The access keys could not be saved to the macOS Keychain."))
            }
        }
    }

    @objc private func removeKeys(_ sender: NSButton) {
        setMessage("")
        perform { [self] in
            do throws(CloudKeyError) { try await environment.model.removeKeys() }
            catch { setMessage(localize("The access keys could not be removed from the macOS Keychain.")) }
        }
    }
}

/// A text link in the accent colour (settings.html `.link`); it hands its page to the caller's URL-open seam.
final class TermsLinkButton: NSButton {
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
