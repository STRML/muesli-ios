import Foundation

/// Words people type without the apostrophe, fixed from an explicit table. It runs before the spell checker
/// because the checker accepts some of them ("cant" is a word). Words that are also real words and not
/// obviously a contraction ("ill", "id", "well", "were", "its", "hell", "shell", "wed", "lets", "wont") stay out:
/// changing them would be wrong more often than right. English only; the caller checks the language.
enum TypingContractions {
    static let table: [String: String] = {
        var table: [String: String] = [
            "dont": "don't", "doesnt": "doesn't", "didnt": "didn't", "cant": "can't", "couldnt": "couldn't",
            "wouldnt": "wouldn't", "shouldnt": "shouldn't", "isnt": "isn't", "arent": "aren't",
            "wasnt": "wasn't", "werent": "weren't", "hasnt": "hasn't", "havent": "haven't", "hadnt": "hadn't",
            "im": "I'm", "ive": "I've", "youre": "you're", "youve": "you've", "youll": "you'll",
            "theyre": "they're", "theyve": "they've", "theyll": "they'll", "weve": "we've",
            "thats": "that's", "whats": "what's", "theres": "there's", "heres": "here's", "whos": "who's",
            "couldve": "could've", "shouldve": "should've", "wouldve": "would've",
            "i": "I",
        ]
        let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        let months = ["january", "february", "april", "june", "july", "august", "september", "october",
                      "november", "december"]
        for name in days + months { table[name] = name.prefix(1).uppercased() + name.dropFirst() }
        return table
    }()

    /// The shortest word that is still fixed before a "." or ":".
    private static let strictMinimumLength = 4

    /// The fixed spelling for `word`, following the case it was typed in, or nil. `strict` is for a word that
    /// may be the start of "i.e.", "im.com" or "june.app": only a longer contraction ("dont") is fixed then,
    /// never "i", a short one or a day or month.
    static func correction(for word: String, strict: Bool = false) -> String? {
        let lowered = word.lowercased()
        guard let fixed = table[lowered] else { return nil }
        if strict, !(fixed.contains("'") && lowered.count >= strictMinimumLength) { return nil }
        let isLower = word == lowered
        let isCapitalized = word.first?.isUppercase == true && word.dropFirst() == lowered.dropFirst()
        guard isLower || isCapitalized else { return nil }
        let result = isLower ? fixed : fixed.prefix(1).uppercased() + fixed.dropFirst()
        return result == word ? nil : result
    }
}
