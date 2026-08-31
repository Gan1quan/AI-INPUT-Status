# AI INPUT Status

AI INPUT 状态监控应用与 RootHide 后台轮询服务，最低支持 iOS 16.1。

## v3.6.0 功能

- 模型状态、延迟、60 分钟 / 3 小时 / 4 小时真实时间窗口统计；
- 明确区分：未配置、等待首次检测、接口未返回模型、过期缓存、异常与正常；
- 状态筛选数量、搜索、异常优先/延迟/可用率/名称排序、模型/供应商/账号分组；
- 单模型重新检测、完整模型详情、备用模型建议和结构化诊断修复；
- 小号、中号、大号 Widget，共用 App Group 数据协议，支持选择显示全部或单个模型；
- 订阅额度、到期提醒、通知权限和测试通知；
- 自定义 HTTPS 监测、最近异常事件、JSON/CSV 诊断导出；
- 可选择时间范围、类型和 TXT/JSON/CSV 格式的日志导出；日志不包含 Token；
- RootHide 后台日志读取与后台请求/成功/失败计数清零（需要配套 DEB v1.2.0）。

## 架构

- IPA 优先调用本机 RootHide 守护进程 `127.0.0.1:17891/refresh`；不可用时回退公共状态 API。
- RootHide DEB `aiinputstatusd` 负责周期拉取、缓存、重试、结构化轮询日志和本机接口。
- Widget 只读取 App Group 中由主应用写入的 `ai-input-widget-data-v2` 快照，不读取 Token。
- iOS 后台刷新由系统决定触发时间；RootHide DEB 可提供更持续的后台轮询。

## 构建

- GitHub Actions → **Build IPA** → `AI-INPUT-Status-v3.6.0-native`
- GitHub Actions → **Build RootHide Background DEB** → `AI-INPUT-Status-Background-v1.2.0-arm64e`

IPA 未签名，需要 TrollStore 或其他适用签名方式安装。DEB 仅适用于已配置 RootHide 环境的 arm64e 设备。

## 后台本机接口

```sh
curl -sS http://127.0.0.1:17891/status
curl -sS http://127.0.0.1:17891/refresh
curl -sS http://127.0.0.1:17891/logs
curl -sS -X POST http://127.0.0.1:17891/reset-counts
```
