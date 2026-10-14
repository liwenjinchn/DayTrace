import XCTest
@testable import DayTraceCore
final class ProviderErrorTests: XCTestCase {
    func testGoogleArrayError() throws {
        let data = try JSONSerialization.data(withJSONObject: [["error": ["message": "User location is not supported for the API use."]]])
        XCTAssertTrue(AITransport.failureMessage(data: data, status: 400).contains("网络出口"))
    }
    func testClassifiesWithoutEchoingSensitiveContent() throws {
        let data = try JSONSerialization.data(withJSONObject: ["error": ["message": "secret prompt and credential", "details": [["reason": "API_KEY_INVALID"]]]])
        let result = AITransport.failureMessage(data: data, status: 400)
        XCTAssertTrue(result.contains("密钥无效"))
        XCTAssertFalse(result.contains("secret"))
        XCTAssertEqual(AITransport.failureMessage(data: Data("private raw body".utf8), status: 400), "服务请求失败（HTTP 400）。")
    }
}
