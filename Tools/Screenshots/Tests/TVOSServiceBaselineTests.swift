//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

#if os(tvOS)
import XCTest

final class TVOSServiceBaselineTests: XCTestCase {

    private enum Service: String {

        case emby
        case jellyfin
    }

    private struct Configuration {

        let url: String
        let username: String
        let password: String
        let title: String

        init(service: Service) throws {
            let environment = ProcessInfo.processInfo.environment
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

    private struct BaselineFailure: LocalizedError {

        let errorDescription: String?

        init(_ description: String) {
            errorDescription = description
        }
    }

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
        let robot = Robot(app: app)
        app.launch()
        try signIn(configuration, using: robot)

        _ = robot.media().library("CineFerry Episode Library").item(configuration.title)
        let secondEpisode = robot.buttons(containing: "Second Fixture").firstMatch
        robot.reveal(secondEpisode)
        robot.tap(secondEpisode)

        try startEpisodePlayer(using: robot)
        let start = try playbackTime(in: robot, atLeast: 1, phase: "Initial episode playback")
        try assertEpisodeIdentity(in: robot)
        let advancing = try playbackTime(in: robot, atLeast: start + 8, phase: "Episode playback")
        let stopped = try closePlayer(
            for: configuration.title,
            in: robot,
            lastObserved: advancing,
            additionalFocusLabels: ["Second Fixture", L10n.posterAccessibilitySeason(1)]
        )
        wait(4)
        app.terminate()
        app.launch()

        robot.home()
        let resumeCard = robot.buttons(containing: "Second Fixture").firstMatch
        robot.reveal(resumeCard)
        robot.tap(resumeCard)
        try startEpisodePlayer(using: robot)
        let resumed = try playbackTime(in: robot, atLeast: 1, phase: "Cold episode resume")
        try assertEpisodeIdentity(in: robot)
        guard resumed >= max(start + 4, stopped - 5), resumed <= stopped + 15 else {
            throw BaselineFailure("Episode resumed at \(resumed)s after stopping at \(stopped)s.")
        }

        let final = try playbackTime(in: robot, atLeast: resumed + 3, phase: "Episode resume advancement")
        _ = try closePlayer(for: configuration.title, in: robot, lastObserved: final)
        print("BASELINE \(service.rawValue) episode S1:E2 stopped \(stopped)s, cold resume \(resumed) -> \(final)s")
    }

    @MainActor
    private func startEpisodePlayer(using robot: Robot) throws {
        if !timeline(in: robot).waitForExistence(timeout: 3) {
            let play = robot.buttons(labeled: L10n.play).firstMatch
            guard play.waitForExistence(timeout: 12) else {
                throw BaselineFailure("The episode detail did not present a Play button.")
            }

            robot.tap(play)
        }
    }

    @MainActor
    private func assertEpisodeIdentity(in robot: Robot) throws {
        let episode = robot.app
            .staticTexts
            .matching(
                NSPredicate(format: "label CONTAINS %@", L10n.seasonAndEpisode(1, 2))
            )
            .firstMatch
        guard episode.waitForExistence(timeout: 6) else {
            throw BaselineFailure("The player did not identify the item as season 1, episode 2.")
        }
    }

