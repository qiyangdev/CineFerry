//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

#if os(iOS)
import XCTest

final class IOSServiceBaselineTests: XCTestCase {

    private enum Service: String {

        case emby
        case jellyfin
    }

    private struct Configuration {

        let url: String
        let username: String
        let password: String
        let title: String

        init(service: Service, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
            let prefix = "CINEFERRY_BASELINE_"
            guard environment[prefix + "SERVICE"]?.lowercased() == service.rawValue else {
                throw XCTSkip("Select \(service.rawValue) with CINEFERRY_BASELINE_SERVICE to run this baseline.")
            }
            guard let url = environment[prefix + "URL"],
                  !url.isEmpty,
                  let username = environment[prefix + "USERNAME"],
                  !username.isEmpty,
                  let password = environment[prefix + "PASSWORD"],
                  let title = environment[prefix + "TITLE"],
                  !title.isEmpty
            else {
                throw XCTSkip("Set the baseline URL, username, password and fixture title.")
            }

            self.url = url
            self.username = username
            self.password = password
            self.title = title
        }
    }

    private struct PlaybackFailure: Error, LocalizedError {

        let errorDescription: String?

        init(_ message: String) {
            errorDescription = message
        }
    }

    private let cappedQuality = "420.0 kbps"

    @MainActor
    func testEmby() throws {
        try runBaseline(for: .emby)
    }

    @MainActor
    func testJellyfin() throws {
        try runBaseline(for: .jellyfin)
    }

    @MainActor
    func testEmbyEpisodeResume() throws {
        try runEpisodeResume(for: .emby)
    }

    @MainActor
    func testJellyfinEpisodeResume() throws {
        try runEpisodeResume(for: .jellyfin)
    }

    @MainActor
    private func runEpisodeResume(for service: Service) throws {
        let configuration = try Configuration(service: service)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        XCUIDevice.shared.orientation = .portrait
        let robot = Robot(app: app)
        app.launch()
        try signIn(configuration, in: app)

        _ = robot.media().library("CineFerry Episode Library").item(configuration.title)
        let secondEpisode = robot.buttons(containing: "Second Fixture").firstMatch
        robot.reveal(secondEpisode)
        robot.tap(secondEpisode)

        try startEpisodePlayer(in: app)
        let start = try playbackTime(in: app, atLeast: 1, phase: "Initial episode playback")
        try assertEpisodeIdentity(in: robot)
        let advancing = try playbackTime(in: app, atLeast: start + 8, phase: "Episode playback")
        let stopped = try stopPlayer(in: app, fallbackTime: advancing, requiresDetail: false)
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        app.terminate()
        app.launch()

        robot.home()
        XCTAssertTrue(app.staticTexts[L10n.continue].firstMatch.waitForExistence(timeout: 20))
        let resumeCard = robot.buttons(containing: "Second Fixture").firstMatch
        robot.reveal(resumeCard)
        robot.tap(resumeCard)
        try startEpisodePlayer(in: app)
        let resumed = try playbackTime(in: app, atLeast: 1, phase: "Cold episode resume")
        try assertEpisodeIdentity(in: robot)
        guard resumed >= max(start + 4, stopped - 5), resumed <= stopped + 15 else {
            throw PlaybackFailure("Episode resumed at \(resumed)s after stopping at \(stopped)s.")
        }

        let final = try playbackTime(in: app, atLeast: resumed + 3, phase: "Episode resume advancement")
        _ = try stopPlayer(in: app, fallbackTime: final, requiresDetail: false)
        print("BASELINE \(service.rawValue) episode S1:E2 stopped \(stopped)s, cold resume \(resumed) -> \(final)s")
    }

    @MainActor
    private func startEpisodePlayer(in app: XCUIApplication) throws {
        let close = app.buttons["closePlayerButton"].firstMatch
        if !close.waitForExistence(timeout: 3) {
            let play = app.buttons[L10n.play].firstMatch
            guard waitForHittable(play, in: app, timeout: 12) else {
                throw PlaybackFailure("The episode detail did not present a Play button.")
            }

            play.tap()
        }
        XCTAssertTrue(close.waitForExistence(timeout: 16))
    }

