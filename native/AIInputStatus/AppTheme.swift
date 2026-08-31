import Foundation
import SwiftUI
import UIKit

struct AppTheme {
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.025, green: 0.040, blue: 0.032, alpha: 1)
            : UIColor(red: 0.965, green: 0.980, blue: 0.970, alpha: 1)
    })
    static let card = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.105, green: 0.125, blue: 0.112, alpha: 1)
            : UIColor.white
    })
    static let controlBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.14, green: 0.17, blue: 0.15, alpha: 1)
            : UIColor(red: 0.90, green: 0.94, blue: 0.91, alpha: 1)
    })
    static let primary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .white : UIColor(red: 0.055, green: 0.095, blue: 0.075, alpha: 1)
    })
    static let secondary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.68, green: 0.75, blue: 0.71, alpha: 1) : UIColor(red: 0.30, green: 0.38, blue: 0.33, alpha: 1)
    })
    static let green = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.18, green: 0.92, blue: 0.50, alpha: 1) : UIColor(red: 0.00, green: 0.45, blue: 0.25, alpha: 1)
    })
    static let red = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0.40, blue: 0.47, alpha: 1) : UIColor(red: 0.72, green: 0.08, blue: 0.13, alpha: 1)
    })
    static let amber = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0.75, blue: 0.30, alpha: 1) : UIColor(red: 0.58, green: 0.34, blue: 0, alpha: 1)
    })
    static let missing = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.19, green: 0.27, blue: 0.22, alpha: 1) : UIColor(red: 0.78, green: 0.84, blue: 0.80, alpha: 1)
    })
    static let divider = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.18, green: 0.26, blue: 0.20, alpha: 1) : UIColor(red: 0.70, green: 0.76, blue: 0.72, alpha: 1)
    })

    // Semantic fonts preserve Dynamic Type while keeping metrics monospaced.
    static let monoTitle = Font.system(.title2, design: .monospaced).weight(.bold)
    static let monoModel = Font.system(.title3, design: .monospaced).weight(.bold)
    static let monoBody = Font.system(.body, design: .monospaced)
    static let monoMeta = Font.system(.subheadline, design: .monospaced)
    static let monoSmall = Font.system(.footnote, design: .monospaced)
}

struct FilledActionButtonStyle: ButtonStyle {
    var color: Color = AppTheme.green
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundColor(AppTheme.background)
            .frame(maxWidth: .infinity, minHeight: 46)
            .padding(.horizontal, 12)
            .background(color.opacity(configuration.isPressed ? 0.65 : 0.92))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct BorderedActionButtonStyle: ButtonStyle {
    var color: Color = AppTheme.green
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundColor(color)
            .frame(maxWidth: .infinity, minHeight: 46)
            .padding(.horizontal, 12)
            .background(color.opacity(configuration.isPressed ? 0.18 : 0.08))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(color.opacity(0.55), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

func money(_ value: Double) -> String { String(format: "$%.2f", value) }

func clock(_ date: Date?) -> String {
    guard let date else { return "--:--:--" }
    return date.formatted(date: .omitted, time: .shortened)
}

func stateColor(_ state: ServiceState) -> Color {
    switch state {
    case .online: return AppTheme.green
    case .stale, .notConfigured: return AppTheme.amber
    case .waiting, .unknown: return AppTheme.secondary
    default: return AppTheme.red
    }
}

func stateIcon(_ state: ServiceState) -> String {
    switch state {
    case .online: return "checkmark.circle.fill"
    case .waiting: return "hourglass"
    case .notConfigured, .misconfigured: return "wrench.and.screwdriver.fill"
    case .stale: return "clock.badge.exclamationmark.fill"
    case .unknown: return "questionmark.circle.fill"
    default: return "xmark.octagon.fill"
    }
}

func stateText(_ state: ServiceState) -> String {
    switch state {
    case .online: return "正常"
    case .waiting: return "待检测"
    case .notConfigured: return "接口未返回"
    case .offline: return "不可用"
    case .misconfigured: return "配置错误"
    case .unauthorized: return "认证失败"
    case .quotaExhausted: return "额度耗尽"
    case .rateLimited: return "限流"
    case .timeout: return "超时"
    case .networkError: return "网络异常"
    case .serverError: return "服务端异常"
    case .clientError: return "请求异常"
    case .stale: return "数据过期"
    case .unknown: return "未知"
    }
}
