import AppSettings
import XCTest
@testable import Overlay
@testable import Transcript

final class CaptionContentTests: XCTestCase {
    let toEnglish = TranslationSettings(kind: .oneWay, target: "en")

    func testTargetOnlyHidesForeignOriginalUntilTranslated() {
        var s = Segment(id: 1, source: .system, language: "ru", original: "Привет, как дела?")
        XCTAssertTrue(CaptionContent.lines(for: s, mode: .translation, translation: toEnglish).isEmpty,
                      "Russian text must not be shown while waiting for the English translation")
        s.translation = "Hi, how are you?"
        XCTAssertEqual(CaptionContent.lines(for: s, mode: .translation, translation: toEnglish),
                       .init(original: false, translation: true))
    }

    func testTargetOnlyShowsSpeechAlreadyInTargetLanguage() {
        let s = Segment(id: 1, source: .system, language: "en", original: "Let's ship it.")
        XCTAssertEqual(CaptionContent.lines(for: s, mode: .translation, translation: toEnglish),
                       .init(original: true, translation: false))
    }

    func testUnknownLanguageDraftIsHidden() {
        let s = Segment(id: 1, source: .mic, draftOriginal: "Шалом")
        XCTAssertTrue(CaptionContent.lines(for: s, mode: .translation, translation: toEnglish).isEmpty)
    }

    func testTranslationOffFallsBackToOriginal() {
        let s = Segment(id: 1, source: .system, language: "he", original: "שלום")
        XCTAssertEqual(CaptionContent.lines(for: s, mode: .translation, translation: .init(kind: .off)),
                       .init(original: true, translation: false))
    }

    func testOtherModes() {
        let s = Segment(id: 1, source: .system, language: "ru", original: "Да", translation: "Yes")
        XCTAssertEqual(CaptionContent.lines(for: s, mode: .both, translation: toEnglish), .init(original: true, translation: true))
        XCTAssertEqual(CaptionContent.lines(for: s, mode: .original, translation: toEnglish), .init(original: true, translation: false))
        XCTAssertEqual(CaptionContent.lines(for: s, mode: .translation, translation: .init(kind: .twoWay, a: "ru", b: "en")),
                       .init(original: false, translation: true))
    }
}
