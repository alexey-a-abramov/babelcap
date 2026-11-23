import XCTest
@testable import SonioxClient

final class ModelsTests: XCTestCase {
    func testConfigEncodesSnakeCaseAndNoApiKey() throws {
        var c = SonioxConfig(model: "stt-rt-v6")
        c.languageHints = ["en", "ru"]
        c.enableSpeakerDiarization = true
        c.maxEndpointDelayMs = 1000
        c.translation = .oneWay(target: "ru")
        c.context = .init(general: [.init(key: "domain", value: "calls")], terms: ["Supabase"])
        let json = try JSONSerialization.jsonObject(with: c.jsonData()) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "stt-rt-v6")
        XCTAssertEqual(json["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(json["sample_rate"] as? Int, 16000)
        XCTAssertEqual(json["max_endpoint_delay_ms"] as? Int, 1000)
        XCTAssertNil(json["api_key"])
        let tr = json["translation"] as! [String: Any]
        XCTAssertEqual(tr["type"] as? String, "one_way")
        XCTAssertEqual(tr["target_language"] as? String, "ru")
    }

    func testTwoWayTranslation() throws {
        var c = SonioxConfig()
        c.translation = .twoWay(a: "ru", b: "en")
        let json = try JSONSerialization.jsonObject(with: c.jsonData()) as! [String: Any]
        let tr = json["translation"] as! [String: Any]
        XCTAssertEqual(tr["language_a"] as? String, "ru")
        XCTAssertEqual(tr["language_b"] as? String, "en")
    }

    func testResponseParsingToleratesUnknownFieldsAndNumericSpeaker() throws {
        let raw = #"{"tokens":[{"text":"Hi","start_ms":10,"end_ms":200,"confidence":0.9,"is_final":true,"speaker":2,"language":"en","translation_status":"none","future_field":1}],"final_audio_proc_ms":200,"total_audio_proc_ms":300,"brand_new":true}"#
        let r = try SonioxResponse.decode(Data(raw.utf8))
        XCTAssertEqual(r.tokens?.first?.speaker, "2")
        XCTAssertEqual(r.tokens?.first?.isFinal, true)
        XCTAssertEqual(r.finalAudioProcMs, 200)
    }

    func testErrorResponseAndActions() throws {
        let r = try SonioxResponse.decode(Data(#"{"error_code":401,"error_message":"bad key"}"#.utf8))
        let e = SonioxError(code: r.errorCode!, message: r.errorMessage!)
        XCTAssertTrue(e.isFatal)
        XCTAssertEqual(SonioxError(code: 429, message: "").action, .backoff)
        XCTAssertEqual(SonioxError(code: 413, message: "").action, .reconnect)
    }
}
