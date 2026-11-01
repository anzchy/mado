import Foundation
import Testing
import PicseeCore
@testable import PicseeApplication

@Test func issue108MetadataSortMenuStatesAndAreaSemantics() {
    let initial = FolderMenuSelection(conditions: .init(), loopEnabled: false)
    let capture = FolderMenuPolicy.applying(.sort(.captureDate), to: initial)
    #expect(FolderMenuPolicy.state(for: .sort(.captureDate), selection: capture,
        hasFolderSource: true, previewActive: false).checked)
    #expect(FolderMenuAction.sort(.captureDate).accessibilityIdentifier == "folder.sort.captureDate.menu")
    #expect(FolderMenuAction.sort(.pixelDimensions).titleKey == "Pixel Area (Width × Height)")
    #expect(FolderMenuAction.sort(.pixelDimensions).helpKey?.contains("equal areas use width, height") == true)
    #expect(FolderMenuAction.sort(.name).helpKey == nil)
    #expect(FolderSortKey.allCases.contains(.captureDate) && FolderSortKey.allCases.contains(.pixelDimensions))
}

@Test func folderMenuPolicyUsesActiveWindowConditionsAndClearableNoMatches() {
    let initial = FolderMenuSelection(conditions: .init(), loopEnabled: false)
    let actions: [FolderMenuAction] = [.sort(.name), .sort(.modificationDate), .sort(.type), .sort(.size),
        .direction(.ascending), .direction(.descending), .extensionType("png"), .clearFilter]
    // #344: loop is app-wide; its preview availability is covered separately from these folder-only actions.
    for action in actions {
        #expect(!FolderMenuPolicy.state(for: action, selection: initial,
            hasFolderSource: false, previewActive: false).enabled)
        #expect(!FolderMenuPolicy.state(for: action, selection: initial,
            hasFolderSource: true, previewActive: true).enabled)
    }
    var a = FolderMenuPolicy.applying(.sort(.modificationDate), to: initial)
    a = FolderMenuPolicy.applying(.direction(.descending), to: a)
    a = FolderMenuPolicy.applying(.extensionType("PNG"), to: a)
    a = FolderMenuPolicy.applying(.loop, to: a)
    #expect(a.conditions == .init(sort: .modificationDate, direction: .descending, selectedExtensions: ["png"]))
    #expect(a.loopEnabled)
    for (action, checked) in [(.sort(.name), false), (.sort(.modificationDate), true),
        (.sort(.type), false), (.direction(.ascending), false), (.direction(.descending), true),
        (.extensionType("png"), true), (.extensionType("jpg"), false), (.clearFilter, false), (.loop, true)] as [(FolderMenuAction, Bool)] {
        let state = FolderMenuPolicy.state(for: action, selection: a, hasFolderSource: true, previewActive: false)
        #expect(state.enabled && state.checked == checked)
    }
    let b = initial
    #expect(FolderMenuPolicy.state(for: .sort(.name), selection: b, hasFolderSource: true, previewActive: false).checked)
    #expect(FolderMenuPolicy.state(for: .sort(.modificationDate), selection: b, hasFolderSource: true, previewActive: false).checked == false)
    a = FolderMenuPolicy.applying(.clearFilter, to: a)
    #expect(a.conditions.selectedExtensions == nil)
    #expect(FolderMenuPolicy.state(for: .clearFilter, selection: a, hasFolderSource: true, previewActive: false).checked)
}

@Test func folderMenuPolicyExtensionChoicesAndTogglesRoundTrip() {
    #expect(FolderMenuPolicy.commonExtensions.contains("png"))
    let choices = FolderMenuPolicy.extensionChoices(available: ["JPG", "raw", "png", "raw"])
    #expect(choices.contains("png") && choices.contains("jpg") && choices.contains("raw"))
    #expect(Set(choices).count == choices.count)
    var selected = FolderMenuSelection(conditions: .init(), loopEnabled: false)
    selected = FolderMenuPolicy.applying(.extensionType("PNG"), to: selected)
    #expect(selected.conditions.selectedExtensions == ["png"])
    selected = FolderMenuPolicy.applying(.extensionType("jpg"), to: selected)
    #expect(selected.conditions.selectedExtensions == ["png", "jpg"])
    selected = FolderMenuPolicy.applying(.extensionType("PNG"), to: selected)
    #expect(selected.conditions.selectedExtensions == ["jpg"])
    selected = FolderMenuPolicy.applying(.extensionType("JPG"), to: selected)
    #expect(selected.conditions.selectedExtensions == nil)
}

