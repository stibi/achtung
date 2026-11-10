import Foundation

/// How an alert's annotations and labels are laid out for reading: the prose first, the
/// links as buttons, the rest of the annotations, and the labels that say where it fires
/// before the others.
extension IncomingAlert {
    /// Labels that say what and where, in this order, before the rest by name.
    static let leadingLabelNames = [
        "alertname", "severity", "cluster", "namespace", "job", "pod", "instance", "service",
        "container", "deployment",
    ]

    /// Annotations shown as prose rather than as entries: the summary and description.
    static let proseAnnotationNames: Set<String> = ["summary", "description"]

    /// The `description` annotation, the long form of the summary; nil when empty or absent.
    public var alertDescription: String? {
        annotations["description"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The labels, those in `leadingLabelNames` first in that order, then the rest by name.
    public var orderedLabels: [(name: String, value: String)] {
        let leading = Self.leadingLabelNames.compactMap { name in
            labels[name].map { (name: name, value: $0) }
        }
        let rest = labels.filter { !Self.leadingLabelNames.contains($0.key) }
            .sorted { $0.key < $1.key }.map { (name: $0.key, value: $0.value) }
        return leading + rest
    }

    /// Annotations whose value is a single http(s) URL that `links` doesn't already have,
    /// e.g. a `dashboard_url`, by name: buttons rather than raw URLs. Not the prose ones,
    /// which show as text.
    public var linkAnnotations: [(name: String, url: URL)] {
        let linked = Set(links.map(\.url))
        return annotations.sorted { $0.key < $1.key }.compactMap { name, value in
            guard !Self.proseAnnotationNames.contains(name), let url = Self.webURL(value),
                !linked.contains(url)
            else { return nil }
            return (name, url)
        }
    }

    /// Every annotation, the summary and description first, then the rest by name.
    public var orderedAnnotations: [(name: String, value: String)] {
        let prose = ["summary", "description"].compactMap { name in
            annotations[name].map { (name: name, value: $0) }
        }
        let rest = annotations.filter { !Self.proseAnnotationNames.contains($0.key) }
            .sorted { $0.key < $1.key }.map { (name: $0.key, value: $0.value) }
        return prose + rest
    }

    /// The value as an http(s) URL with a host, when it is one and nothing else.
    static func webURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
            ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil
        else { return nil }
        return url
    }
}

/// "runbook_url" → "Runbook", "generatorURL" → "Generator", "grafana-dashboard" → "Grafana
/// dashboard": an annotation's name as a button title.
public func linkTitle(forAnnotation name: String) -> String {
    var words: [String] = []
    var current = ""
    for character in name {
        if character == "_" || character == "-" || character == "." {
            words.append(current)
            current = ""
        } else if character.isUppercase, let last = current.last, last.isLowercase {
            words.append(current)
            current = String(character)
        } else {
            current.append(character)
        }
    }
    words.append(current)
    let kept = words.filter { !$0.isEmpty }.map { $0.lowercased() }
        .filter { $0 != "url" && $0 != "link" }
    guard let first = kept.first else { return name }
    return ([first.prefix(1).uppercased() + first.dropFirst()] + kept.dropFirst())
        .joined(separator: " ")
}