    @MainActor
    private func assertEpisodeIdentity(in robot: Robot) throws {
        showControls(in: robot.app)
        let episode = robot.app
            .staticTexts
            .matching(
                NSPredicate(format: "label CONTAINS %@", L10n.seasonAndEpisode(1, 2))
            )
            .firstMatch
        guard episode.waitForExistence(timeout: 6) else {
            throw PlaybackFailure("The player did not identify the item as season 1, episode 2.")
        }
    }

    @MainActor
    private func runBaseline(for service: Service) throws {
        let configuration = try Configuration(service: service)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        try signIn(configuration, in: app)
        print("BASELINE \(service.rawValue) signed in")
        try openPlayer(for: configuration.title, in: app)
        let initial = try playbackTime(in: app, atLeast: 1, phase: "Auto start")
        let auto = try playbackTime(in: app, atLeast: initial + 8, phase: "Auto advancement")
        try checkPlaybackQuality(L10n.auto, switchingTo: service == .emby ? cappedQuality : nil, in: app)
        print("BASELINE \(service.rawValue) Auto \(initial) -> \(auto) seconds")

        var lastPlayed = auto
        if service == .emby {
            print("BASELINE \(service.rawValue) selected 420 kbps")
            let cappedStart = try playbackTime(in: app, atLeast: 1, phase: "420 kbps start")
            lastPlayed = try playbackTime(in: app, atLeast: cappedStart + 8, phase: "420 kbps advancement")
            try checkPlaybackQuality(cappedQuality, in: app)
            print("BASELINE \(service.rawValue) 420 kbps \(cappedStart) -> \(lastPlayed) seconds")
        }

        let stopped = try stopPlayer(in: app, fallbackTime: lastPlayed)
        // Give the queued stop report time to reach the server before dropping client memory.
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        app.terminate()
        app.launch()

        try openPlayer(for: configuration.title, in: app)
        let resumed = try playbackTime(in: app, atLeast: 1, phase: "First timeline after cold launch")
        guard resumed >= max(initial + 4, stopped - 5), resumed <= stopped + 15 else {
            throw PlaybackFailure("Resumed at \(resumed)s after stopping at \(stopped)s.")
        }

        let advancing = try playbackTime(in: app, atLeast: resumed + 3, phase: "Cold resume advancement")
        try checkPlaybackQuality(L10n.auto, in: app)
        _ = try stopPlayer(in: app, fallbackTime: advancing)
        print("BASELINE \(service.rawValue) stopped \(stopped)s, cold resume \(resumed) -> \(advancing) seconds")
    }

    @MainActor
    private func signIn(_ configuration: Configuration, in app: XCUIApplication) throws {
        let connect = app.buttons[L10n.connect].firstMatch
        guard waitForHittable(connect, in: app, timeout: 12) else {
            throw PlaybackFailure("Expected the Connect screen on a fresh simulator.")
        }

        connect.tap()

        let url = app.textFields[L10n.url].firstMatch
        guard waitForHittable(url, in: app, timeout: 10) else {
            throw PlaybackFailure("The server URL field did not appear.")
        }

        url.tap()
        typeText(configuration.url, into: url)
        guard url.value as? String == configuration.url else {
            throw PlaybackFailure("The server URL field did not retain the configured text.")
        }

        let center = CGPoint(x: url.frame.midX, y: url.frame.midY)
        let connectButtons = Robot(app: app).buttons(labeled: L10n.connect).allElementsBoundByIndex
        let submit = connectButtons.filter { canTap($0, in: app) }.min {
            hypot($0.frame.midX - center.x, $0.frame.midY - center.y) <
                hypot($1.frame.midX - center.x, $1.frame.midY - center.y)
        }
        guard let submit else { throw PlaybackFailure("The server Connect button did not appear.") }

        submit.tap()

        let username = app.textFields[L10n.username].firstMatch
        let addUser = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", L10n.addUser)).firstMatch
        let publicUser = app.buttons[configuration.username].firstMatch
        let entry = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", L10n.addUser)).firstMatch
        let deadline = Date().addingTimeInterval(18)
        while !username.exists, Date() < deadline {
            if let button = [addUser, entry, publicUser].first(where: { canTap($0, in: app) }) {
                button.tap()
                break
            }
            guard !app.alerts.firstMatch.exists else { throw PlaybackFailure("Connecting to the server displayed an alert.") }

            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        guard username.waitForExistence(timeout: 10) else {
            throw PlaybackFailure("The server sign-in form did not appear.")
        }

        if username.value as? String != configuration.username {
            guard canTap(username, in: app) else { throw PlaybackFailure("The username field was not editable.") }

            username.tap()
            typeText(configuration.username, into: username)
            guard username.value as? String == configuration.username else {
                throw PlaybackFailure("The username field did not retain the configured text.")
            }
        }

        if !configuration.password.isEmpty {
            let password = app.secureTextFields.firstMatch
            guard waitForHittable(password, in: app, timeout: 8) else {
                throw PlaybackFailure("The secure password field did not appear.")
            }

            password.tap()
            typeText(configuration.password, into: password)
        }

        let signIn = app.buttons[L10n.signIn].firstMatch
        guard waitForHittable(signIn, in: app, timeout: 8) else {
            throw PlaybackFailure("The Sign in button was not available.")
        }

        signIn.tap()
        guard homeButton(in: app).waitForExistence(timeout: 25) else {
            throw PlaybackFailure("The app did not reach Home after signing in.")
        }
    }

    @MainActor
    private func typeText(_ text: String, into field: XCUIElement) {
        // Send repeated adjacent characters in separate events. The URL keyboard can drop the second slash.
        var segment = ""
        for character in text {
            if segment.last == character {
                field.typeText(segment)
                segment = ""
            }
            segment.append(character)
        }
        if !segment.isEmpty {
            field.typeText(segment)
        }
    }

    @MainActor
    private func homeButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons[L10n.home].firstMatch
    }

