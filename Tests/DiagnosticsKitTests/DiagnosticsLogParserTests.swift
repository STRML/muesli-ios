import XCTest
@testable import DiagnosticsKit

final class DiagnosticsLogParserTests: XCTestCase {
    func testTimestampIsUTCWithMilliseconds() {
        XCTAssertEqual(DiagnosticsLogFormat.timestamp(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(DiagnosticsLogFormat.timestamp(Date(timeIntervalSince1970: 1.0236)), "1970-01-01T00:00:01.023Z")
    }

    func testWriterAndReaderRoundTripOneLine() {
        let text = Fixture.line(1, "recording.started", ["request": "04fcc3fc", "elapsed_ms": "412"]) + "\n"
        let result = DiagnosticsLogParser.parse(text)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0].name, "recording.started")
        XCTAssertEqual(result.lines[0].process, "Muesli")
        XCTAssertEqual(result.lines[0].detail, "elapsed_ms=412 request=04fcc3fc")
        XCTAssertEqual(result.lines[0].time, DiagnosticsLogFormat.timestamp(Fixture.t0.addingTimeInterval(1)))
        XCTAssertFalse(result.skippedPartialTail)
    }

    func testAnEventWithNoDetailParses() {
        let result = DiagnosticsLogParser.parse(Fixture.line(0, "keyboard.appeared") + "\n")
        XCTAssertEqual(result.lines.map(\.name), ["keyboard.appeared"])
        XCTAssertEqual(result.lines.first?.detail, "")
    }

    /// Two processes write the log. A reader that catches it between writes must not send half a line.
    func testAPartialLastLineIsSkippedAndFlagged() {
        let whole = Fixture.line(0, "intent.stop", ["request": "04fcc3fc"])
        let torn = String(Fixture.line(1, "recording.started", ["elapsed_ms": "412"]).prefix(40))
        let result = DiagnosticsLogParser.parse(whole + "\n" + torn)
        XCTAssertEqual(result.lines.map(\.name), ["intent.stop"])
        XCTAssertTrue(result.skippedPartialTail)
    }

    func testLineIDIsStableAndDistinguishesLines() {
        let a = Fixture.line(0, "intent.stop")
        let b = Fixture.line(0.001, "intent.stop")
        XCTAssertEqual(DiagnosticsLogParser.lineID(a), DiagnosticsLogParser.lineID(a))
        XCTAssertNotEqual(DiagnosticsLogParser.lineID(a), DiagnosticsLogParser.lineID(b))
        XCTAssertEqual(DiagnosticsLogParser.lineID(a).count, 16)
        let parsed = DiagnosticsLogParser.parse(a + "\n").lines
        XCTAssertEqual(parsed.first?.id, DiagnosticsLogParser.lineID(a))
    }

    func testMalformedAndEmptyLinesAreCountedNotParsed() {
        let text = "garbage without tabs\n\n" + Fixture.line(0) + "\n2026-01-01T00:00:00.000Z\tMuesli\n"
        let result = DiagnosticsLogParser.parse(text)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.malformedLines, 2)
    }

    func testEmptyTextParsesToNothing() {
        XCTAssertEqual(DiagnosticsLogParser.parse(""), DiagnosticsLogParseResult())
    }

    func testCleanValueCollapsesWhitespaceAndCapsLength() {
        XCTAssertEqual(DiagnosticsLogFormat.cleanValue("a\nb\tc"), "a b c")
        let long = String(repeating: "x", count: 100)
        XCTAssertEqual(DiagnosticsLogFormat.cleanValue(long), String(repeating: "x", count: 64) + "...")
    }
}
