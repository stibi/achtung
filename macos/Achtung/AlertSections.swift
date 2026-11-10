import AchtungDomain
import AppKit
import SwiftUI

/// The summary and the description as text to read, links clickable, on one card.
struct AlertProse: View {
    let alert: IncomingAlert

    var body: some View {
        let description = alert.alertDescription.flatMap { $0 == alert.summary ? nil : $0 }
        if alert.summary != nil || description != nil {
            VStack(alignment: .leading, spacing: 10) {
                if let summary = alert.summary {
                    Text(linkified(summary))
                        .font(.title3)
                }
                if let description {
                    Text(linkified(description))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The alert's links and its URL annotations as buttons.
struct AlertLinkButtons: View {
    let alert: IncomingAlert

    @Environment(\.openURL) private var openURL

    var body: some View {
        ForEach(alert.links, id: \.url) { link in
            button(
                link.kind.rawValue.capitalized, symbol: link.kind.symbolName, url: link.url,
                help: link.url.absoluteString)
        }
        ForEach(alert.linkAnnotations, id: \.name) { annotation in
            button(
                linkTitle(forAnnotation: annotation.name), symbol: "link", url: annotation.url,
                help: "\(annotation.name): \(annotation.url.absoluteString)")
        }
    }

    private func button(_ title: String, symbol: String, url: URL, help: String) -> some View {
        Button {
            openURL(url)
        } label: {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.bordered)
        .help(help)
    }
}

/// Every annotation, the summary and description first, one per line: the name on the
/// left, the value wrapping on the right, URLs clickable.
struct AnnotationsSection: View {
    let alert: IncomingAlert

    var body: some View {
        if !alert.annotations.isEmpty {
            DetailSection(title: "Annotations", symbol: "text.alignleft") {
                KeyValueRows(
                    entries: alert.orderedAnnotations.map {
                        KeyValueRows.Entry(name: $0.name, value: $0.value)
                    })
            }
        }
    }
}

/// The labels, one per line, the ones that say what and where first, severity in its
/// colour.
struct LabelsSection: View {
    let alert: IncomingAlert

    var body: some View {
        if !alert.labels.isEmpty {
            DetailSection(title: "Labels", symbol: "tag") {
                KeyValueRows(
                    entries: alert.orderedLabels.map {
                        KeyValueRows.Entry(
                            name: $0.name, value: $0.value,
                            tint: $0.name == "severity" ? alert.severity.color : nil)
                    }, isLabels: true)
            }
        }
    }
}

/// Name and value rows on a card, divided, names in one column. Hovering a row shows a
/// button that copies `name=value`; its context menu has the other forms.
private struct KeyValueRows: View {
    struct Entry {
        let name: String
        let value: String
        var tint: Color?
    }

    let entries: [Entry]
    /// Labels also copy as a PromQL matcher.
    var isLabels = false

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.name) { index, entry in
                if index > 0 {
                    Divider()
                        .gridCellUnsizedAxes(.horizontal)
                }
                KeyValueRow(entry: entry, isLabel: isLabels)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

private struct KeyValueRow: View {
    let entry: KeyValueRows.Entry
    let isLabel: Bool

    @State private var isHovered = false
    /// Counts copies; the checkmark shows for a moment from the latest one.
    @State private var copies = 0
    @State private var copied = false

    var body: some View {
        GridRow {
            Text(entry.name)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .gridColumnAlignment(.leading)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Not Markdown: values are often PromQL or regexes, whose `*` and `\`
                // must stay as they are.
                Text(linkified(entry.value, markdown: false))
                    .font(.callout)
                    .fontWeight(entry.tint == nil ? .regular : .semibold)
                    .foregroundStyle(entry.tint ?? .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    copy("\(entry.name)=\(entry.value)")
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .opacity(isHovered || copied ? 1 : 0)
                .help("Copy \(entry.name)=…")
                .accessibilityLabel("Copy \(entry.name)")
            }
        }
        .padding(.vertical, 7)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Copy \(entry.name)=…") { copy("\(entry.name)=\(entry.value)") }
            Button("Copy Value") { copy(entry.value) }
            if isLabel {
                Button("Copy as PromQL Matcher") {
                    copy("\(entry.name)=\"\(promQLEscaped(entry.value))\"")
                }
            }
        }
        .task(id: copies) {
            guard copies > 0 else { return }
            withAnimation(.snappy) { copied = true }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { copied = false }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copies += 1
    }

    /// A PromQL string literal's content: backslashes and double quotes escaped.
    private func promQLEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// A titled card in the alert's details.
private struct DetailSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 12))
        }
    }
}

/// Lays its subviews out left to right, wrapping onto a new line when the next doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var top = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var left = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.init(width: bounds.width, height: nil))
                subviews[index].place(
                    at: CGPoint(x: left, y: top), proposal: .init(width: size.width, height: nil))
                left += size.width + spacing
            }
            top += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.init(width: width, height: nil))
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += row.indices.isEmpty ? size.width : size.width + spacing
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// The text with bare http(s) URLs made links; with `markdown`, inline Markdown (links,
/// emphasis, code) too.
func linkified(_ text: String, markdown: Bool = true) -> AttributedString {
    var attributed =
        markdown
        ? (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        : AttributedString(text)
    let plain = String(attributed.characters)
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return attributed }
    for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
        guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased()),
            let range = Range(match.range, in: plain),
            let target = Range(range, in: attributed), attributed[target].link == nil
        else { continue }
        attributed[target].link = url
    }
    return attributed
}
