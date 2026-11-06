import XCTest

/// Walks through the demo machine. Set HIRTE_SHOTS (TEST_RUNNER_HIRTE_SHOTS for xcodebuild)
/// to a folder to also save screenshots there, e.g. for the App Store.
final class DemoTourTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDemoTour() throws {
        let app = XCUIApplication()
        let environment = ProcessInfo.processInfo.environment
        if environment["HIRTE_SHOTS"] != nil {
            // Screenshots: English, and a terminal font that fills the screen without wrapping.
            let fontSize = environment["HIRTE_SHOT_FONT"] ?? "17"
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-terminal.fontSize", fontSize]
        }
        app.launch()

        startDemo(app)

        XCTAssertTrue(blockedRow(app).waitForExistence(timeout: 10), "demo spaces appear")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "t3").firstMatch.exists)
        sleep(1)
        shot(app, "1-terminals")

        open(app, "t1")
        sleep(2)
        shot(app, "2-agent")
        back(app)

        open(app, "t3")
        sleep(2)
        shot(app, "3-needs-you")
        back(app)

        // A shell with the keyboard and key bar up.
        open(app, "t5")
        sleep(1)
        let keyboard = app.buttons["Show Keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        keyboard.tap()
        sleep(1)
        // iOS explains slide-to-type the first time a keyboard appears.
        let hint = app.buttons["Continue"]
        if hint.waitForExistence(timeout: 2) { hint.tap() }
        app.typeText("git status\n")
        sleep(1)
        shot(app, "4-shell")
        app.buttons["Hide Keyboard"].tap()
        back(app)

        open(app, "t2")
        sleep(4)
        shot(app, "5-tests")
    }

    /// The README video, recorded by `scripts/video.sh`: the demo at a pace people can follow.
    /// Only runs with HIRTE_VIDEO set to a folder; it writes `start` and `end` (Unix times) there,
    /// so the script can cut the recording to the app.
    @MainActor
    func testVideoTour() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let marks = environment["HIRTE_VIDEO"] else { throw XCTSkip("HIRTE_VIDEO is not set") }
        let app = XCUIApplication()
        let fontSize = environment["HIRTE_SHOT_FONT"] ?? "15"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-terminal.fontSize", fontSize]
        app.launch()
        let tryDemo = app.buttons["Try the Demo"]
        XCTAssertTrue(tryDemo.waitForExistence(timeout: 10), "a fresh install offers the demo")
        mark(marks, "start")
        pause(1.5)
        tryDemo.tap()

        // Everything at a glance; the blocked agent sits on top.
        XCTAssertTrue(blockedRow(app).waitForExistence(timeout: 10))
        pause(3)

        // An agent at work.
        open(app, "t1")
        pause(3)
        back(app)
        pause(1)

        // The blocked one: answer in a tap and watch it go.
        open(app, "t3")
        pause(2.5)
        let yes = app.buttons["Yes"]
        XCTAssertTrue(yes.waitForExistence(timeout: 5), "the needs-you bar shows")
        yes.tap()
        pause(5)
        back(app)
        pause(2)

        // A real terminal: type, then pinch to zoom.
        open(app, "t5")
        pause(1)
        app.buttons["Show Keyboard"].tap()
        pause(1)
        let hint = app.buttons["Continue"]
        if hint.waitForExistence(timeout: 2) { hint.tap() }
        for character in "git log" {
            app.typeText(String(character))
            pause(0.08)
        }
        app.typeText("\n")
        pause(1.5)
        app.buttons["Hide Keyboard"].tap()
        pause(0.5)
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        screen.pinch(withScale: 2.2, velocity: 1.5)
        pause(2)
        screen.pinch(withScale: 0.45, velocity: -1.5)
        pause(1.5)
        back(app)
        // Back on the list: the migration went through.
        pause(2.5)
        mark(marks, "end")
    }

    /// The video on a real device (`scripts/video-device.sh`), made for the unfolded iPhone Duo: the
    /// app records itself (ReplayKit, Debug builds) and stops when the test sends it home. Opens the
    /// demo machine without touching the other machines. Only runs with HIRTE_DEVICE_VIDEO set.
    @MainActor
    func testDeviceVideoTour() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["HIRTE_DEVICE_VIDEO"] else { throw XCTSkip("HIRTE_DEVICE_VIDEO is not set") }
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-hirte.demo", "YES", "-hirte.record", name]
        if let fontSize = environment["HIRTE_SHOT_FONT"] { app.launchArguments += ["-terminal.fontSize", fontSize] }
        app.launch()
        allowScreenRecording(app)
        XCTAssertTrue(blockedRow(app).waitForExistence(timeout: 10), "the demo's terminals show")
        pause(2.5)

        // An agent at work.
        open(app, "t1")
        pause(3)
        backIfStacked(app)

        // The blocked one: answer in a tap and watch it go.
        open(app, "t3")
        pause(2.5)
        let yes = app.buttons["Yes"]
        XCTAssertTrue(yes.waitForExistence(timeout: 5), "the needs-you bar shows")
        yes.tap()
        pause(5)
        backIfStacked(app)

        // A real terminal: type, then pinch to zoom.
        open(app, "t5")
        pause(1)
        app.buttons["Show Keyboard"].tap()
        pause(1)
        let hint = app.buttons["Continue"]
        if hint.waitForExistence(timeout: 2) { hint.tap() }
        app.typeText("git log")
        pause(0.5)
        app.typeText("\n")
        pause(2)
        app.buttons["Hide Keyboard"].tap()
        pause(0.5)
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        screen.pinch(withScale: 2.2, velocity: 1.5)
        pause(2)
        screen.pinch(withScale: 0.45, velocity: -1.5)
        pause(1.5)
        backIfStacked(app)

        // Tests streaming in.
        open(app, "t2")
        pause(4)

        // Home: the app stops recording and writes the file.
        XCUIDevice.shared.press(.home)
        pause(4)
    }

    /// iOS asks before an app records its screen (again after some minutes). Taps the button that
    /// allows it, in any language: the one that isn't "Don't Allow" / "Nicht erlauben".
    @MainActor
    private func allowScreenRecording(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            for alert in [springboard.alerts.firstMatch, app.alerts.firstMatch] where alert.exists {
                let refuse = NSPredicate(format: "label CONTAINS[c] 'don' OR label CONTAINS[c] 'nicht' OR label CONTAINS[c] 'not'")
                let accept = alert.buttons.allElementsBoundByIndex.first { !refuse.evaluate(with: $0) }
                accept?.tap()
                return
            }
            pause(0.2)
        }
    }

    /// Two columns (unfolded Duo) keep the list next to the terminal; a stack needs going back.
    @MainActor
    private func backIfStacked(_ app: XCUIApplication) {
        let list = blockedRow(app)
        if !(list.exists && list.isHittable) { back(app) }
        pause(1)
    }

    private func pause(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func mark(_ folder: String, _ name: String) {
        let now = String(Date().timeIntervalSince1970)
        try? now.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Pinch to zoom: the font changes once per gesture and the screen comes back crisp.
    @MainActor
    func testPinchZoom() throws {
        let app = XCUIApplication()
        app.launch()
        startDemo(app)
        open(app, "t5")
        sleep(2)
        shot(app, "zoom-0-start")
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        screen.pinch(withScale: 1.6, velocity: 1)
        sleep(1)
        shot(app, "zoom-1-in")
        screen.pinch(withScale: 0.6, velocity: -1)
        sleep(1)
        shot(app, "zoom-2-out")
    }

    /// The key bar: its keys scroll, also from a drag that starts on one, and Shift applies to the
    /// next key, whichever that is. ^C stays an interrupt, so it lets go of Shift.
    @MainActor
    func testKeyBar() throws {
        let app = XCUIApplication()
        app.launch()
        startDemo(app)
        open(app, "t5")
        sleep(2)
        let keyboard = app.buttons["Show Keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        keyboard.tap()
        // iOS explains slide-to-type the first time a keyboard appears.
        let hint = app.buttons["Continue"]
        if hint.waitForExistence(timeout: 2) { hint.tap() }

        let shift = app.buttons["Shift"]
        XCTAssertTrue(shift.waitForExistence(timeout: 5), "the key bar shows Shift")
        shift.tap()
        XCTAssertTrue(shift.isSelected, "Shift stays on for the next key")
        shot(app, "key-bar-0-start")

        let keys = app.scrollViews["key-bar"]
        keys.swipeLeft()
        sleep(1)
        let right = app.buttons["Right"]
        XCTAssertTrue(right.isHittable, "the last key scrolls into view")
        XCTAssertTrue(shift.isSelected, "a drag isn't a key press")
        XCTAssertTrue(app.buttons["Hide keyboard"].isHittable, "hiding the keyboard stays in reach")
        shot(app, "key-bar-1-end")
        right.tap()
        sleep(1)
        XCTAssertFalse(shift.isSelected, "Shift applied to that key")

        keys.swipeRight()
        sleep(1)
        shift.tap()
        app.buttons["Control C"].tap()
        sleep(1)
        XCTAssertFalse(shift.isSelected, "^C lets go of Shift")
    }

    /// Watch Only: the terminal opens as an observer; tapping it takes over (and the choice is
    /// remembered for the next terminal until it's switched off).
    @MainActor
    func testWatchOnly() throws {
        let app = XCUIApplication()
        app.launch()
        startDemo(app)
        open(app, "t5")
        let watch = app.buttons["Watch Only"]
        XCTAssertTrue(watch.waitForExistence(timeout: 5))
        watch.tap()
        // The subtitle says so (the size the other viewer set).
        let banner = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Watching'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "watching shows in the title")
        shot(app, "watch-0-watching")
        // Typing takes over: the keyboard comes up and the banner goes.
        app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch.tap()
        let hint = app.buttons["Continue"]
        if hint.waitForExistence(timeout: 2) { hint.tap() }
        XCTAssertTrue(app.buttons["Hide Keyboard"].waitForExistence(timeout: 5), "tapping brings up the keyboard")
        XCTAssertFalse(banner.exists, "and takes over")
        sleep(1)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Another viewer'")).firstMatch.exists,
                       "taking over sets the size, also with the keyboard up")
        XCTAssertTrue(app.buttons["Watch Only"].exists)
        shot(app, "watch-1-taken-over")
        // Watching again puts the keyboard away.
        app.buttons["Watch Only"].tap()
        XCTAssertTrue(app.buttons["Show Keyboard"].waitForExistence(timeout: 5), "watching hides the keyboard")
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        back(app)
        // Remembered: the next terminal opens watching. Switch it off again for the other tests.
        open(app, "t1")
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "the next terminal opens watching")
        app.buttons["Take Over"].tap()
        XCTAssertTrue(app.buttons["Watch Only"].waitForExistence(timeout: 5))
        XCTAssertFalse(banner.exists)
    }

    /// Long-pressing a live row shows its screen above the menu, watched (no attach, no resize).
    @MainActor
    func testRowPreview() throws {
        let app = XCUIApplication()
        app.launch()
        startDemo(app)
        app.buttons["Terminals"].tap()
        let row = app.descendants(matching: .any).matching(identifier: "t5").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Copy Address"].waitForExistence(timeout: 5), "the menu opens")
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 5), "with the terminal's screen above it")
        sleep(1)
        shot(app, "preview-0-menu")
        // Closing the menu leaves the list as it was.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: screen)
        wait(for: [gone], timeout: 5)

        // "Watch" opens it watching, without changing what the eye button remembers.
        row.press(forDuration: 1.2)
        let watch = app.buttons["Watch"]
        XCTAssertTrue(watch.waitForExistence(timeout: 5))
        watch.tap()
        let watching = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Watching'")).firstMatch
        XCTAssertTrue(watching.waitForExistence(timeout: 5), "the terminal opens watching")
        shot(app, "preview-1-watch")
        back(app)
        open(app, "t5")
        XCTAssertTrue(app.buttons["Watch Only"].waitForExistence(timeout: 5), "opening it normally doesn't watch")
        XCTAssertFalse(watching.exists)
    }

    /// Agents lists only agents, with their status; Terminals lists every terminal by space.
    @MainActor
    func testAgentsAndTerminals() throws {
        let app = XCUIApplication()
        app.launch()
        startDemo(app)
        // Not a launch argument: those win over what the app saves, so switching wouldn't stick.
        app.buttons["Agents"].tap()
        let shell = app.descendants(matching: .any).matching(identifier: "t5").firstMatch
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "t3").firstMatch.exists, "the blocked agent")
        XCTAssertFalse(shell.exists, "the shell is not an agent")
        shot(app, "view-agents")
        app.buttons["Terminals"].tap()
        XCTAssertTrue(shell.waitForExistence(timeout: 5), "the terminals view lists the shell")
        shot(app, "view-terminals")
        // Finished terminals are in a section of their own at the bottom, collapsed at first
        // (the simulator may remember it open from an earlier run).
        let backup = app.descendants(matching: .any).matching(identifier: "t7").firstMatch
        let finished = app.staticTexts["Finished"]
        let list = app.collectionViews.firstMatch
        for _ in 0..<4 where !(finished.exists && finished.isHittable) { list.swipeUp() }
        XCTAssertTrue(finished.isHittable, "the Finished section is listed")
        if !backup.exists { finished.tap() }
        XCTAssertTrue(backup.waitForExistence(timeout: 5), "opening it shows the finished backup")
        shot(app, "view-terminals-finished")
        finished.tap()
        sleep(1)
        XCTAssertFalse(backup.exists, "collapsing it hides the finished backup")
        app.buttons["Agents"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "t3").firstMatch.waitForExistence(timeout: 5))
    }

    /// Agents are grouped by status, "Needs you" first; done means unread (herdr's shared
    /// `herdr.seen`): looking at one makes it idle, and Mark as Unread brings it back.
    @MainActor
    func testAgentsByStatus() throws {
        let app = XCUIApplication()
        app.launch()
        startDemo(app)
        app.buttons["Agents"].tap()
        func section(_ state: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: "section-\(state)").firstMatch
        }
        for state in ["needsYou", "done", "working"] {
            XCTAssertTrue(section(state).waitForExistence(timeout: 5), "a \(state) section")
        }
        let upgrade = app.descendants(matching: .any).matching(identifier: "t6").firstMatch
        XCTAssertTrue(upgrade.exists, "the unread upgrade is under Done")
        XCTAssertLessThan(blockedRow(app).frame.minY, upgrade.frame.minY, "what needs you comes first")
        shot(app, "status-0-agents")

        // The dot explains itself.
        let dot = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Needs you, since'")).firstMatch
        XCTAssertTrue(dot.label.contains("12 minutes"), "with how long it has waited: \(dot.label)")
        XCTAssertTrue(app.staticTexts["12m"].exists, "shown short in the row")
        dot.tap()
        XCTAssertTrue(app.staticTexts["Needs you: waiting for your answer."].waitForExistence(timeout: 5))
        shot(app, "status-1-legend")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()

        // Looking at it reads it: it moves to Idle, which starts collapsed.
        open(app, "t6")
        sleep(2)
        back(app)
        let idle = section("idle")
        XCTAssertTrue(idle.waitForExistence(timeout: 5), "an Idle section once it's read")
        if !upgrade.waitForExistence(timeout: 2) { idle.tap() }
        XCTAssertTrue(upgrade.waitForExistence(timeout: 5))
        XCTAssertLessThan(idle.frame.minY, upgrade.frame.minY, "it's under Idle now")
        shot(app, "status-2-read")

        // Swipe from the left: Mark as Unread puts it back under Done.
        upgrade.swipeRight()
        let unread = app.buttons["Mark as Unread"]
        XCTAssertTrue(unread.waitForExistence(timeout: 5))
        unread.tap()
        XCTAssertTrue(section("done").waitForExistence(timeout: 5), "back under Done")
        sleep(1)
        XCTAssertLessThan(upgrade.frame.minY, idle.exists ? idle.frame.minY : .infinity, "above Idle again")
        shot(app, "status-3-unread")
    }

    /// "Clear" in the open Finished section removes all finished terminals, after asking.
    @MainActor
    func testClearFinished() throws {
        let app = XCUIApplication()
        app.launch()
        startDemo(app)
        app.buttons["Terminals"].tap()
        let backup = app.descendants(matching: .any).matching(identifier: "t7").firstMatch
        let finished = app.staticTexts["Finished"]
        let list = app.collectionViews.firstMatch
        for _ in 0..<4 where !(finished.exists && finished.isHittable) { list.swipeUp() }
        XCTAssertTrue(finished.isHittable, "the Finished section is listed")
        if !backup.exists { finished.tap() }
        XCTAssertTrue(backup.waitForExistence(timeout: 5), "opening it shows the finished backup")
        let clear = app.buttons["Clear"]
        XCTAssertTrue(clear.isHittable, "the open section offers Clear")
        shot(app, "finished-clear")
        clear.tap()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "Clear asks first")
        shot(app, "finished-clear-confirm")
        remove.tap()
        XCTAssertTrue(finished.waitForNonExistence(timeout: 5), "the section goes once it's empty")
        XCTAssertFalse(backup.exists)
    }

    /// Each view keeps its scroll position when switching away and back. Large text makes the
    /// demo list longer than the screen.
    @MainActor
    func testViewsKeepScrollPosition() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        startDemo(app)
        app.buttons["Terminals"].tap()
        let infra = app.descendants(matching: .any).matching(identifier: "t6").firstMatch
        let list = app.collectionViews.firstMatch
        for _ in 0..<4 where !(infra.exists && infra.isHittable) { list.swipeUp() }
        XCTAssertTrue(infra.isHittable, "scrolled down to the last terminal")
        shot(app, "scroll-0-terminals-bottom")
        app.buttons["Agents"].tap()
        sleep(1)
        app.buttons["Terminals"].tap()
        sleep(1)
        shot(app, "scroll-1-terminals-back")
        XCTAssertTrue(infra.waitForExistence(timeout: 3) && infra.isHittable, "still scrolled down after switching back")
    }

    /// One sidebar: the machine is picked from the list's title.
    @MainActor
    func testMachineSwitcher() throws {
        let app = XCUIApplication()
        app.launch()
        startDemo(app)
        XCTAssertTrue(blockedRow(app).waitForExistence(timeout: 10), "the demo's terminals show")
        shot(app, "switcher-0-list")
        // The title is a menu button: "Demo machine ⌄".
        app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demo machine'")).firstMatch.tap()
        let manage = app.buttons["Manage Machines…"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5), "the title opens the switcher")
        shot(app, "switcher-1-menu")
        manage.tap()
        XCTAssertTrue(app.navigationBars["Machines"].waitForExistence(timeout: 5))
        shot(app, "switcher-2-manage")
    }

    /// Holding the system keyboard's delete key keeps deleting, past spaces too. The screen's text
    /// can't be read from here, so this can't fail for it: look at the screenshots.
    @MainActor
    func testHoldingDelete() throws {
        let app = XCUIApplication()
        app.launch()
        startDemo(app)
        open(app, "t5")
        let showKeyboard = app.buttons["Show Keyboard"]
        XCTAssertTrue(showKeyboard.waitForExistence(timeout: 5))
        showKeyboard.tap()
        let hint = app.buttons["Continue"]
        if hint.waitForExistence(timeout: 2) { hint.tap() }
        let delete = app.keys["delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the system keyboard shows")
        app.typeText("some words to delete, and more of them")
        sleep(1)
        shot(app, "delete-0-typed")
        delete.tap()
        sleep(1)
        shot(app, "delete-1-tapped")
        delete.press(forDuration: 2)
        sleep(1)
        shot(app, "delete-2-held")
    }

    /// A machine can log in with a password: Save waits for one. Cancelled in the end, so nothing
    /// stays behind in the Keychain or the list.
    @MainActor
    func testPasswordInMachineEditor() throws {
        let app = XCUIApplication()
        app.launch()
        startDemo(app)
        app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demo machine'")).firstMatch.tap()
        let add = app.buttons["Add Machine…"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "the title menu offers Add Machine")
        add.tap()
        let host = app.textFields["Host"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.tap()
        let hint = app.buttons["Continue"]
        if hint.waitForExistence(timeout: 2) { hint.tap() }
        host.typeText("server.example.com")
        let user = app.textFields["User"]
        user.tap()
        user.typeText("me")
        // It starts on a password only when there are no keys.
        let password = app.secureTextFields["Password"]
        if !password.exists {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Log In With'")).firstMatch.tap()
            app.buttons["Password"].tap()
        }
        XCTAssertTrue(password.waitForExistence(timeout: 5), "the password field shows")
        let save = app.buttons["Save"]
        XCTAssertFalse(save.isEnabled, "Save waits for a password")
        shot(app, "password-0-empty")
        password.tap()
        password.typeText("not a real password")
        XCTAssertTrue(save.isEnabled, "a password is enough to save")
        shot(app, "password-1-typed")
        app.buttons["Cancel"].tap()
    }

    /// Settings: the font preview, the demo button and About.
    @MainActor
    func testSettings() throws {
        let app = XCUIApplication()
        app.launch()
        openSettings(app)
        XCTAssertTrue(app.staticTexts["Terminal"].waitForExistence(timeout: 5))
        shot(app, "settings")
        // A row's label is its title and value: "Dark Theme, Hirte Dark".
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dark Theme'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Dracula"].waitForExistence(timeout: 5))
        shot(app, "settings-dark-themes")
        back(app)

        // Licenses: the list, then one license's text.
        app.swipeUp()
        let licenses = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open-Source Licenses'")).firstMatch
        XCTAssertTrue(licenses.waitForExistence(timeout: 5))
        licenses.tap()
        let ghostty = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ghostty'")).firstMatch
        XCTAssertTrue(ghostty.waitForExistence(timeout: 5), "the licenses list shows")
        shot(app, "settings-licenses")
        ghostty.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'MIT License'")).firstMatch
            .waitForExistence(timeout: 5), "a license's text shows")
        shot(app, "settings-license-ghostty")
    }

    /// The appearance setting reaches sheets too, and switching it applies at once (also back to System).
    @MainActor
    func testAppearanceInSettings() throws {
        let app = XCUIApplication()
        app.launch()
        openSettings(app)
        XCTAssertTrue(app.staticTexts["Terminal"].waitForExistence(timeout: 5))
        app.buttons["Dark"].tap()
        sleep(1)
        shot(app, "appearance-dark")
        app.buttons["Light"].tap()
        sleep(1)
        shot(app, "appearance-light")
        app.buttons["System"].tap()
        sleep(1)
        shot(app, "appearance-system")
    }

    /// A light terminal theme: the screen, its title bar and the keyboard follow it.
    @MainActor
    func testLightTheme() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-appearance", "light", "-theme.light", "catppuccin-latte", "-terminal.fontSize", "15"]
        app.launch()
        startDemo(app)
        open(app, "t1")
        sleep(2)
        shot(app, "theme-light-agent")
        back(app)
        open(app, "t3")
        sleep(2)
        shot(app, "theme-light-needs-you")
    }

    /// A fresh install offers the demo in its empty state; later launches open on the last machine.
    /// The demo's blocked agent: listed in both views, so the list is on screen when it is.
    private func blockedRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "t3").firstMatch
    }

    @MainActor
    private func startDemo(_ app: XCUIApplication) {
        let tryDemo = app.buttons["Try the Demo"]
        if tryDemo.waitForExistence(timeout: 5) { tryDemo.tap() }
        XCTAssertTrue(blockedRow(app).waitForExistence(timeout: 10), "the demo's terminals show")
    }

    /// Settings is in the title menu, below the machines.
    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        startDemo(app)
        app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demo machine'")).firstMatch.tap()
        let settings = app.buttons["Settings…"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "the title menu offers Settings")
        settings.tap()
    }

    @MainActor
    private func open(_ app: XCUIApplication, _ address: String) {
        // Rows carry their terminal's address as identifier (the address itself isn't shown).
        // The agents view lists only agents; anything else is in the terminals view.
        let row = app.descendants(matching: .any).matching(identifier: address).firstMatch
        if !row.waitForExistence(timeout: 3) { app.buttons["Terminals"].tap() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(address) is listed")
        row.tap()
    }

    @MainActor
    private func back(_ app: XCUIApplication) {
        // The back button sits in a side rail on wide screens, in the navigation bar otherwise.
        for candidate in [app.buttons["BackButton"], app.buttons["Demo machine"], app.buttons["Back"]] where candidate.exists {
            candidate.tap()
            return
        }
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["HIRTE_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }
}
