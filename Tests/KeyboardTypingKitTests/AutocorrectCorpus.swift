import Foundation

/// The autocorrect evaluation corpus. Plain data with no imports of the typing module, so the same file is
/// compiled into the host test target (shape checks) and into MuesliTests (the run against the real UITextChecker,
/// which needs a UIKit runtime).
///
/// Two sets, because the engine is judged on both: it must fix the typos people really make (a), and it must
/// leave alone everything that only looks wrong to a dictionary (b). A wrong correction is worse than a missed
/// one, so (b) carries the hard limit.
enum AutocorrectCorpus {
    /// (a) What the user typed, and what it must become. Typed in the middle of a sentence.
    static let typos: [(typed: String, expected: String)] = [
        // The classics.
        ("teh", "the"), ("adn", "and"), ("wiht", "with"), ("thier", "their"), ("recieve", "receive"),
        ("definately", "definitely"), ("seperate", "separate"), ("becuase", "because"), ("dont", "don't"),
        ("cant", "can't"), ("im", "I'm"), ("youre", "you're"), ("doesnt", "doesn't"), ("tomorow", "tomorrow"),
        ("accomodate", "accommodate"), ("occured", "occurred"), ("untill", "until"), ("wich", "which"),
        ("freind", "friend"),
        // Contractions.
        ("isnt", "isn't"), ("wasnt", "wasn't"), ("couldnt", "couldn't"), ("wouldnt", "wouldn't"),
        ("shouldnt", "shouldn't"), ("didnt", "didn't"), ("havent", "haven't"), ("ive", "I've"),
        ("theyre", "they're"), ("thats", "that's"), ("arent", "aren't"), ("hasnt", "hasn't"),
        // Transpositions and dropped letters.
        ("hte", "the"), ("taht", "that"), ("jsut", "just"), ("waht", "what"), ("becasue", "because"),
        ("beacuse", "because"), ("chnage", "change"), ("togehter", "together"), ("thorugh", "through"),
        ("wokring", "working"), ("questoin", "question"), ("thougth", "thought"), ("heigth", "height"),
        ("begining", "beginning"), ("buisness", "business"), ("calender", "calendar"), ("cieling", "ceiling"),
        // Wrong or doubled vowels and consonants.
        ("beleive", "believe"), ("wierd", "weird"), ("goverment", "government"), ("enviroment", "environment"),
        ("necesary", "necessary"), ("occassion", "occasion"), ("embarass", "embarrass"), ("grammer", "grammar"),
        ("independant", "independent"), ("knowlege", "knowledge"), ("maintainance", "maintenance"),
        ("noticable", "noticeable"), ("persistant", "persistent"), ("posession", "possession"),
        ("refered", "referred"), ("relevent", "relevant"), ("succesful", "successful"), ("suprise", "surprise"),
        ("tommorow", "tomorrow"), ("truely", "truly"), ("usualy", "usually"), ("writting", "writing"),
        ("yeild", "yield"), ("comming", "coming"), ("diffrent", "different"), ("finaly", "finally"),
        ("happend", "happened"), ("intresting", "interesting"), ("mesage", "message"), ("peice", "piece"),
        ("realy", "really"), ("somthing", "something"), ("sucess", "success"), ("apparantly", "apparently"),
        ("recomend", "recommend"), ("immediatly", "immediately"), ("arguement", "argument"),
        ("existance", "existence"), ("dissapear", "disappear"), ("definatly", "definitely"),
    ]

    /// (a2) Typos at the start of a sentence, where the first letter is a capital and a capital is normal.
    static let sentenceStartTypos: [(typed: String, expected: String)] = [
        ("Teh", "The"), ("Dont", "Don't"), ("Recieve", "Receive"), ("Thier", "Their"), ("Wich", "Which"),
        ("Im", "I'm"), ("Becuase", "Because"), ("Tomorow", "Tomorrow"),
    ]

    /// (b) Typed exactly as written and followed by a space. None may change. Tokens with a natural
    /// continuation ("github.com", "localhost:8080") are typed whole, because the "." or ":" inside them is a
    /// word boundary that fires before the rest of the token exists.
    static let neverChange: [String] = [
        // Proper names.
        "Samuel", "Jensen", "Anthropic", "Kowalski", "Priya", "Nguyen", "Siobhan", "Zoltan", "Oaxaca",
        "Reykjavik", "Pranav", "Aarav", "Beatriz", "Takeshi", "Olumide", "Ximena", "Dmitri", "Ingrid",
        // Brands and products.
        "iPhone", "Muesli", "GitHub", "YouTube", "macOS", "TestFlight", "Xcode", "ChatGPT", "OpenAI",
        "Kubernetes", "Spotify", "Figma", "Vercel", "Notion", "WhatsApp", "LinkedIn", "PayPal", "eBay",
        // Brands and tools people type in lowercase.
        "muesli", "github", "spotify", "figma", "vercel", "xcode", "iphone", "macos", "linkedin",
        // Abbreviations and chat words.
        "lol", "tbh", "ok", "btw", "idk", "imo", "fyi", "asap", "omg", "brb", "lmk", "tldr", "afaik", "eta",
        "rsvp", "pdf", "faq", "ugh", "hmm", "yeah", "nope", "yep", "gonna", "wanna", "gotta", "kinda", "sorta",
        "nah", "yay", "wow", "oops", "thx", "pls",
        // Technical terms.
        "async", "await", "regex", "kubectl", "localhost", "json", "yaml", "stdout", "stderr", "bool", "enum",
        "struct", "config", "repo", "repos", "middleware", "webhook", "namespace", "backend", "frontend",
        "devops", "nginx", "sudo", "grep", "chmod", "npm", "tcp", "dns", "oauth", "sqlite", "postgres",
        "graphql", "tokenizer", "linter", "refactor", "mutex", "dockerfile", "http", "https", "ssh", "www",
        // Hashtags and handles.
        "#nofilter", "#TeamMuesli", "#swiftlang", "@samreed", "@strml", "@muesli_app", "@jdoe99",
        // URLs, hosts and emails.
        "https://github.com/STRML/muesli-ios", "www.muesli.app", "muesli.app/docs", "http://localhost:3000",
        "github.com", "localhost:8080", "sam@example.com", "first.last@company.co",
        // Numbers with units, and numeric tokens.
        "10km", "5kg", "3pm", "2nd", "100%", "24/7", "1.5x", "80mph", "$20", "3.14", "5G", "4K",
        // Code-like tokens.
        "foo_bar", "camelCaseVar", "snake_case_name", "getUserName()", "--verbose", "./run.sh", "user.id",
        "x86_64", "v2.1.0", "TODO", "i18n", "utf8", "node.js",
        // Valid but rare English words.
        "serendipity", "ephemeral", "ubiquitous", "sycophant", "pulchritude", "quixotic", "obfuscate",
        "perspicacious", "defenestrate", "gregarious", "ennui", "zeitgeist", "schadenfreude", "mellifluous",
        "onomatopoeia", "juxtaposition", "rhythm", "queue", "conscientious", "bureaucracy", "miscellaneous",
        "pneumonia", "rendezvous", "silhouette", "entrepreneur",
        // Real words that are also a contraction without its apostrophe.
        "ill", "id", "well", "were", "its", "hell", "shell", "wed", "lets", "wont",
        // Apostrophes and hyphens.
        "don't", "it's", "well-known", "state-of-the-art", "mother-in-law", "o'clock", "rock'n'roll",
        // Accents.
        "naïve", "résumé", "jalapeño", "fiancé",
    ]
}
