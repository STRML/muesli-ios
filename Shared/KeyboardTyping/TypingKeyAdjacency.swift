import Foundation

/// Which letter keys sit next to each other, read from the Type page's own layout so the typo generator in the
/// tests and the autocorrect cost model measure the same keyboard. Keys are compared by the centre of their cell
/// in `TypingLayout`'s weighted rows: two keys are neighbours when they are side by side, or when they are in
/// adjacent rows and their centres are less than one key apart.
enum TypingKeyAdjacency {
    private struct Position {
        let row: Int
        let x: Double
    }

    private static let positions: [Character: Position] = {
        let rows = TypingLayout.rows(page: .letters, uppercase: false, traits: TypingTraits(), showsGlobe: true)
        var result: [Character: Position] = [:]
        for (rowIndex, row) in rows.enumerated() {
            var offset = 0.0
            for key in row {
                defer { offset += key.weight }
                guard case .character(let text) = key.action, text.count == 1, let letter = text.first, letter.isLetter
                else { continue }
                result[letter] = Position(row: rowIndex, x: offset + key.weight / 2)
            }
        }
        return result
    }()

    /// The letters next to `letter`, in keyboard order (top row first, left to right), so a seeded generator
    /// picks the same neighbour on every run. Empty for anything that is not a letter key.
    static func neighbours(of letter: Character) -> [Character] {
        let key = Character(letter.lowercased())
        return orderedLetters.filter { areNeighbours(key, $0) }
    }

    static func areNeighbours(_ a: Character, _ b: Character) -> Bool {
        let first = Character(a.lowercased()), second = Character(b.lowercased())
        guard first != second, let from = positions[first], let to = positions[second] else { return false }
        let rowGap = abs(from.row - to.row), gap = abs(from.x - to.x)
        return (rowGap == 0 && gap <= 1.0) || (rowGap == 1 && gap < 1.0)
    }

    static let orderedLetters: [Character] = TypingLayout.letterRows.flatMap { Array($0) }
}
