# AI INPUT Status Native

原生 SwiftUI IPA，对齐 Scripting 3.4.2 的非 Widget 功能，最低支持 iOS 16.1。

## 已实现

- RootHide DEB 优先的公共状态读取（127.0.0.1:17891/refresh）；无 RootHide 时自动回退公共 API；
- iOS BGAppRefreshTask 后台状态刷新（系统调度，非固定周期）；
- 官方模型状态与 60/180/240 分钟历史窗口；
- 网关 HEAD 延迟（三次并发取中位数）和 HTTP 分类；
- 最多 20 个自定义 HTTPS 监测目标；
- 结构化诊断、异常/恢复事件；
- 订阅额度、每日/每周/每月用量、余额和到期日；
- Token 仅存储在 iOS Keychain；
- 额度趋势和耗尽预估；
- 状态、额度、到期本地通知；
- 浅色/深色自适应终端风格 UI。

## 明确不包含

- Widget：目标系统为 iOS 16.1，本项目按要求不构建 Widget Extension；
- DEB 修改：继续使用现有 RootHide DEB 1.1.1，IPA 不向 daemon 下发 Token。

## 构建

GitHub Actions → `Build IPA` → Artifact `AI-INPUT-Status-v3.4.2-native`。

这是未签名 IPA，需要 TrollStore 或其他适用签名工具安装。
