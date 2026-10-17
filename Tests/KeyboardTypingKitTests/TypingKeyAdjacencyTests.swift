import XCTest
@testable import KeyboardTypingKit

/// Matrix rows N1-N3: which keys the cost model and the typo generator treat as next to each other.
final class TypingKeyAdjacencyTests: XCTestCase {
    // N1
    func testKeysBesideAndDiagonallyAboveOrBelowAreNeighbours() {
        XCTAssertEqual(Set(TypingKeyAdjacency.neighbours(of: "f")), ["d", "g", "r", "t", "c"])
        XCTAssertTrue(TypingKeyAdjacency.areNeighbours("q", "w"))
        XCTAssertTrue(TypingKeyAdjacency.areNeighbours("q", "a"))
        XCTAssertTrue(TypingKeyAdjacency.areNeighbours("j", "n"), "n sits under j in this layout")
    }

    // N2
    func testFarKeysAndTheSameKeyAreNot() {
        XCTAssertFalse(TypingKeyAdjacency.areNeighbours("q", "p"))
        XCTAssertFalse(TypingKeyAdjacency.areNeighbours("a", "a"))
        XCTAssertFalse(TypingKeyAdjacency.areNeighbours("c", "s"))
        XCTAssertFalse(TypingKeyAdjacency.areNeighbours("m", "q"))
    }

    func testTheRelationIsSymmetricAndIgnoresCase() {
        for a in TypingKeyAdjacency.orderedLetters {
            for b in TypingKeyAdjacency.orderedLetters {
                XCTAssertEqual(TypingKeyAdjacency.areNeighbours(a, b), TypingKeyAdjacency.areNeighbours(b, a), "\(a)\(b)")
            }
        }
        XCTAssertTrue(TypingKeyAdjacency.areNeighbours("A", "s"))
    }

    // N3
    func testEveryLetterHasNeighboursAndNothingElseDoes() {
        XCTAssertEqual(TypingKeyAdjacency.orderedLetters.count, 26)
        for letter in TypingKeyAdjacency.orderedLetters {
            XCTAssertGreaterThanOrEqual(TypingKeyAdjacency.neighbours(of: letter).count, 2, "\(letter)")
        }
        XCTAssertTrue(TypingKeyAdjacency.neighbours(of: "1").isEmpty)
        XCTAssertTrue(TypingKeyAdjacency.neighbours(of: " ").isEmpty)
    }

    func testNeighboursComeInKeyboardOrderSoASeededGeneratorIsStable() {
        XCTAssertEqual(TypingKeyAdjacency.neighbours(of: "s"), TypingKeyAdjacency.neighbours(of: "s"))
        let order = TypingKeyAdjacency.orderedLetters
        let neighbours = TypingKeyAdjacency.neighbours(of: "g")
        XCTAssertEqual(neighbours, neighbours.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! })
    }
}
