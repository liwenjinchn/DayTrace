import XCTest
@testable import DayTraceCore

final class ResponsesTests: XCTestCase {
    let source = SourceExcerpt(id: "fixture:0", clipID: "fixture", offset: 0, text: "会议在周五下午三点。", started: Date())
    func payload(status: String = "completed", type: String = "output_text", ids: [String] = ["fixture:0"]) throws -> Data {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: ["answer": "周五下午三点", "sourceIDs": ids]), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["status": status, "output": [
            ["type": "reasoning"], ["type": "message", "role": "assistant", "status": "completed", "content": [["type": type, "text": text]]]], "usage": ["total_tokens": 42]])
    }
    func testResponsesRequestAndGroundedDecode() throws {
        let request = try AIWire.request(service: AIService(endpoint: "https://example.invalid/v1/responses", model: "synthetic"), key: "secret-fixture", question: "几点？", sources: [source])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertNil(body["messages"])
        XCTAssertEqual(body["max_output_tokens"] as? Int, AIWire.outputLimit)
        XCTAssertTrue((body["input"] as? String)?.contains(source.text) == true)
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("secret-fixture"))
        let reply = try AIWire.decode(payload(), sources: [source])
        XCTAssertEqual(reply.answer.sourceIDs, [source.id])
        XCTAssertEqual(reply.totalTokens, 42)
    }
    func testRejectsIncompleteRefusalAndUnknownCitation() throws {
        XCTAssertThrowsError(try AIWire.decode(payload(status: "incomplete"), sources: [source]))
        XCTAssertThrowsError(try AIWire.decode(payload(type: "refusal"), sources: [source]))
        XCTAssertThrowsError(try AIWire.decode(payload(ids: ["invented"]), sources: [source]))
    }
}