    @MainActor
    private func runBaseline(for service: Service) throws {
        let configuration = try Configuration(service: service)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        let robot = Robot(app: app)
        app.launch()

        do {
            try signIn(configuration, using: robot)
            print("BASELINE \(service.rawValue) tvOS signed in")
            try openPlayer(for: configuration.title, using: robot)
            let start = try playbackTime(in: robot, atLeast: 1, phase: "Initial playback")
            let advancing = try playbackTime(in: robot, atLeast: start + 8, phase: "Timeline advancement")
            attachScreenshot("\(service.rawValue)-playing")

            let stopped = try closePlayer(for: configuration.title, in: robot, lastObserved: advancing)
            print("BASELINE \(service.rawValue) tvOS played \(start)s to \(advancing)s, stopped at \(stopped)s")
            wait(4)
            app.terminate()
            app.launch()

            try openPlayer(for: configuration.title, using: robot)
            let resumed = try playbackTime(in: robot, atLeast: 1, phase: "First timeline after cold launch")
            guard resumed >= max(start + 4, stopped - 5), resumed <= stopped + 15 else {
                throw BaselineFailure("Resumed at \(resumed)s after stopping at \(stopped)s.")
            }

            let resumedAdvancing = try playbackTime(in: robot, atLeast: resumed + 3, phase: "Cold resume advancement")
            attachScreenshot("\(service.rawValue)-cold-resume")
            _ = try closePlayer(for: configuration.title, in: robot, lastObserved: resumedAdvancing)
            print("BASELINE \(service.rawValue) tvOS cold resume advanced from \(resumed)s to \(resumedAdvancing)s")
        } catch {
            attachScreenshot("\(service.rawValue)-failure")
            throw error
        }
    }

    @MainActor
    private func signIn(_ configuration: Configuration, using robot: Robot) throws {
        robot.tap(robot.button(L10n.connect))
        let url = robot.waitFor(robot.app.textFields[L10n.url])
        try enterServerURL(configuration.url, into: url, using: robot)

        let center = CGPoint(x: url.frame.midX, y: url.frame.midY)
        let submit = robot.buttons(labeled: L10n.connect).allElementsBoundByIndex.min {
            hypot($0.frame.midX - center.x, $0.frame.midY - center.y) <
                hypot($1.frame.midX - center.x, $1.frame.midY - center.y)
        }
        guard let submit else { throw BaselineFailure("The server Connect button did not appear.") }

        robot.tap(submit)
        let username = robot.app.textFields[L10n.username].firstMatch
        if !username.exists {
            robot.tap(robot.largest(robot.buttons(containing: L10n.addUser)))
        }
        robot.type(configuration.username, into: username)
        if !configuration.password.isEmpty {
            robot.type(configuration.password, into: robot.app.secureTextFields.firstMatch)
        }
        robot.tap(robot.button(L10n.signIn))
        guard robot.button(L10n.home).waitForExistence(timeout: 24) else {
            throw BaselineFailure("Sign-in did not reach Home.")
        }
    }

    @MainActor
    private func enterServerURL(_ address: String, into field: XCUIElement, using robot: Robot) throws {
        let editor = robot.app
            .descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == true"))
            .firstMatch
        let keyboard = robot.app.keyboards.firstMatch

        for _ in 0 ..< 2 {
            if !editor.exists, !keyboard.exists {
                robot.tap(field)
            }
            let deadline = Date().addingTimeInterval(8)
            while !editor.exists, !keyboard.exists, Date() < deadline {
                wait(0.2)
            }
            guard editor.exists || keyboard.exists else {
                throw BaselineFailure("The Siri Remote did not open the server URL editor.")
            }

            // Sending the slashes separately avoids losing one to keyboard repeat handling.
            if let separator = address.range(of: "://") {
                robot.app.typeText(String(address[..<address.index(before: separator.upperBound)]))
                robot.app.typeText(String(address[address.index(before: separator.upperBound)...]))
            } else {
                robot.app.typeText(address)
            }
            XCUIRemote.shared.press(.menu)
            wait(0.6)

            let value = field.value as? String ?? ""
            if normalizedAddress(value) == normalizedAddress(address) {
                return
            }
            guard value.isEmpty || value == field.placeholderValue else {
                throw BaselineFailure("The server URL field did not retain the full address.")
            }
        }
        throw BaselineFailure("The server URL field was empty after two attempts.")
    }

