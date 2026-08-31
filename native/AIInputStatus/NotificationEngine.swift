import Foundation
import UserNotifications

@MainActor
enum NotificationEngine {
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func notifyTest() async {
        let content = UNMutableNotificationContent()
        content.title = "AI INPUT 通知测试"
        content.body = "本地通知功能正常。"
        content.sound = .default
        content.threadIdentifier = "ai-input-status"
        let request = UNNotificationRequest(identifier: "ai-input-test-\(Int(Date().timeIntervalSince1970))", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func notifyStatusOpened(_ events: [StatusEvent]) async {
        guard !events.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "AI INPUT 状态异常"
        content.body = events.count == 1 ? "\(sourceLabel(events[0].source)) · \(events[0].target) · \(events[0].detail)" : "有 \(events.count) 项监测异常"
        content.sound = .default
        content.threadIdentifier = "ai-input-status"
        let identifier = "ai-input-status-opened-\(Int(Date().timeIntervalSince1970))"
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    static func notifyStatusRecovered(_ events: [StatusEvent]) async {
        guard !events.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "AI INPUT 已恢复"
        content.body = events.count == 1 ? "\(events[0].target) 已恢复正常" : "有 \(events.count) 项监测已恢复正常"
        content.sound = .default
        content.threadIdentifier = "ai-input-status"
        let identifier = "ai-input-status-recovered-\(Int(Date().timeIntervalSince1970))"
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    static func notifyQuota(_ plan: SubscriptionPlan, threshold: Int, resetLabel: String) async {
        let content = UNMutableNotificationContent()
        content.title = "AI INPUT 每日额度提醒"
        content.subtitle = "\(plan.name) 已用 \(String(format: "%.1f", plan.usagePercent))%"
        content.body = "今日剩余 $\(String(format: "%.2f", plan.remainingUSD)) / $\(String(format: "%.2f", plan.dailyLimitUSD)) · \(resetLabel)"
        content.sound = threshold >= 95 ? .default : nil
        content.threadIdentifier = "ai-input-subscription"
        let identifier = "ai-input-quota-\(plan.id)-\(threshold)"
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    static func scheduleExpiry(_ plan: SubscriptionPlan, daysBefore: Int) async {
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(identifier: "Asia/Shanghai") else { return }
        calendar.timeZone = zone
        let expiryDay = calendar.startOfDay(for: plan.expiresAt)
        guard let targetDay = calendar.date(byAdding: .day, value: -daysBefore, to: expiryDay),
              let triggerDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: targetDay),
              triggerDate > Date() else { return }
        let components = calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: triggerDate)
        let content = UNMutableNotificationContent()
        content.title = "AI INPUT 订阅即将到期"
        content.body = "\(plan.name) 还有 \(daysBefore) 天到期 · 到期日 \(SubscriptionEngine.shortDate(plan.expiresAt))"
        content.sound = daysBefore == 1 ? .default : nil
        content.threadIdentifier = "ai-input-subscription"
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let identifier = "ai-input-expiry-\(plan.id)-\(daysBefore)"
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    private static func sourceLabel(_ source: StatusEvent.Source) -> String {
        switch source {
        case .official: return "官方状态"
        case .gateway: return "本机网关"
        case .custom: return "自定义监测"
        }
    }
}