    @MainActor
    private func openPlayer(for title: String, in app: XCUIApplication) throws {
        guard homeButton(in: app).waitForExistence(timeout: 24) else {
            throw PlaybackFailure("The fixture account did not reach Home.")
        }

        let item = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
        guard waitForHittable(item, in: app, timeout: 24) else {
            throw PlaybackFailure("The configured fixture was not tappable on Home.")
        }

        item.tap()

        let close = app.buttons["closePlayerButton"].firstMatch
        if !close.exists {
            let play = app.buttons[L10n.play].firstMatch
            guard waitForHittable(play, in: app, timeout: 18) else {
                throw PlaybackFailure("The fixture detail did not present a Play button.")
            }

            play.tap()
        }
        guard close.waitForExistence(timeout: 16) else { throw PlaybackFailure("The player did not open.") }
    }

    @MainActor
    private func playbackTime(in app: XCUIApplication, atLeast target: Int, phase: String) throws -> Int {
        let deadline = Date().addingTimeInterval(55)
        repeat {
            if app.alerts.firstMatch.exists {
                throw PlaybackFailure("\(phase): the player displayed an alert.")
            }
            if let time = elapsedTime(in: app), time >= target {
                return time
            }
            showControls(in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        } while Date() < deadline
        throw PlaybackFailure("\(phase): playback did not reach \(target)s (last \(elapsedTime(in: app) ?? 0)s).")
    }

    @MainActor
    private func elapsedTime(in app: XCUIApplication) -> Int? {
        let elapsed = app.staticTexts["playbackElapsedTime"].firstMatch
        guard elapsed.exists else { return nil }

        let parts = elapsed.label.split(separator: ":")
        guard (2 ... 3).contains(parts.count), parts.allSatisfy({ Int($0) != nil }) else { return nil }

        return parts.compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
    }

    @MainActor
    private func checkPlaybackQuality(_ expected: String, switchingTo newQuality: String? = nil, in app: XCUIApplication) throws {
        showControls(in: app)
        let menu = app.buttons[L10n.menu].firstMatch
        let playback = menuElements(labeled: L10n.playback, in: app)
        if !canTap(playback.firstMatch, in: app) {
            guard waitForHittable(menu, in: app, timeout: 12, revealPlayerControls: true)
            else { throw PlaybackFailure("The player menu did not open.") }

            menu.tap()
        }
        guard waitForHittable(playback.firstMatch, in: app, timeout: 6) else {
            throw PlaybackFailure("The Playback submenu did not appear.")
        }

        playback.firstMatch.tap()

        let quality = menuElements(labeled: L10n.playbackQuality, prefix: true, in: app).firstMatch
        guard waitForHittable(quality, in: app, timeout: 6) else {
            throw PlaybackFailure("The Playback quality picker did not appear.")
        }

        let description = [quality.value as? String, quality.label].compactMap(\.self).joined(separator: " ")
        guard description.localizedCaseInsensitiveContains(expected) else {
            throw PlaybackFailure("Expected playback quality \(expected), found \(description).")
        }
        guard let newQuality else {
            // Dismiss the menu without activating the picker or reselecting the current value.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
            guard quality.waitForNonExistence(timeout: 6) else {
                throw PlaybackFailure("The Playback submenu did not close.")
            }

            return
        }

        // On iOS 26.1, XCTest can lose the SwiftUI picker during element-based activation.
        try tapCenter(of: quality, in: app)
        let option = menuElements(labeled: newQuality, in: app).firstMatch
        guard waitForHittable(option, in: app, timeout: 8) else {
            throw PlaybackFailure("The requested playback quality was unavailable.")
        }

        option.tap()
    }

    @MainActor
    private func menuElements(labeled label: String, prefix: Bool = false, in app: XCUIApplication) -> XCUIElementQuery {
        let title = NSPredicate(format: prefix ? "label BEGINSWITH[c] %@" : "label ==[c] %@", label)
        let type = NSPredicate(
            format: "elementType IN %@",
            [XCUIElement.ElementType.button, .popUpButton, .menuItem].map(\.rawValue)
        )
        return app.descendants(matching: .any).matching(type).matching(title)
    }

    @MainActor
    private func stopPlayer(in app: XCUIApplication, fallbackTime: Int, requiresDetail: Bool = true) throws -> Int {
        showControls(in: app)
        let pause = app.buttons[L10n.pause].firstMatch
        if canTap(pause, in: app) {
            try tapCenter(of: pause, in: app)
        }
        let stopped = elapsedTime(in: app) ?? fallbackTime
        showControls(in: app)
        let close = app.buttons["closePlayerButton"].firstMatch
        guard waitForHittable(close, in: app, timeout: 6) else {
            throw PlaybackFailure("The Close player button was not available.")
        }

        // The default XCTest activation point can be outside the styled button hit region.
        try tapCenter(of: close, in: app)
        let video = app.descendants(matching: .any).matching(identifier: "videoSurfaceControlsToggle").firstMatch
        guard close.waitForNonExistence(timeout: 10),
              video.waitForNonExistence(timeout: 8)
        else { throw PlaybackFailure("The player did not close.") }

        if requiresDetail, !waitForHittable(app.buttons[L10n.play].firstMatch, in: app, timeout: 8) {
            throw PlaybackFailure("Closing the player did not return to the playable item detail.")
        }

        return stopped
    }

    @MainActor
    private func showControls(in app: XCUIApplication) {
        let close = app.buttons["closePlayerButton"].firstMatch
        let video = app.descendants(matching: .any).matching(identifier: "videoSurfaceControlsToggle").firstMatch
        if !canTap(close, in: app), canTap(video, in: app) {
            // Stay beside the central playback button if the controls are transitioning.
            video.coordinate(withNormalizedOffset: CGVector(dx: 0.74, dy: 0.5)).tap()
        }
    }

    @MainActor
    private func tapCenter(of element: XCUIElement, in app: XCUIApplication) throws {
        let window = app.windows.firstMatch
        let elementFrame = element.frame
        let frame = window.frame
        let center = CGPoint(x: elementFrame.midX, y: elementFrame.midY)
        guard !elementFrame.isEmpty, !frame.isEmpty, frame.contains(center) else {
            throw PlaybackFailure("The playback control was outside the window.")
        }

        window.coordinate(withNormalizedOffset: CGVector(
            dx: (center.x - frame.minX) / frame.width,
            dy: (center.y - frame.minY) / frame.height
        ))
        .tap()
    }

    @MainActor
    private func waitForHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval,
        revealPlayerControls: Bool = false
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if canTap(element, in: app) {
                return true
            }
            if revealPlayerControls {
                showControls(in: app)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        } while Date() < deadline
        return false
    }

    @MainActor
    private func canTap(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isEnabled else { return false }

        let frame = element.frame
        let window = app.windows.firstMatch
        let windowFrame = window.exists ? window.frame : app.frame
        return !frame.isEmpty && windowFrame.contains(CGPoint(x: frame.midX, y: frame.midY)) && element.isHittable
    }
}
#endif