@Test func issue127JpegHasOneMenuChoiceAndOneCheckmark() {
    let choices = FolderMenuPolicy.extensionChoices(available: ["JPG", "JPEG", "jPeG", "png"])
    #expect(choices.filter { $0 == "jpg" || $0 == "jpeg" } == ["jpg"])
    let initial = FolderMenuSelection(conditions: .init(), loopEnabled: false)
    let selected = FolderMenuPolicy.applying(.extensionType("JPEG"), to: initial)
    #expect(selected.conditions.selectedExtensions == ["jpg"])
    #expect(FolderMenuPolicy.state(for: .extensionType("jpg"), selection: selected,
        hasFolderSource: true, previewActive: false).checked)
    #expect(FolderMenuPolicy.applying(.extensionType("jpg"), to: selected).conditions.selectedExtensions == nil)
}

@Test func folderMenuPolicyIdentifiersAndLabelsCoverEveryAction() {
    let actions: [FolderMenuAction] = FolderSortKey.allCases.map { .sort($0) }
        + FolderSortDirection.allCases.map { .direction($0) }
        + [.extensionType("png"), .extensionType("jpg"), .clearFilter, .loop]
    let identifiers = actions.map(\.accessibilityIdentifier)
    #expect(Set(identifiers).count == identifiers.count)
    #expect(identifiers.allSatisfy { $0.hasPrefix("folder.") && $0.hasSuffix(".menu") })
    #expect(actions.allSatisfy { !$0.titleKey.isEmpty })
}

@Test func folderMenuPolicyExtensionlessImageHasNamedReachableChoice() {
    let extensionless = FolderMenuAction.extensionType("")
    #expect(FolderMenuPolicy.extensionChoices(available: [""]).contains(""))
    #expect(extensionless.accessibilityIdentifier == "folder.extension.none.menu")
    #expect(extensionless.titleKey == "No Extension")
    let initial = FolderMenuSelection(conditions: .init(), loopEnabled: false)
    let selected = FolderMenuPolicy.applying(extensionless, to: initial)
    #expect(selected.conditions.selectedExtensions == [""])
    #expect(FolderMenuPolicy.state(for: extensionless, selection: selected,
        hasFolderSource: true, previewActive: false).checked)
    #expect(FolderMenuPolicy.applying(extensionless, to: selected).conditions.selectedExtensions == nil)
}

@Test func folderMenuPolicyNormalizesMutatedExtensionSetForCheckmarksAndToggles() {
    var conditions = FolderViewConditions()
    conditions.selectedExtensions = ["JPG"]
    let selected = FolderMenuSelection(conditions: conditions, loopEnabled: false)
    #expect(FolderMenuPolicy.state(for: .extensionType("jpg"), selection: selected,
        hasFolderSource: true, previewActive: false).checked)
    #expect(FolderMenuPolicy.applying(.extensionType("jpg"), to: selected).conditions.selectedExtensions == nil)
    let expanded = FolderMenuPolicy.applying(.extensionType("PNG"), to: selected)
    #expect(expanded.conditions.selectedExtensions == ["jpg", "png"])
}

@Test func folderMenuPolicyRecursiveToggleIsSessionScopedAndHasNoShortcutID() {
    let original = FolderMenuSelection(conditions: .init(), loopEnabled: false)
    #expect(FolderMenuAction.recursive.accessibilityIdentifier == "folder.recursive.menu")
    #expect(FolderMenuAction.recursive.titleKey == "Include Subfolders")
    #expect(!FolderMenuPolicy.state(for: .recursive, selection: original,
        hasFolderSource: false, previewActive: false).enabled)
    let enabled = FolderMenuPolicy.applying(.recursive, to: original)
    #expect(enabled.recursiveEnabled)
    #expect(!original.recursiveEnabled)
    #expect(FolderMenuPolicy.state(for: .recursive, selection: enabled,
        hasFolderSource: true, previewActive: false) == .init(enabled: true, checked: true))
    #expect(FolderMenuPolicy.state(for: .recursive, selection: enabled,
        hasFolderSource: false, previewActive: false) == .init(enabled: false, checked: true))
    #expect(FolderMenuPolicy.applying(.recursive, to: enabled) == original)
}
