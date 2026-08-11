import XCTest
@testable import OpenUsage

/// The provider marks are single SVG paths parsed at runtime. DeepSeek and MiniMax draw their rounded
/// forms with elliptical arcs, which the parser has to handle — an unsupported command stops parsing
/// mid-path and the icon silently renders as a fragment.
final class SVGPathArcTests: XCTestCase {
    func testParsesCircleDrawnFromTwoArcs() {
        // A radius-5 circle centered at (5, 0), drawn as two half-arcs.
        let path = SVGPath.parse("M 0 0 a 5 5 0 1 0 10 0 a 5 5 0 1 0 -10 0 z")
        let bounds = path.cgPath.boundingBoxOfPath

        XCTAssertEqual(bounds.minX, 0, accuracy: 0.01)
        XCTAssertEqual(bounds.maxX, 10, accuracy: 0.01)
        XCTAssertEqual(bounds.minY, -5, accuracy: 0.01)
        XCTAssertEqual(bounds.maxY, 5, accuracy: 0.01)
    }

    func testArcHonorsSweepDirection() {
        // Same endpoints, opposite sweep flags: the arcs bow to opposite sides of the baseline.
        let up = SVGPath.parse("M 0 0 A 5 5 0 0 0 10 0").cgPath.boundingBoxOfPath
        let down = SVGPath.parse("M 0 0 A 5 5 0 0 1 10 0").cgPath.boundingBoxOfPath

        XCTAssertGreaterThan(up.maxY, 0.1)
        XCTAssertLessThan(down.minY, -0.1)
    }

    func testParsesArcFlagsPackedWithoutSeparators() {
        // Optimized marks pack the flags and the following coordinate together ("1 0-1.718").
        let packed = SVGPath.parse("M10 0a.86.86 0 1 0-1.718 0").cgPath.boundingBoxOfPath

        XCTAssertFalse(packed.isNull)
        XCTAssertEqual(packed.width, 1.718, accuracy: 0.01)
    }

    func testDegenerateRadiusFallsBackToALine() {
        let path = SVGPath.parse("M 0 0 A 0 0 0 0 1 10 0").cgPath.boundingBoxOfPath

        XCTAssertEqual(path.maxX, 10, accuracy: 0.01)
        XCTAssertEqual(path.height, 0, accuracy: 0.01)
    }
}

@MainActor
final class ProviderMarkTests: XCTestCase {
    func testShippedMarksParseIntoNonEmptyArtwork() throws {
        // Every registered provider's mark must resolve from the bundle and produce real artwork; a
        // missing or unparsable file falls back to an SF Symbol without any other signal.
        for id in ["claude", "codex", "cursor", "deepseek", "minimax", "openrouter", "zai"] {
            let mark = try XCTUnwrap(ProviderMarks.mark(for: id), "no mark for \(id)")
            let bounds = SVGPath.parse(mark.path).cgPath.boundingBoxOfPath
            XCTAssertGreaterThan(bounds.width, 0, "\(id) mark has no width")
            XCTAssertGreaterThan(bounds.height, 0, "\(id) mark has no height")
        }
    }

    func testDeepSeekAndMiniMaxMarksFillTheirViewBox() throws {
        // Both are 24×24 simple-icons marks made largely of arcs: if arc parsing broke, the path would
        // stop early and cover only a fraction of the box.
        for id in ["deepseek", "minimax"] {
            let mark = try XCTUnwrap(ProviderMarks.mark(for: id))
            let bounds = SVGPath.parse(mark.path).cgPath.boundingBoxOfPath
            XCTAssertGreaterThan(bounds.width, 18, "\(id) mark is narrower than its viewBox")
            XCTAssertGreaterThan(bounds.height, 12, "\(id) mark is shorter than expected")
        }
    }
}
