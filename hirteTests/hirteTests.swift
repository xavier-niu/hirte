import Foundation
import HerdrKit
import Testing
import UIKit
@testable import hirte

@MainActor
struct ThemeTests {
    @Test func bundledThemesLoad() {
        // More than the built-in fallback: themes.json is in the app and decodes.
        #expect(TerminalTheme.all.count > 1)
        #expect(!TerminalTheme.darkThemes.isEmpty)
        #expect(!TerminalTheme.lightThemes.isEmpty)
    }

    @Test func everyThemeHasSixteenColors() {
        for theme in TerminalTheme.all {
            #expect(theme.ansi.count == 16, "\(theme.id)")
        }
    }

    @Test func defaultsExistAndUnknownIdsFallBack() {
        #expect(TerminalTheme.find(TerminalTheme.defaultDark, dark: true).id == TerminalTheme.defaultDark)
        #expect(TerminalTheme.find(TerminalTheme.defaultLight, dark: false).id == TerminalTheme.defaultLight)
        #expect(TerminalTheme.find("no-such-theme", dark: true).id == TerminalTheme.defaultDark)
        // A dark theme's id asked for as light falls back to the light default.
        #expect(TerminalTheme.find(TerminalTheme.defaultDark, dark: false).id == TerminalTheme.defaultLight)
    }
}

@MainActor
struct HostTests {
    @Test func subtitleShowsPortOnlyWhenNotDefault() {
        var host = Host(name: "Mini", target: SSHTarget(host: "mini.local", username: "pavel"))
        #expect(host.subtitle == "pavel@mini.local")
        host.target.port = 2222
        #expect(host.subtitle == "pavel@mini.local:2222")
    }

    @Test func hostsSavedBeforeTheDemoExistedStillDecode() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Mini","target":{"host":"mini.local","port":22,"username":"pavel"}}]"#
        let hosts = try JSONDecoder().decode([Host].self, from: Data(json.utf8))
        #expect(hosts.first?.isDemo == false)
    }

    @Test func storePersistsAndAddsTheDemoOnce() throws {
        let suite = "hirteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = HostStore(defaults: defaults)
        store.save(Host(name: "Mini", target: SSHTarget(host: "mini.local", username: "pavel")))
        let demo = store.addDemo()
        #expect(store.addDemo().id == demo.id)

        let reloaded = HostStore(defaults: defaults)
        #expect(reloaded.hosts.map(\.name) == ["Mini", "Demo machine"])
        #expect(reloaded.hasDemo)
    }

    @Test func hostsSavedBeforePasswordsLogInWithTheirKey() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Mini","target":{"host":"mini.local","port":22,"username":"pavel"}}]"#
        let hosts = try JSONDecoder().decode([Host].self, from: Data(json.utf8))
        #expect(hosts.first?.usesPassword == false)
    }

    @Test func aNewMachineUsesItsKeyOrElseAPassword() {
        #expect(Host.new(key: UUID()).usesPassword == false)
        #expect(Host.new(key: nil).usesPassword)
    }

    @Test func passwordsStayOutOfTheSavedHostsAndGoWithTheirMachine() throws {
        let suite = "hirteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let passwords = PasswordStore(storage: InMemoryKeyStorage())
        let store = HostStore(defaults: defaults, passwords: passwords)

        var host = Host(name: "Mini", target: SSHTarget(host: "mini.local", username: "pavel"))
        host.usesPassword = true
        try store.save(host, password: "correct horse")
        #expect(try passwords.password(for: host.id) == "correct horse")
        #expect(store.hasPassword(for: host))
        let saved = try #require(defaults.data(forKey: "hirte.hosts"))
        #expect(!String(decoding: saved, as: UTF8.self).contains("correct horse"))

        // Saving without typing one keeps it.
        try store.save(host, password: nil)
        #expect(try passwords.password(for: host.id) == "correct horse")

        // Moving to a key forgets it, and so does deleting the machine.
        host.usesPassword = false
        try store.save(host, password: "ignored")
        #expect(try passwords.password(for: host.id) == nil)
        host.usesPassword = true
        try store.save(host, password: "battery staple")
        store.delete(at: [0])
        #expect(try passwords.password(for: host.id) == nil)
    }
}

