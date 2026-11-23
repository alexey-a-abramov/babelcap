import XCTest
@testable import SonioxClient
@testable import Transcript

final class TokenAssemblerTests: XCTestCase {
    func tok(_ t: String, final: Bool, speaker: String? = "1", tr: Bool = false, start: Int = 0, end: Int = 0) -> SonioxToken {
        SonioxToken(text: t, startMs: start, endMs: end, isFinal: final, speaker: speaker, translationStatus: tr ? "translation" : "original")
    }

    func testFinalTokensAppendOnceAndDraftIsReplaced() {
        var a = TokenAssembler(source: .system)
        a.handle([tok("Hello", final: true), tok(" wor", final: false)])
        XCTAssertEqual(a.snapshot.first?.fullOriginal, "Hello wor")
        a.handle([tok(" world", final: false)])
        XCTAssertEqual(a.snapshot.first?.fullOriginal, "Hello world") // draft replaced, not appended
        a.handle([tok(" world", final: true)])
        XCTAssertEqual(a.snapshot.first?.original, "Hello world")
        XCTAssertEqual(a.snapshot.first?.draftOriginal, "")
        XCTAssertEqual(a.snapshot.count, 1)
    }

    func testSpeakerChangeClosesSegment() {
        var a = TokenAssembler(source: .system)
        a.handle([tok("Hi.", final: true, speaker: "1"), tok("Hey.", final: true, speaker: "2")])
        XCTAssertEqual(a.snapshot.map(\.original), ["Hi.", "Hey."])
        XCTAssertEqual(a.snapshot.map(\.speaker), ["1", "2"])
        XCTAssertTrue(a.snapshot[0].isClosed)
    }

    func testEndMarkerClosesSegment() {
        var a = TokenAssembler(source: .mic)
        a.handle([tok("One.", final: true), tok("<end>", final: true)])
        a.handle([tok("Two.", final: true)])
        XCTAssertEqual(a.snapshot.map(\.original), ["One.", "Two."])
    }

    func testTranslationTrackIsIndependentAndLags() {
        var a = TokenAssembler(source: .system)
        a.handle([tok("Привет.", final: true), tok("<end>", final: true)])
        a.handle([tok("Как дела?", final: true), tok("<end>", final: true)])
        // Translation of the first sentence arrives only now, after two originals.
        a.handle([tok("Hello.", final: true, tr: true), tok("<end>", final: true, tr: true)])
        XCTAssertEqual(a.snapshot[0].translation, "Hello.")
        XCTAssertEqual(a.snapshot[1].translation, "")
        a.handle([tok("How are you?", final: false, tr: true)])
        XCTAssertEqual(a.snapshot[1].draftTranslation, "How are you?")
    }

    func testEmptyOpenSegmentIsPrunedOnClose() {
        var a = TokenAssembler(source: .system)
        a.handle([tok("x", final: false)]) // opens a segment for the draft only
        a.handle([])                        // draft vanished
        a.closeOpenSegment()
        XCTAssertTrue(a.snapshot.isEmpty)
    }
}

final class DeduperTests: XCTestCase {
    func testEchoDetected() {
        let sys = Segment(id: 1, source: .system, original: "so we should deploy the new build tomorrow")
        let mic = Segment(id: 2, source: .mic, original: "we should deploy the new build tomorrow")
        XCTAssertTrue(EchoDeduper.isEcho(mic: mic, system: [sys]))
        let own = Segment(id: 3, source: .mic, original: "sounds good to me")
        XCTAssertFalse(EchoDeduper.isEcho(mic: own, system: [sys]))
    }
}

@MainActor final class StoreTests: XCTestCase {
    func testExportFormats() {
        let s = Segment(id: 1, source: .system, speaker: "1", original: "Hello", translation: "Привет", isClosed: true)
        XCTAssertTrue(Exporters.srt([s], start: s.createdAt).contains("00:00:00,000 --> 00:00:01,500"))
        XCTAssertTrue(Exporters.markdown([s], start: s.createdAt).contains("> Привет"))
        XCTAssertTrue(Exporters.json([s]).contains("\"original\""))
    }
}
