import XCTest
@testable import DayTraceCore
final class GeminiTests: XCTestCase {
    let source = SourceExcerpt(id: "fixture:0", clipID: "fixture", offset: 0, text: "会议在周五下午三点。", started: Date())
    func testNativeRequestKeepsCredentialOutOfURLAndBody() throws {
        let r = try AIWire.request(service: AIService(endpoint: "https://generativelanguage.googleapis.com/v1beta/models/test:generateContent", model: "test"), key: "fixture-secret", question: "几点？", sources: [source])
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-secret")
        XCTAssertNil(r.url?.query)
        let data = try XCTUnwrap(r.httpBody)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixture-secret"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(body["systemInstruction"])
        XCTAssertNotNil(body["contents"])
        XCTAssertNil(body["messages"])
        XCTAssertThrowsError(try AIWire.request(service: AIService(endpoint: "https://example.com/models/other:generateContent", model: "test"), key: "fixture", question: "q", sources: [source]))
    }
    func testStructuredMemoryEvidenceRequiresQuoteObjectsAndHonorsPurposes() throws {
        let service = AIService(endpoint: "https://example.com/models/test:generateContent", model: "test")
        let request = try AIWire.request(service: service, key: "test", question: "q", sources: [source], generateMemories: true)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let instruction = try XCTUnwrap(body["systemInstruction"] as? [String: Any])
        let parts = try XCTUnwrap(instruction["parts"] as? [[String: String]])
        XCTAssertTrue(parts[0]["text"]!.contains("array of objects"))
        XCTAssertTrue(parts[0]["text"]!.contains("never an array of strings"))
        let invalid = "{\"answer\":\"计划\",\"sourceIDs\":[\"fixture:0\"],\"memories\":[{\"content\":\"计划\",\"topic\":\"计划\",\"category\":\"plan\",\"subject\":\"record\",\"uncertain\":false,\"evidence\":[\"fixture:0\"]}]}"
        let data = try JSONSerialization.data(withJSONObject: ["candidates": [["finishReason": "STOP", "content": ["role": "model", "parts": [["text": invalid]]]]]])
        XCTAssertThrowsError(try AIWire.decode(data, sources: [source], generateMemories: true))
    }
    func testNativeDecodeRejectsIncompleteAndUnknownSources() throws {
        func payload(_ finish: String, _ id: String) throws -> Data {
            let answer = String(decoding: try JSONSerialization.data(withJSONObject: ["answer": "周五下午三点", "sourceIDs": [id]]), as: UTF8.self)
            return try JSONSerialization.data(withJSONObject: ["candidates": [["finishReason": finish, "content": ["role": "model", "parts": [["text": "hidden", "thought": true], ["text": answer]]]]], "usageMetadata": ["totalTokenCount": 42]])
        }
        let reply = try AIWire.decode(payload("STOP", source.id), sources: [source])
        XCTAssertEqual(reply.answer.sourceIDs, [source.id]); XCTAssertEqual(reply.totalTokens, 42)
        XCTAssertThrowsError(try AIWire.decode(payload("MAX_TOKENS", source.id), sources: [source]))
        XCTAssertThrowsError(try AIWire.decode(payload("STOP", "unknown"), sources: [source]))
    }
}
