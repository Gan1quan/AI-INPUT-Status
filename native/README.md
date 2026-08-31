# AI INPUT Status Native v3.6.0

原生 SwiftUI IPA，最低支持 iOS 16.1。

## 主要能力

- 优先读取 RootHide DEB 状态，回退公共 API；
- 模型状态、真实时间窗口历史、延迟 p50/p95/最大值；
- 区分正常、待检测、接口未返回、缓存过期、配置/认证/额度/限流/网络等状态；
- 大尺寸触控控件、搜索、筛选数量、空结果反馈、排序和分组；
- 小号 / 中号 / 大号 Widget，使用 App Group 共享快照；
- 模型详情、单模型重新检测、诊断修复、备用模型建议；
- 订阅额度、本地通知与测试通知、自定义 HTTPS 监测；
- 诊断报告和可选择类型/范围/格式的日志导出。

## 配套后台服务

RootHide DEB v1.2.0 提供后台轮询日志以及请求计数清零接口。未安装 DEB 时，IPA 仍会回退公共 API；后台日志和清零操作会提示安装配套 DEB。

## 构建

GitHub Actions → **Build IPA** → `AI-INPUT-Status-v3.6.0-native`。

这是未签名 IPA，需要 TrollStore 或其他适用签名工具安装。
