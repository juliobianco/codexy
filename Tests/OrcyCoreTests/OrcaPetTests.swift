import XCTest
@testable import CodexyCore

final class OrcaPetTests: XCTestCase {
    func testOrcaIsWellFormed() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/Orcy/pets/orca.txt")
        let p = try XCTUnwrap(PetParser.parse(try String(contentsOf: url, encoding: .utf8), id: "orca"))
        XCTAssertEqual(Set(p.art.keys), ["normal", "slack", "crit", "sleep", "walk1", "walk2", "sit"])
        for (mood, rows) in p.art {
            XCTAssertEqual(rows.count, 12, mood)
            for r in rows {
                XCTAssertEqual(r.count, 18, "\(mood) \(r)")
                for ch in r where ch != "." { XCTAssertNotNil(p.colors[String(ch)], "\(mood) '\(ch)'") }
            }
        }
    }
}
