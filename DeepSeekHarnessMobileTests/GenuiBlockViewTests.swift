import XCTest
@testable import DeepSeekHarnessMobile

final class GenuiBlockViewTests: XCTestCase {
    func testMatchesFenceIsCaseAndWhitespaceInsensitive() {
        XCTAssertTrue(GenuiArtifact.matchesFence("dsh-ui"))
        XCTAssertTrue(GenuiArtifact.matchesFence("  DSH-UI  "))
        XCTAssertFalse(GenuiArtifact.matchesFence("json"))
        XCTAssertFalse(GenuiArtifact.matchesFence(nil))
    }

    func testJSONRepairHandlesStrictAndCommonModelDefects() {
        // Strict valid JSON
        XCTAssertEqual(GenuiJSONRepair.decodeObject(#"{"type":"card","title":"ok"}"#)?["title"] as? String, "ok")

        // Missing closing brace
        XCTAssertEqual(GenuiJSONRepair.decodeObject(#"{"type":"card","items":[1,2"#)?["type"] as? String, "card")

        // Trailing comma
        XCTAssertEqual(GenuiJSONRepair.decodeObject(#"{"type":"card","items":[1,2,],}"#)?["type"] as? String, "card")

        // Surplus closing brace
        XCTAssertEqual(GenuiJSONRepair.decodeObject(#"{"type":"card"}}"#)?["type"] as? String, "card")

        // Full-width Chinese quotes
        XCTAssertEqual(GenuiJSONRepair.decodeObject("{“type”:“card”}")?["type"] as? String, "card")

        // Non-object or completely invalid text returns nil
        XCTAssertNil(GenuiJSONRepair.decodeObject("[1, 2, 3]"))
        XCTAssertNil(GenuiJSONRepair.decodeObject("not json at all"))
    }

    func testPlanDerivesRequiredAssetsAndPresentation() throws {
        let source = """
        {
          "type": "layout",
          "children": [
            { "type": "mermaid", "code": "graph TD; A-->B;" },
            { "type": "scene3d" },
            { "type": "chart", "option": {} }
          ]
        }
        """
        let plan = try XCTUnwrap(GenuiArtifact.plan(fromFence: source, isDark: true, fontScale: 1.25))
        XCTAssertEqual(plan.assets, ["mermaid", "three", "echarts-core", "echarts-full"])

        let data = try XCTUnwrap(plan.artifactJSON.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["format"] as? String, "dsh-genui")
        let presentation = try XCTUnwrap(root["presentation"] as? [String: Any])
        XCTAssertEqual(presentation["theme"] as? String, "dark")
        XCTAssertEqual(presentation["fontScale"] as? Double, 1.25)
    }

    func testMountBudgetEvictsOldestEntryWhenOverLimit() {
        let budget = GenuiMountBudget(limit: 2)
        let first = UUID()
        let second = UUID()
        let third = UUID()

        budget.claim(first)
        budget.claim(second)
        XCTAssertTrue(budget.isActive(first))
        XCTAssertTrue(budget.isActive(second))

        budget.claim(third)
        XCTAssertFalse(budget.isActive(first))
        XCTAssertTrue(budget.isActive(second))
        XCTAssertTrue(budget.isActive(third))

        budget.release(second)
        XCTAssertFalse(budget.isActive(second))
        XCTAssertTrue(budget.isActive(third))
    }
}
