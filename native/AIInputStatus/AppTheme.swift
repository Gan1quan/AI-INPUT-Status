import SwiftUI

enum AppTheme {
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.025, green: 0.040, blue: 0.032, alpha: 1)
            : UIColor(red: 0.965, green: 0.980, blue: 0.970, alpha: 1)
    })
    static let primary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.94, green: 0.98, blue: 0.95, alpha: 1)
            : UIColor(red: 0.055, green: 0.095, blue: 0.075, alpha: 1)
    })
    static let secondary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.64, green: 0.70, blue: 0.66, alpha: 1)
            : UIColor(red: 0.32, green: 0.39, blue: 0.35, alpha: 1)
    })
    static let green = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.18, green: 0.92, blue: 0.50, alpha: 1)
            : UIColor(red: 0.00, green: 0.45, blue: 0.25, alpha: 1)
    })
    static let red = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.40, blue: 0.47, alpha: 1)
            : UIColor(red: 0.72, green: 0.08, blue: 0.13, alpha: 1)
    })
    static let amber = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.75, blue: 0.30, alpha: 1)
            : UIColor(red: 0.58, green: 0.34, blue: 0.00, alpha: 1)
    })
    static let missing = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.17, green: 0.23, blue: 0.19, alpha: 1)
            : UIColor(red: 0.79, green: 0.84, blue: 0.81, alpha: 1)
    })
    static let divider = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.16, green: 0.23, blue: 0.18, alpha: 1)
            : UIColor(red: 0.70, green: 0.75, blue: 0.72, alpha: 1)
    })
    static let monoTitle = Font.system(size: 20, weight: .bold, design: .monospaced)
    static let monoModel = Font.system(size: 17, weight: .bold, design: .monospaced)
    static let monoBody = Font.system(size: 14, weight: .regular, design: .monospaced)
    static let monoMeta = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let monoSmall = Font.system(size: 10, weight: .regular, design: .monospaced)
}

extension View {
    @ViewBuilder
    func statusSectionTitle() -> some View {
        self.font(.system(size: 21, weight: .bold, design: .rounded)).foregroundColor(AppTheme.primary)
    }
}

func money(_ value: Double) -> String { String(format: "$%.2f", value) }

func clock(_ date: Date?) -> String {
    guard let date else { return "--:--:--" }
    return date.formatted(date: .omitted, time: .shortened)
}

func shortDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy/M/d"
    return formatter.string(from: date)
}

func percent(_ value: Double?) -> String {
    guard let value else { return "--" }
    return String(format: "%.1f%%", value)
}

func duration(_ value: TimeInterval) -> String {
    let seconds = max(0, Int(value))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
}

func stateColor(_ state: ServiceState) -> Color {
    switch state {
    case .online: return AppTheme.green
    case .offline: return AppTheme.red
    case .stale: return AppTheme.amber
    case .unknown: return AppTheme.secondary
    }
}

func stateText(_ state: ServiceState) -> String {
    switch state {
    case .online: return "online"
    case .offline: return "offline"
    case .stale: return "stale"
    case .unknown: return "unknown"
    }
}
