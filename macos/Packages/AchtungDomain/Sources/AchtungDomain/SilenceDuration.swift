import Foundation

/// How long a silence lasts, as the client offers it. The server accepts any duration from
/// a minute to 30 days; these are the choices on the silence button.
public enum SilenceDuration: String, Sendable, CaseIterable, Identifiable {
    case oneHour = "1h"
    case fourHours = "4h"
    case oneDay = "1d"
    case oneWeek = "1w"

    public var id: String { rawValue }

    /// Short label, e.g. "4h".
    public var title: String { rawValue }

    public var seconds: Int {
        switch self {
        case .oneHour: 3600
        case .fourHours: 4 * 3600
        case .oneDay: 24 * 3600
        case .oneWeek: 7 * 24 * 3600
        }
    }
}
