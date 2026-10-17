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
    /// word boundary that fires before the rest of the token exists. Grouped so a report can say which kind of
    /// token was changed.
    static let neverChangeGroups: [(category: String, tokens: [String])] = [
        ("proper names", [
            "Samuel", "Jensen", "Anthropic", "Kowalski", "Priya", "Nguyen", "Siobhan", "Zoltan", "Oaxaca",
            "Reykjavik", "Pranav", "Aarav", "Beatriz", "Takeshi", "Olumide", "Ximena", "Dmitri", "Ingrid",
            "Mehmet", "Svetlana", "Nakamura", "Hernandez", "Fitzgerald", "Okonkwo", "Lindqvist", "Tamsin",
            "Cormac", "Katarzyna", "Rajesh", "Anneliese", "Yusuf", "Mirembe", "Tigist", "Ljubljana", "Tbilisi",
            "Antananarivo", "Ouagadougou", "Guadalajara", "Chukwuemeka", "Ashkelon",
        ]),
        ("brands and products", [
            "iPhone", "Muesli", "GitHub", "YouTube", "macOS", "TestFlight", "Xcode", "ChatGPT", "OpenAI",
            "Kubernetes", "Spotify", "Figma", "Vercel", "Notion", "WhatsApp", "LinkedIn", "PayPal", "eBay",
            "Slack", "Dropbox", "Stripe", "Shopify", "Airbnb", "Reddit", "TikTok", "Snapchat", "Pinterest",
            "Tesla", "Nvidia", "Cloudflare", "Datadog", "Supabase", "Firebase", "Zoom", "Instacart",
            "muesli", "github", "spotify", "figma", "vercel", "xcode", "iphone", "macos", "linkedin",
            "airbnb", "shopify", "cloudflare", "supabase", "firebase", "nvidia", "tiktok", "dropbox",
        ]),
        ("abbreviations and chat words", [
            "lol", "tbh", "ok", "btw", "idk", "imo", "fyi", "asap", "omg", "brb", "lmk", "tldr", "afaik", "eta",
            "rsvp", "pdf", "faq", "ugh", "hmm", "yeah", "nope", "yep", "gonna", "wanna", "gotta", "kinda", "sorta",
            "nah", "yay", "wow", "oops", "thx", "pls", "ngl", "smh", "fomo", "yolo", "iirc", "ftw", "irl", "ama",
            "eod", "wfh", "pto", "kpi", "roi", "ceo", "cto", "aka", "etc", "approx", "dept", "govt", "selfie",
            "bestie", "vibes", "legit", "hbd", "ttyl", "nvm", "jk", "tmi", "fwiw",
        ]),
        ("technical terms", [
            "async", "await", "regex", "kubectl", "localhost", "json", "yaml", "stdout", "stderr", "bool", "enum",
            "struct", "config", "repo", "repos", "middleware", "webhook", "namespace", "backend", "frontend",
            "devops", "nginx", "sudo", "grep", "chmod", "npm", "tcp", "dns", "oauth", "sqlite", "postgres",
            "graphql", "tokenizer", "linter", "refactor", "mutex", "dockerfile", "http", "https", "ssh", "www",
            "webpack", "eslint", "tsconfig", "dotenv", "pytest", "numpy", "pandas", "redis", "mongodb", "mysql",
            "terraform", "ansible", "nodejs", "typescript", "javascript", "homebrew", "swiftui", "uikit",
            "cocoapods", "gitignore", "readme", "changelog", "bashrc", "zshrc", "tmux", "ssl", "tls", "jwt",
            "cors", "csrf", "apis", "sdk", "cli", "ide", "orm", "crud", "uuid", "regexp", "hostname", "username",
            "autocomplete", "dropdown", "checkbox", "tooltip", "boolean", "tuple", "serializer", "polyfill",
            "monorepo", "microservice", "dockerized", "kubernetes", "xcodeproj", "plist", "storyboard",
            "codesign", "provisioning", "entitlements", "apns", "cloudkit", "swiftlang",
        ]),
        ("hashtags and handles", [
            "#nofilter", "#TeamMuesli", "#swiftlang", "@samreed", "@strml", "@muesli_app", "@jdoe99",
            "#blessed", "#MondayMotivation", "#100DaysOfCode", "#iOSDev", "#wfh", "@elonmusk", "@sama",
            "@dan_abramov", "@a_b_c", "#TBT", "#ootd",
        ]),
        ("urls, hosts and emails", [
            "https://github.com/STRML/muesli-ios", "www.muesli.app", "muesli.app/docs", "http://localhost:3000",
            "github.com", "localhost:8080", "sam@example.com", "first.last@company.co",
            "https://muesli.app/blog/post-1", "mailto:hi@muesli.app", "ftp://files.example.org",
            "john.doe+tag@gmail.com", "support@muesli.app", "192.168.1.1", "10.0.0.1:8080",
            "example.org/path?query=1", "docs.swift.org", "stackoverflow.com", "news.ycombinator.com",
        ]),
        ("numbers with units", [
            "10km", "5kg", "3pm", "2nd", "100%", "24/7", "1.5x", "80mph", "$20", "3.14", "5G", "4K",
            "12oz", "6ft", "8GB", "256GB", "3.5mm", "15min", "2hrs", "9am", "1st", "3rd", "4th", "50%",
            "\u{20AC}20", "\u{00A3}15", "#1", "2x", "10x", "1k", "2.5k", "30s", "100ms", "60fps", "1080p",
            "720p", "4x4", "3d", "0xFF", "0b101", "1e9",
        ]),
        ("code-like tokens", [
            "foo_bar", "camelCaseVar", "snake_case_name", "getUserName()", "--verbose", "./run.sh", "user.id",
            "x86_64", "v2.1.0", "TODO", "i18n", "utf8", "node.js", "$HOME", "$PATH", "${var}", "a.b.c", "x_y",
            "__init__", "self.name", "this.state", "array[0]", "foo()", "bar.baz()", "-rf", "--force", "=>",
            "->", "<div>", "{{name}}", "@Observable", "@MainActor", "#include", "#import", "NaN", "UUID",
            "SHA256", "md5", "sha1", "base64", "HTTP/1.1", "UTF-8", "ISO8601", "fn", "impl", "nil",
        ]),
        ("rare but valid words", [
            "serendipity", "ephemeral", "ubiquitous", "sycophant", "pulchritude", "quixotic", "obfuscate",
            "perspicacious", "defenestrate", "gregarious", "ennui", "zeitgeist", "schadenfreude", "mellifluous",
            "onomatopoeia", "juxtaposition", "rhythm", "queue", "conscientious", "bureaucracy", "miscellaneous",
            "pneumonia", "rendezvous", "silhouette", "entrepreneur", "sesquipedalian", "petrichor", "limerence",
            "susurrus", "apricity", "phosphene", "abstruse", "recalcitrant", "ineffable", "effervescent",
            "loquacious", "bildungsroman", "weltanschauung", "gestalt", "doppelganger", "kitsch", "angst",
            "lugubrious", "obstreperous", "sanguine", "equanimity", "magnanimous", "idiosyncratic", "ostensibly",
            "vicissitude", "ameliorate", "anachronism", "cacophony", "ebullient", "inchoate", "pellucid",
        ]),
        ("valid words one edit from a more common word", [
            "form", "from", "trial", "trail", "quiet", "quite", "affect", "effect", "desert", "dessert",
            "angel", "angle", "casual", "causal", "expect", "except", "loose", "lose", "martial", "marital",
            "personal", "personnel", "stationary", "stationery", "then", "than", "whether", "weather",
            "thorough", "through", "adapt", "adopt", "accept", "advice", "advise", "altar", "alter", "bare",
            "bear", "brake", "break", "cite", "site", "complement", "compliment", "council", "counsel",
            "dairy", "diary", "device", "devise", "fair", "fare", "flour", "flower", "hole", "whole", "idle",
            "idol", "lead", "lend", "principal", "principle", "raise", "rise", "sight", "statue", "statute",
            "tale", "tail", "vain", "vein", "waist", "waste", "wander", "wonder", "wear", "where", "whose",
            "lightning", "lightening", "formed", "former", "trails", "trials",
        ]),
        ("contractions' lookalikes", [
            "ill", "id", "well", "were", "its", "hell", "shell", "wed", "lets", "wont",
        ]),
        ("apostrophes and hyphens", [
            "don't", "it's", "well-known", "state-of-the-art", "mother-in-law", "o'clock", "rock'n'roll",
            "can't", "won't", "I'll", "we're", "x-ray", "long-term", "e-mail", "re-enter", "co-op",
        ]),
        ("accents", ["na\u{00EF}ve", "r\u{00E9}sum\u{00E9}", "jalape\u{00F1}o", "fianc\u{00E9}", "caf\u{00E9}", "fa\u{00E7}ade"]),
    ]

    static let neverChange: [String] = neverChangeGroups.flatMap(\.tokens)
}
