import XCTest
import Yams

final class SmokeTests: XCTestCase {
    func testYamsIsLinkedAndParses() throws {
        let yaml = "title: Focus Tracker\npriority: high\n"
        let parsed = try Yams.load(yaml: yaml) as? [String: Any]
        XCTAssertEqual(parsed?["title"] as? String, "Focus Tracker")
        XCTAssertEqual(parsed?["priority"] as? String, "high")
    }

    func testYamsDumps() throws {
        let dumped = try Yams.dump(object: ["a": 1])
        XCTAssertTrue(dumped.contains("a: 1"))
    }
}