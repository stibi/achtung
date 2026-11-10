import Foundation

/// A search across every channel (ADR 0017): text found in an alert's title, summary or a
/// label, and filters that must all hold: labels with exactly these values, any of these
/// severities, this instance. The server does the matching.
public struct OccurrenceSearch: Hashable, Sendable {
    /// Found case-insensitively and literally; empty for none.
    public let text: String
    public let tokens: [SearchToken]

    public init(text: String, tokens: [SearchToken]) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tokens = tokens
    }

    public var isEmpty: Bool { text.isEmpty && tokens.isEmpty }

    /// `name=value`, as the server's `label` parameter takes them.
    public var labels: [String] {
        tokens.compactMap {
            if case .label(let name, let value) = $0 { "\(name)=\(value)" } else { nil }
        }
    }

    public var severities: [Severity] {
        tokens.compactMap { if case .severity(let severity) = $0 { severity } else { nil } }
    }

    /// The last instance token wins: an alert is on one instance.
    public var instance: String? {
        tokens.compactMap { if case .instance(let name) = $0 { name } else { nil } }.last
    }

    /// "namespace=payments severity:critical disk", for the empty state and the help.
    public var description: String {
        (tokens.map(\.title) + (text.isEmpty ? [] : ["“\(text)”"])).joined(separator: " ")
    }
}

/// A filter in the search field, shown as a token: a label with a value, a severity or an
/// instance.
public enum SearchToken: Hashable, Sendable, Identifiable {
    case label(name: String, value: String)
    case severity(Severity)
    case instance(String)

    public var id: String { title }

    /// As typed: "namespace=payments", "severity:critical", "instance:cdx".
    public var title: String {
        switch self {
        case .label(let name, let value): "\(name)=\(value)"
        case .severity(let severity): "severity:\(severity.rawValue)"
        case .instance(let name): "instance:\(name)"
        }
    }

    /// A word typed in the search field as a token, or nil when it's plain text:
    /// "name=value" with a Prometheus label name, "severity:<level>", "instance:<name>".
    public init?(word: String) {
        if let separator = word.firstIndex(of: "=") {
            let name = String(word[..<separator])
            let value = String(word[word.index(after: separator)...])
            guard Self.isLabelName(name), !value.isEmpty else { return nil }
            self = .label(name: name, value: value)
        } else if word.lowercased().hasPrefix("severity:"),
            let severity = Severity(rawValue: String(word.dropFirst(9)).lowercased())
        {
            self = .severity(severity)
        } else if word.lowercased().hasPrefix("instance:"), word.count > 9 {
            self = .instance(String(word.dropFirst(9)))
        } else {
            return nil
        }
    }

    /// Prometheus label names: a letter or underscore, then letters, digits, underscores.
    private static func isLabelName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter || first == "_" else {
            return false
        }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// Turns the finished words of `text` (those followed by a space, or all of them when
    /// `all`) into tokens where they are ones, and returns the rest of the text as typed.
    public static func extract(from text: String, all: Bool = false)
        -> (tokens: [SearchToken], text: String)
    {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        // The word being typed is the last one, unless the text ends in a space or `all`.
        let typing = all || text.hasSuffix(" ") ? nil : words.popLast()
        var tokens: [SearchToken] = []
        var rest: [String] = []
        for word in words where !word.isEmpty {
            if let token = SearchToken(word: word) {
                tokens.append(token)
            } else {
                rest.append(word)
            }
        }
        if let typing {
            rest.append(typing)
        }
        guard !tokens.isEmpty else { return ([], text) }
        // A space typed after the last word stays, so the next word starts apart from it.
        let remaining = rest.joined(separator: " ")
        return (tokens, typing == nil && !remaining.isEmpty ? remaining + " " : remaining)
    }

    /// The search field after typing `text` with `tokens` already there: finished filter
    /// words become tokens (all words with `all`, on Return), each once; a new instance
    /// replaces the old one, as an alert is on one instance.
    public static func tokenize(text: String, tokens: [SearchToken], all: Bool = false)
        -> (text: String, tokens: [SearchToken])
    {
        let extracted = extract(from: text, all: all)
        var result = tokens
        for token in extracted.tokens where !result.contains(token) {
            if case .instance = token {
                result.removeAll { if case .instance = $0 { true } else { false } }
            }
            result.append(token)
        }
        return (extracted.text, result)
    }
}
