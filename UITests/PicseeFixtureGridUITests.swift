import AppKit
import ImageIO
import XCTest

final class PicseeFixtureGridUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.anzchy.mado").isEmpty else {
            throw XCTSkip("another Mado is running; refusing to launch over it")
        }
    }

    @MainActor
    func testContainerFixtureOpensThreeImageGrid() throws {
        let app = try launchFixture()
        XCTAssertEqual(gridCells(in: app).count, 3)
    }

    // Characterization tests: these observe existing behavior; they do not accompany a product fix.
    @MainActor
    func testKeyboardLoopRestoresCurrentItemSelectionAndFocus() throws {
        let app = try launchFixture()
        let names = try orderedFilenames(in: app)
        let first = try XCTUnwrap(names.first)
        let second = try XCTUnwrap(names.dropFirst().first)
        waitForThumbnails(app)
        assertGridCurrent(app, names: names, current: first)
        let initiallyUnselected = captureGrid(app, names: names, stage: "initial")

        app.typeKey(.rightArrow, modifierFlags: [])
        assertGridCurrent(app, names: names, current: second)
        let selectedSecond = captureGrid(app, names: names, stage: "selected-second")
        app.typeKey(.leftArrow, modifierFlags: [.shift])
        assertGridCurrent(app, names: names, current: first)
        let beforePreview = captureGrid(app, names: names, stage: "before-preview")
        // Native collection wrappers expose neither custom AX values nor Selection.
        // With the same Current Item, only the second cell's selection appearance may change.
        XCTAssertTrue(appearanceMatches(beforePreview[0], initiallyUnselected[0]), "First cell must stay unselected")
        XCTAssertFalse(appearanceMatches(beforePreview[1], initiallyUnselected[1]), "Second cell must visibly become selected")
        XCTAssertTrue(appearanceMatches(beforePreview[2], initiallyUnselected[2]), "Third cell must stay unselected")

        app.typeKey(" ", modifierFlags: [])
        assertViewer(app, filename: first)
        app.typeKey(.rightArrow, modifierFlags: [])
        assertViewer(app, filename: second)
        app.typeKey(.leftArrow, modifierFlags: [])
        assertViewer(app, filename: first)
        app.typeKey(.rightArrow, modifierFlags: [])
        assertViewer(app, filename: second)
        app.typeKey(.escape, modifierFlags: [])
        assertGridCurrent(app, names: names, current: first)
        waitForThumbnails(app)
        // Only GridCollectionView.keyDown handles vertical arrows; window commands do not.
        // If focus were elsewhere, Shift-Down could not move the Grid's Current Item.
        app.typeKey(.downArrow, modifierFlags: [.shift])
        let focusedGridMovement = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "value IN %@", Array(names.dropFirst())),
            object: app.staticTexts["grid.current-file-status"])
        let focusResult = XCTWaiter.wait(for: [focusedGridMovement], timeout: 5)
        print("i145 focused Grid-only Shift-Down result=\(focusResult.rawValue)")
        XCTAssertEqual(focusResult, .completed, "Esc must restore focus to the Grid-only vertical-arrow handler")
        app.typeKey(.upArrow, modifierFlags: [.shift])
        assertGridCurrent(app, names: names, current: first)
        let afterReturn = captureGrid(app, names: names, stage: "after-return")
        for index in names.indices {
            XCTAssertTrue(appearanceMatches(afterReturn[index], beforePreview[index]),
                "Esc must restore Current Item and Selection appearance for \(names[index])")
        }

        let restoredCurrent = app.staticTexts["grid.current-file-status"]
        XCTAssertEqual(restoredCurrent.value as? String, first, "Esc must restore the originating Grid Current Item")
        // Shift navigation changes Current Item while preserving Selection, forcing a redraw.
        app.typeKey(.rightArrow, modifierFlags: [.shift])
        assertGridCurrent(app, names: names, current: second)
        let afterRedraw = captureGrid(app, names: names, stage: "selection-after-redraw")
        for index in names.indices {
            XCTAssertTrue(appearanceMatches(afterRedraw[index], selectedSecond[index]),
                "Selection must survive a keyboard redraw for \(names[index])")
        }
        app.typeKey(.leftArrow, modifierFlags: [.shift])
        assertGridCurrent(app, names: names, current: first)
        // No click after Esc: subsequent keys demonstrate restored keyboard handling.
        app.typeKey(.rightArrow, modifierFlags: [])
        assertGridCurrent(app, names: names, current: second)
        app.typeKey(" ", modifierFlags: [])
        assertViewer(app, filename: second)
    }

    @MainActor
    func testMenuStatesFollowGridAndViewer() throws {
        let app = try launchFixture()
        let first = try XCTUnwrap(try orderedFilenames(in: app).first)
        assertMenuStates(app, imageCommands: false)

        app.menuBars.menuBarItems["View"].click()
        XCTAssertFalse(app.menuItems["command.zoomIn.menu"].isEnabled,
            "Zoom In must be disabled while the Grid is active")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey(" ", modifierFlags: [])
        assertViewer(app, filename: first)
        assertMenuStates(app, imageCommands: true)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(gridCollection(in: app).waitForExistence(timeout: 20))
        assertMenuStates(app, imageCommands: false)
    }

    @MainActor
    func testAccessibilityAuditGridAndViewer() throws {
        guard #available(macOS 14.0, *) else {
            throw XCTSkip("performAccessibilityAudit requires macOS 14 or newer")
        }
        // Native audit findings remain test failures; continue so both surfaces are examined.
        continueAfterFailure = true
        let app = try launchFixture()
        let cells = gridCells(in: app)
        let names = try orderedFilenames(in: app)
        waitForThumbnails(app)
        let first = try XCTUnwrap(names.first)

        XCTAssertEqual(cells.count, 3, "Accessibility audit requires all three fixture images")

        var auditErrors: [String] = []
        @MainActor func audit(_ surface: String) {
            XCTContext.runActivity(named: "Accessibility audit: \(surface)") { activity in
                do {
                    try app.performAccessibilityAudit { issue in
                        let element = issue.element
                        let details = """
                        i145 accessibility finding surface=\(surface) type=\(issue.auditType.rawValue)
                        compact=\(issue.compactDescription)
                        detailed=\(issue.detailedDescription)
                        identifier=\(element?.identifier ?? "<none>")
                        label=\(element?.label ?? "<none>")
                        value=\(String(describing: element?.value))
                        frame=\(String(describing: element?.frame))
                        """
                        print(details)
                        let attachment = XCTAttachment(string: details)
                        attachment.name = "\(surface): \(issue.compactDescription)"
                        attachment.lifetime = .keepAlways
                        activity.add(attachment)
                        // False leaves the finding with XCTest; it is never suppressed.
                        return false
                    }
                } catch {
                    let details = "i145 accessibility audit error surface=\(surface): \(error)"
                    print(details)
                    auditErrors.append(details)
                    let attachment = XCTAttachment(string: details)
                    attachment.name = "\(surface) audit execution error"
                    attachment.lifetime = .keepAlways
                    activity.add(attachment)
                }
            }
        }

        audit("Grid")
        app.typeKey(" ", modifierFlags: [])
        assertViewer(app, filename: first)
        audit("Viewer")
        // A Grid audit execution error must not prevent the Viewer audit or become a pass.
        for error in auditErrors { XCTFail(error) }
    }

    @MainActor
    func launchFixture() throws -> XCUIApplication {
        // The UI target's TEST_TARGET_NAME binds this to the product built for this test run.
        let app = XCUIApplication()
        let runPrefix = ProcessInfo.processInfo.environment["PICSEE_UI_RUN_ID"].map { $0 + "-" } ?? ""
        let fixtureName = runPrefix + UUID().uuidString
        let names = ["landscape-3x2.png", "portrait-2x3.png", "orientation-1.tiff"]
        for (index, name) in names.enumerated() {
            let resource = name as NSString
            let url: URL
            if let directory = ProcessInfo.processInfo.environment["PICSEE_UI_FIXTURE_DIR"] {
                url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
            } else {
                url = try XCTUnwrap(Bundle(for: Self.self).url(
                    forResource: resource.deletingPathExtension,
                    withExtension: resource.pathExtension))
            }
            app.launchEnvironment["PICSEE_UI_FIXTURE_\(index)"] = try Data(contentsOf: url).base64EncodedString()
        }
        app.launchArguments += ["-PicseeUITestFixture", fixtureName,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        addTeardownBlock {
            app.terminate()
            // Fallback if App termination did not run its test-only cleanup hook.
            let runFolder = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/io.github.anzchy.mado/Data/Library/Application Support/Mado/UITestFixtures", isDirectory: true)
                .appendingPathComponent(fixtureName, isDirectory: true)
            if FileManager.default.fileExists(atPath: runFolder.path) {
                try? FileManager.default.removeItem(at: runFolder)
            }
        }

        let folderMarker = app.descendants(matching: .any).matching(identifier: "grid.sidebar.folder.\(fixtureName)").firstMatch
        let fixtureMarker = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND (label == %@ OR label BEGINSWITH %@)",
                fixtureName, fixtureName + ", "), object: folderMarker)
        XCTAssertEqual(XCTWaiter.wait(for: [fixtureMarker], timeout: 20), .completed,
            "The build under test did not open its fixture; check the UI test compile flag and target application")

        let collection = gridCollection(in: app)
        XCTAssertTrue(collection.waitForExistence(timeout: 20))
        let cells = gridCells(in: app)
        XCTAssertTrue(cells.element(boundBy: 2).waitForExistence(timeout: 30))
        let count = cells.count
        XCTAssertEqual(count, 3)
        return app
    }

    @MainActor
    func gridCollection(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "grid.collection").firstMatch
    }

    @MainActor
    func gridCells(in app: XCUIApplication) -> XCUIElementQuery {
        gridCollection(in: app).descendants(matching: .any).matching(identifier: "grid.cell")
    }

    private static let pinnedNames = ["landscape-3x2.png", "portrait-2x3.png", "orientation-1.tiff"]

    @MainActor
    func orderedFilenames(in app: XCUIApplication) throws -> [String] {
        let names = try gridCells(in: app).allElementsBoundByIndex.map { cell in
            let text = cell.staticTexts.matching(NSPredicate(format: "value IN %@", Self.pinnedNames)).firstMatch
            let value = text.waitForExistence(timeout: 10) ? text.value as? String : nil
            return try XCTUnwrap(value, "Grid cell must expose its pinned filename text")
        }
        XCTAssertEqual(names.count, 3)
        XCTAssertEqual(Set(names), Set(Self.pinnedNames), "Fixture filenames must be complete and unique")
        return names
    }

    @MainActor
    func waitForThumbnails(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let pending = gridCollection(in: app).staticTexts.matching(NSPredicate(
            format: "value IN %@", ["Thumbnail pending", "Thumbnail unavailable"]))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: pending)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed,
            "All fixture thumbnails must load before observing appearance", file: file, line: line)
    }

    @MainActor
    func assertGridCurrent(_ app: XCUIApplication, names: [String], current: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(gridCollection(in: app).waitForExistence(timeout: 20), file: file, line: line)
        XCTAssertEqual(gridCells(in: app).count, names.count, file: file, line: line)
        for (index, name) in names.enumerated() {
            let field = gridCells(in: app).element(boundBy: index).staticTexts
                .matching(NSPredicate(format: "value == %@", name)).firstMatch
            XCTAssertTrue(field.exists, "Grid order must remain unchanged", file: file, line: line)
        }
        assertValue(app.staticTexts["grid.current-file-status"], equals: current, file: file, line: line)
    }

    @MainActor
    func captureGrid(_ app: XCUIApplication, names: [String], stage: String) -> [GridAppearance] {
        names.enumerated().map { index, name in
            let screenshot = gridCells(in: app).element(boundBy: index).screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "\(stage): \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            return gridAppearance(screenshot.pngRepresentation)
        }
    }

    struct GridAppearance {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    func gridAppearance(_ png: Data) -> GridAppearance {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            XCTFail("Cannot decode retained Grid screenshot")
            return GridAppearance(width: 0, height: 0, pixels: [])
        }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width,
                height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(rendered, "Cannot render retained Grid screenshot")
        return GridAppearance(width: image.width, height: image.height, pixels: rendered ? pixels : [])
    }

    func appearanceMatches(_ lhs: GridAppearance, _ rhs: GridAppearance) -> Bool {
        guard lhs.width > 0, lhs.width == rhs.width, lhs.height == rhs.height,
              !lhs.pixels.isEmpty, lhs.pixels.count == rhs.pixels.count else { return false }
        // Captured focus-ring corners can vary by two channel levels from antialiasing.
        // Compare decoded pixels, retaining sensitivity to the visible Selection fill.
        return zip(lhs.pixels, rhs.pixels).allSatisfy { abs(Int($0) - Int($1)) <= 2 }
    }

    @MainActor
    func assertViewer(_ app: XCUIApplication, filename: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        let marker = app.descendants(matching: .any).matching(identifier: "chrome.filename").firstMatch
        let identity = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "exists == true AND (value == %@ OR value BEGINSWITH %@)",
            filename, filename + " · "), object: marker)
        XCTAssertEqual(XCTWaiter.wait(for: [identity], timeout: 20), .completed,
            "Viewer must display \(filename)", file: file, line: line)
        let zoom = app.buttons["command.actualPixels.button"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"), object: zoom)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed,
            "Viewer image did not become ready for \(filename)", file: file, line: line)
    }

    @MainActor
    func assertValue(_ element: XCUIElement, equals value: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed,
            "Expected AX value \(value) on \(element.identifier); observed \(String(describing: element.value))",
            file: file, line: line)
    }

    @MainActor
    func assertMenuStates(_ app: XCUIApplication, imageCommands: Bool,
                          file: StaticString = #filePath, line: UInt = #line) {
        app.menuBars.menuBarItems["View"].click()
        for command in ["zoomIn", "zoomOut", "actualPixels", "fit", "inspector"] {
            let item = app.menuItems["command.\(command).menu"]
            XCTAssertTrue(item.waitForExistence(timeout: 10), file: file, line: line)
            XCTAssertEqual(item.isEnabled, command == "inspector" || imageCommands,
                "\(command) availability with imageCommands=\(imageCommands)", file: file, line: line)
        }
        // This Esc dismisses the tracked menu; the caller's next Esc acts on the viewer.
        app.typeKey(.escape, modifierFlags: [])
    }
}
