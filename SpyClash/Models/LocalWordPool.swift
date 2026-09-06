import Foundation

enum LocalWordPool {
    static let generationLimit = 200

    static func cleanWords(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.compactMap { raw in
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { return nil }
            return word
        }
    }

    static func playableWords(_ words: [String], selectedCount: Int) -> [String] {
        Array(cleanWords(words).prefix(max(selectedCount, 1)))
    }

    static func restoredCount(_ count: Double, hasCustomTheme: Bool) -> Double {
        let count = max(count, 2)
        // The generation limit does not limit a saved local pack. Applying it
        // to every restored source silently changed the pool after relaunch.
        return hasCustomTheme ? min(count, Double(generationLimit)) : count
    }
}