@MainActor
struct ConnectionErrorTests {
    /// Trying a rejected login again and again can get the account locked or the address banned.
    @Test func aRejectedLoginIsNotRetried() {
        #expect(!HostSession.isRetryable(SSHTransportError.passwordRejected(username: "me")))
        #expect(!HostSession.isRetryable(SSHTransportError.authenticationFailed(username: "me")))
        #expect(!HostSession.isRetryable(SessionError.noPassword))
        #expect(!HostSession.isRetryable(SessionError.noKey))
    }

    @Test func aLostConnectionIsRetried() {
        #expect(HostSession.isRetryable(SessionError.connectionLost))
        #expect(HostSession.isRetryable(SessionError.timedOut))
    }
}

struct AgeTests {
    @Test func shortAgesLikeHerdrApp() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func age(_ seconds: TimeInterval) -> String { Terminal.shortAge(now.addingTimeInterval(-seconds), now: now) }
        #expect(age(59) == "now")
        #expect(age(-30) == "now")  // the machine's clock is ahead
        #expect(age(60) == "1m")
        #expect(age(47 * 60 + 59) == "47m")
        #expect(age(3 * 3600) == "3h")
        #expect(age(23 * 3600 + 3599) == "23h")
        #expect(age(2 * 86_400) == "2d")
    }
}

@MainActor
struct ScrollGlideTests {
    /// How far a glide goes, a frame at a time, until under half a point is left.
    private func coasted(_ start: ScrollGlide, framesPerSecond: Double) -> (travel: Double, seconds: Double) {
        var glide = start
        var travel = 0.0
        var frames = 0.0
        while abs(glide.travelLeft) >= 0.5 {
            travel += glide.advance(by: 1 / framesPerSecond)
            frames += 1
        }
        return (travel, frames / framesPerSecond)
    }

    @Test func decelerationIsUIKits() {
        #expect(abs(ScrollGlide.decelerationRate - Double(UIScrollView.DecelerationRate.normal.rawValue)) < 0.0001)
        #expect(abs(ScrollGlide.settlingRate - Double(UIScrollView.DecelerationRate.fast.rawValue)) < 0.0001)
    }

    @Test func aFlickCoastsForAboutHalfASecondOfItsSpeed() {
        let down = coasted(ScrollGlide(lift: 2000), framesPerSecond: 60).travel
        #expect(down > 990)
        #expect(down < 1000)
        #expect(abs(coasted(ScrollGlide(lift: -2000), framesPerSecond: 60).travel + down) < 0.001)
    }

    @Test func theFrameRateChangesNothing() {
        let slow = coasted(ScrollGlide(lift: 2000), framesPerSecond: 60).travel
        let fast = coasted(ScrollGlide(lift: 2000), framesPerSecond: 120).travel
        #expect(abs(slow - fast) < 1)
    }

    @Test func aboutASeventhOfTheSpeedIsLeftAfterASecond() {
        var glide = ScrollGlide(lift: 2000)
        _ = glide.advance(by: 1)
        #expect(abs(glide.velocity - 270) < 1)
    }

    @Test func aFlickAddsToTheGlideItsTouchStopped() {
        #expect(ScrollGlide(lift: 1000, interrupted: 800, heldFor: 0.1).velocity == 1800)
        #expect(ScrollGlide(lift: -1000, interrupted: -800, heldFor: 0.1).velocity == -1800)
    }

    @Test func turningAroundOrHoldingStillStartsAfresh() {
        #expect(ScrollGlide(lift: -1000, interrupted: 800, heldFor: 0.1).velocity == -1000)
        #expect(ScrollGlide(lift: 1000, interrupted: 800, heldFor: ScrollGlide.carryTime + 0.1).velocity == 1000)
    }

