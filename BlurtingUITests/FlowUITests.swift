import Foundation
import XCTest

final class FlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 900
    }

    private func launch(_ arguments: [String] = [], language: String = "en", environment: [String: String] = [:]) {
        app?.terminate()
        app = XCUIApplication()
        let locales = ["en": "en_US", "zh-Hans": "zh_CN", "zh-Hant": "zh_TW"]
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(\(language))",
                               "-AppleLocale", locales[language] ?? "en_US"] + arguments
        app.launchEnvironment = environment
        app.launch()
    }

    private func button(_ id: String) -> XCUIElement { app.buttons.matching(identifier: id).firstMatch }
    private func label(_ id: String) -> XCUIElement { app.staticTexts.matching(identifier: id).firstMatch }

    private func tap(_ id: String, scroll: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        let element = button(id)
        if !element.waitForExistence(timeout: scroll ? 3 : 10), scroll { app.swipeUp() }
        if scroll {
            for _ in 0..<4 {
                if element.exists && element.isHittable { break }
                app.swipeUp()
            }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), id, file: file, line: line)
        XCTAssertTrue(element.isHittable, id, file: file, line: line)
        element.tap()
    }

    private func beginNote(title: String, text: String) {
        tap("home.new")
        let name = app.textFields["editor.title"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        name.typeText(title)
        let source = app.textViews["editor.source"]
        XCTAssertTrue(source.exists)
        source.tap()
        source.typeText(text)
        tap("editor.save")
        XCTAssertTrue(app.textViews["recall.answer"].waitForExistence(timeout: 8))
    }

    private func completeBlank() {
        tap("recall.reveal")
        XCTAssertTrue(button("compare.finish").waitForExistence(timeout: 8))
        XCTAssertFalse(button("compare.finish").isEnabled)
        tap("compare.blank")
        tap("compare.finish")
        XCTAssertEqual(label("result.coverage").label, "0%")
        tap("result.home")
    }

    func testFirstInstallRecallResumesAfterBackgroundAndProcessRestart() {
        launch(["-reset", "-persist"])
        beginNote(title: "Study chapter", text: "Only key point")
        XCTAssertFalse(app.staticTexts["Only key point"].exists)
        XCTAssertFalse(app.staticTexts["Study chapter"].exists)
        let answer = app.textViews["recall.answer"]
        answer.tap()
        answer.typeText("My remembered text")
        tap("recall.exit")
        tap("home.start")
        XCTAssertEqual(app.textViews["recall.answer"].value as? String, "My remembered text")

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.textViews["recall.answer"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.textViews["recall.answer"].value as? String, "My remembered text")

        tap("recall.reveal")
        tap("compare.point.0")
        XCTAssertEqual(label("compare.missCount").label, "Missed: 1")
        launch(["-persist"])
        tap("home.start")
        XCTAssertTrue(label("compare.missCount").waitForExistence(timeout: 8))
        XCTAssertEqual(label("compare.missCount").label, "Missed: 1")
        tap("compare.finish")
        XCTAssertEqual(label("result.coverage").label, "0%")
        tap("result.share")
        tap("share.export", scroll: true)
        XCTAssertTrue(label("share.requested").waitForExistence(timeout: 8))
        tap("nav.back", scroll: false)
        tap("result.home")
        tap("home.start")
        XCTAssertTrue(app.textViews["recall.answer"].waitForExistence(timeout: 8))
    }

    func testExampleAndZeroMisses() {
        launch(["-reset"])
        tap("home.example")
        let editor = app.textViews["recall.answer"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.tap()
        editor.typeText("Some words I remember")
        tap("recall.reveal")
        tap("compare.point.0")
        tap("compare.point.0")
        tap("compare.finish")
        XCTAssertEqual(label("result.coverage").label, "100%")
    }

    func testThirdPracticeDayDefersRatingUntilHomeAndNeverRepeatsThisVersion() {
        launch(["-reset", "-persist"], environment: ["BLURTING_DAY_OFFSET": "0"])
        tap("home.example")
        completeBlank()
        XCTAssertFalse(label("rating.requested").exists)
        launch(["-persist"], environment: ["BLURTING_DAY_OFFSET": "1"])
        XCTAssertTrue(button("home.start").waitForExistence(timeout: 8))
        XCTAssertFalse(label("rating.requested").exists)
        launch(["-persist"], environment: ["BLURTING_DAY_OFFSET": "2"])
        tap("home.start")
        tap("recall.reveal")
        tap("compare.blank")
        tap("compare.finish")
        XCTAssertTrue(label("result.coverage").waitForExistence(timeout: 8))
        XCTAssertFalse(label("rating.requested").exists)
        tap("result.home")
        XCTAssertTrue(label("rating.requested").waitForExistence(timeout: 8))
        launch(["-persist"], environment: ["BLURTING_DAY_OFFSET": "2"])
        XCTAssertTrue(button("home.start").waitForExistence(timeout: 8))
        XCTAssertFalse(label("rating.requested").waitForExistence(timeout: 3))
    }

    func testExpiredTrialLeavesOriginalNotesReadableAndFreePracticeRepeatable() {
        launch(["-reset", "-persist"])
        for title in ["Earlier chapter", "Second chapter", "Latest chapter"] {
            beginNote(title: title, text: "One key point")
            completeBlank()
        }

        launch(["-persist", "-expired"], environment: ["BLURTING_RESTORE_PRO": "1"])
        tap("home.notes")
        XCTAssertTrue(button("notes.useFree.2").waitForExistence(timeout: 8))
        tap("notes.detail.2")
        XCTAssertTrue(app.staticTexts["Earlier chapter"].exists)
        XCTAssertTrue(app.staticTexts.matching(identifier: "One key point").firstMatch.exists)
        tap("detail.history")
        XCTAssertTrue(button("trend.session.0").waitForExistence(timeout: 8))
        XCTAssertTrue(button("trend.pro").exists)
        tap("nav.back")
        tap("nav.back")
        tap("notes.start.0")
        completeBlank()
        tap("home.start")
        completeBlank()
        tap("home.new")
        XCTAssertTrue(button("paywall.buy").waitForExistence(timeout: 8))
        tap("paywall.restore", scroll: true)
        XCTAssertTrue(label("paywall.message").waitForExistence(timeout: 8))
        XCTAssertEqual(label("paywall.status").label, "Pro unlocked")
    }

    func testInvalidCodeManualInputValidPasteDedupAndFileImport() throws {
        let outline = Data(#"{"version":1,"title":"Partner outline","points":["One","Two"]}"#.utf8)
        let base64 = outline.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let file = #"{"version":1,"title":"File outline","points":["First","Second"]}"#
        launch(["-reset"], environment: ["BLURTING_IMPORT_CODE": "BP1." + base64, "BLURTING_IMPORT_FILE": file])
        tap("home.import")
        let text = app.textViews["import.code"]
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        text.tap()
        text.typeText("invalid")
        XCTAssertTrue(label("import.error").waitForExistence(timeout: 8))
        tap("import.paste")
        XCTAssertTrue(label("import.previewTitle").waitForExistence(timeout: 8))
        XCTAssertEqual(label("import.previewTitle").label, "Partner outline")
        tap("import.save")
        tap("home.import")
        tap("import.paste")
        tap("import.save")
        XCTAssertTrue(label("import.error").waitForExistence(timeout: 8))
        XCTAssertEqual(label("import.error").label, "This outline is already in Notes.")
        tap("nav.back")
        tap("home.notes")
        tap("notes.importFile")
        XCTAssertTrue(label("import.previewTitle").waitForExistence(timeout: 8))
        XCTAssertEqual(label("import.previewTitle").label, "File outline")
        tap("import.save")
        tap("notes.detail.0")
        tap("detail.code")
        tap("detail.copyCode", scroll: true)
        tap("detail.file", scroll: true)
        XCTAssertTrue(label("detail.message").waitForExistence(timeout: 8))
    }

    func testThreeClickChapterTrendAndNextDayReview() {
        launch(["-demo", "-reset"])
        tap("home.notes")
        tap("notes.subject.0")
        tap("subject.trend.0")
        XCTAssertTrue(label("85%").waitForExistence(timeout: 8))
        XCTAssertTrue(button("trend.session.0").exists)
        tap("nav.back")
        tap("nav.back")
        tap("nav.back")
        tap("home.review")
        XCTAssertTrue(app.staticTexts["Coming up"].waitForExistence(timeout: 8))

        launch(["-reset", "-persist"])
        tap("home.example")
        completeBlank()
        launch(["-persist"], environment: ["BLURTING_DAY_OFFSET": "1"])
        tap("home.review")
        tap("review.start.0")
        tap("recall.reveal")
        XCTAssertTrue(button("compare.prior").waitForExistence(timeout: 8))
    }

    func testTodayReviewStartsFirstChapterInOneTap() {
        launch(["-reset", "-demo", "-screen", "review-due"])
        tap("home.reviewToday")
        XCTAssertTrue(button("recall.reveal").waitForExistence(timeout: 8))
    }

    func testPaperPhotoAutomaticallyComparesAndKeepsManualChangesAndOriginal() throws {
        let url = try XCTUnwrap(Bundle(for: FlowUITests.self).url(forResource: "paper-recall", withExtension: "png"))
        let photo = try Data(contentsOf: url).base64EncodedString()
        launch(["-reset", "-persist"], environment: ["BLURTING_PAPER_IMAGE": photo])
        beginNote(title: "Paper chapter", text: "Plants absorb carbon through photosynthesis\nOceans release carbon dioxide")
        tap("recall.paper")
        XCTAssertTrue(label("recall.timer").exists)
        tap("paper.capture")
        XCTAssertTrue(button("compare.finish").waitForExistence(timeout: 15))
        XCTAssertTrue(label("compare.answer").label.lowercased().contains("photosynthesis"))
        XCTAssertEqual(label("compare.missCount").label, "Missed: 1")
        XCTAssertEqual(button("compare.point.0").value as? String, "Recalled")
        tap("compare.point.1")
        XCTAssertEqual(label("compare.missCount").label, "Missed: 0")
        tap("compare.finish")
        XCTAssertEqual(label("result.coverage").label, "100%")

        launch(["-persist"])
        tap("home.notes")
        tap("notes.detail.0")
        tap("detail.history")
        tap("trend.session.0")
        XCTAssertTrue(app.images["history.paper.1"].waitForExistence(timeout: 8))
    }

    func testStoreScreenshots() throws {
        let sceneList: [(String, String?, String)] = [
            ("01-home", nil, "home.start"),
            ("02-editor", "editor", "editor.point.0"),
            ("03-recall", "recall", "recall.reveal"),
            ("04-compare", "compare", "compare.finish"),
            ("05-trend", "trend", "trend.chapter"),
            ("09-paper", "paper", "compare.finish"),
            ("10-review-due", "review-due", "home.reviewToday")
        ]
        for language in ["en", "zh-Hans", "zh-Hant"] {
            for (shotName, screen, marker) in sceneList {
                let options = screen.map { ["-screen", $0] } ?? []
                var environment: [String: String] = [:]
                if screen == "editor" {
                    environment["BLURTING_NOTE_TEXT"] = screenshotText(for: language)
                }
                launch(["-reset", "-demo"] + options, language: language, environment: environment)
                XCTAssertTrue(button(marker).waitForExistence(timeout: 10), "\(language)/\(shotName)")
                let name = "store-\(language)-\(shotName)"
                try shot(name)
            }
        }
    }

    func testPaidScreenshot() throws {
        launch(["-reset", "-paywall"], language: "zh-Hans")
        XCTAssertTrue(button("paywall.buy").waitForExistence(timeout: 10))
        try shot("paid-01-paywall")
    }

    private func screenshotText(for language: String) -> String {
        switch language {
        case "zh-Hans": "1. 植物通过光合作用吸收二氧化碳。\n2. 碳沿食物网传递。\n3. 呼吸作用释放二氧化碳。\n4. 海洋吸收并释放二氧化碳。"
        case "zh-Hant": "1. 植物透過光合作用吸收二氧化碳。\n2. 碳沿食物網傳遞。\n3. 呼吸作用釋放二氧化碳。\n4. 海洋吸收並釋放二氧化碳。"
        default: "1. Plants absorb CO₂ through photosynthesis.\n2. Carbon moves through food webs.\n3. Respiration releases CO₂.\n4. Oceans absorb and release CO₂."
        }
    }

    private func shot(_ name: String) throws {
        let image = app.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["SHOTS_DIR"] ?? environment["TEST_RUNNER_SHOTS_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try image.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        }
    }
}