    private func normalizedAddress(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "/\u{FFFC}")))
            .replacing("://", with: ":/")
    }

    @MainActor
    private func openPlayer(for title: String, using robot: Robot) throws {
        robot.home()
        let item = robot.buttons(containing: title).firstMatch
        if item.waitForExistence(timeout: 8) {
            robot.tap(item)
        } else {
            _ = robot.media().library("CineFerry Test").item(title)
        }

        // Continue Watching can open the player directly. Library items open detail first.
        if timeline(in: robot).waitForExistence(timeout: 3) {
            return
        }
        let detailPlay = robot.buttons(labeled: L10n.play).firstMatch
        guard detailPlay.waitForExistence(timeout: 15) else {
            throw BaselineFailure("The fixture did not open playback or show Play on its detail view.")
        }

        robot.tap(detailPlay)
    }

    @MainActor
    private func timeline(in robot: Robot) -> XCUIElement {
        robot.app.staticTexts["playbackElapsedTime"].firstMatch
    }

    @MainActor
    private func elapsedTime(in robot: Robot) -> Int? {
        let elapsed = timeline(in: robot)
        guard isVisible(elapsed) else { return nil }

        let parts = elapsed.label.split(separator: ":").compactMap { Int($0) }
        guard (2 ... 3).contains(parts.count) else { return nil }

        return parts.reduce(0) { $0 * 60 + $1 }
    }

    @MainActor
    private func playbackTime(in robot: Robot, atLeast target: Int, phase: String) throws -> Int {
        let deadline = Date().addingTimeInterval(45)
        var observed: Int?
        repeat {
            if robot.app.alerts.firstMatch.exists {
                throw BaselineFailure("\(phase): the player displayed an alert.")
            }
            if let elapsed = elapsedTime(in: robot) {
                if elapsed >= target {
                    return elapsed
                }

                observed = elapsed
            } else {
                // Select reveals hidden controls without moving the seek position.
                XCUIRemote.shared.press(.select)
            }
            wait(0.7)
        } while Date() < deadline
        throw BaselineFailure(
            "\(phase): playback never reached \(target)s. Last timeline value: \(observed.map(String.init) ?? "missing")."
        )
    }

    @MainActor
    private func closePlayer(
        for title: String,
        in robot: Robot,
        lastObserved: Int,
        additionalFocusLabels: [String] = []
    ) throws -> Int {
        let elapsed = timeline(in: robot)
        if !isVisible(elapsed) {
            XCUIRemote.shared.press(.select)
            guard waitForVisibility(of: elapsed, visible: true) else {
                throw BaselineFailure("Couldn't reveal the playback timeline before closing the player.")
            }
        }

        let stopped = elapsedTime(in: robot) ?? lastObserved
        XCUIRemote.shared.press(.menu)
        guard waitForVisibility(of: elapsed, visible: false) else {
            throw BaselineFailure("Back did not hide the playback controls.")
        }

        // The first Back hides the overlay. The second Back stops the playback session.
        XCUIRemote.shared.press(.menu)
        let confirmation = robot.app.alerts[L10n.closePlayer]
        if confirmation.waitForExistence(timeout: 1) {
            robot.tap(confirmation.buttons[L10n.ok])
        }

        let deadline = Date().addingTimeInterval(8)
        repeat {
            if !isVisible(elapsed),
               let focus = robot.focusedLabel,
               focus == L10n.play || focus == L10n.home || focus.contains(title) || additionalFocusLabels
                .contains(where: { focus.contains($0) }) {
                return stopped
            }
            wait(0.4)
        } while Date() < deadline
        throw BaselineFailure(
            "Back did not return focus to the fixture or Home after closing the player. Focus: \(robot.focusedLabel ?? "none")."
        )
    }

    @MainActor
    private func isVisible(_ element: XCUIElement) -> Bool {
        element.exists && element.isEnabled
    }

    @MainActor
    private func waitForVisibility(of element: XCUIElement, visible: Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if isVisible(element) == visible {
                return true
            }

            wait(0.3)
        } while Date() < deadline
        return false
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func wait(_ interval: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(interval))
    }
}
#endif