    /// A small move stays where it was left, also when its touch stopped a glide.
    @Test func aSlowLiftDoesNotGlide() {
        for lift in [0.0, 50, -100, 299, -299] {
            #expect(ScrollGlide(lift: lift).velocity == 0, "\(lift)")
            #expect(ScrollGlide(lift: lift, interrupted: lift < 0 ? -2000 : 2000, heldFor: 0.1).velocity == 0, "\(lift)")
        }
    }

    @Test func aFirmFlickGlidesInFull() {
        for lift in [ScrollGlide.fullGlideSpeed, -ScrollGlide.fullGlideSpeed, 2000, -5000] {
            #expect(ScrollGlide(lift: lift).velocity == lift, "\(lift)")
        }
    }

    /// In between, a little more speed never means suddenly many more lines.
    @Test func theGlideBuildsUpSmoothly() {
        #expect(ScrollGlide(lift: 550).velocity == 275)
        var last = 0.0
        for lift in stride(from: 300.0, through: 800, by: 5) {
            let velocity = ScrollGlide(lift: lift).velocity
            #expect(velocity >= last, "\(lift)")
            #expect(velocity - last <= 15, "\(lift)")
            last = velocity
        }
    }

    @Test func repeatedFlicksHaveALimit() {
        #expect(ScrollGlide(lift: 10_000, interrupted: 10_000).velocity == ScrollGlide.maxSpeed)
        #expect(ScrollGlide(lift: -10_000, interrupted: -10_000).velocity == -ScrollGlide.maxSpeed)
    }

    /// The text comes to rest on a line, whatever the speed and however far off one it starts.
    @Test func aGlideLandsOnALine() {
        for lift in [0.0, 50, -90, 700, 2000, -2000, 15_000] {
            for offset in [0.0, 5, -7, 17, -17] {
                var glide = ScrollGlide(lift: lift)
                glide.land(onMultiplesOf: 18, from: offset)
                let lines = (glide.travelLeft + offset) / 18
                #expect(abs(lines - lines.rounded()) < 0.000001, "\(lift) from \(offset)")
            }
        }
    }

    @Test func landingBarelyChangesWhereAFlickGoes() {
        let flick = ScrollGlide(lift: 2000)
        var landing = flick
        landing.land(onMultiplesOf: 18, from: 5)
        #expect(abs(landing.travelLeft - flick.travelLeft) <= 9 + 5)
        #expect(landing.velocity > 0)
    }

    /// After a slow lift the text finds its line quickly: a long slow crawl looks like lag.
    @Test func aSlowLiftSettlesOnTheNearestLineQuickly() {
        var back = ScrollGlide(lift: 0)
        back.land(onMultiplesOf: 18, from: 8)
        #expect(abs(back.travelLeft + 8) < 0.000001)
        #expect(coasted(back, framesPerSecond: 60).seconds < 0.5)

        var onward = ScrollGlide(lift: 0)
        onward.land(onMultiplesOf: 18, from: 10)
        #expect(abs(onward.travelLeft - 8) < 0.000001)
    }
}

@MainActor
struct TerminalTextInputTests {
    @Test func theDeleteKeyAlwaysHasSomethingToAskFor() throws {
        let view = TerminalCanvasView()
        #expect(view.hasText)
        let selection = try #require(view.selectedTextRange)
        #expect(view.text(in: selection) == "")
    }

    @Test func compositionLastsUntilCommitted() throws {
        let view = TerminalCanvasView()
        #expect(view.markedTextRange == nil)
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        let marked = try #require(view.markedTextRange)
        #expect(view.text(in: marked) == "ni")
        view.unmarkText()
        #expect(view.markedTextRange == nil)
    }

    @Test func typingEndsAComposition() {
        let view = TerminalCanvasView()
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        view.insertText("你")
        #expect(view.markedTextRange == nil)
    }
}
