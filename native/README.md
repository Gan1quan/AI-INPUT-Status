# AI INPUT Status Native

独立 SwiftUI iOS App，最低支持 iOS 16.1，版本 3.3.2。

## 后台架构

IPA 不再把系统 Background Fetch 当成固定定时器。安装 RootHide DEB 后，SpringBoard 通过 Darwin notification 唤醒 `aiinputstatusd`，daemon 每 30 秒轮询并保存状态；IPA 通过 `127.0.0.1:17891/refresh` 获取 daemon 的 `payload`。daemon 不存在时，IPA 回退到公网 API。

系统 Background Fetch 已移除，后台统一由 SpringBoard → DEB 负责。

## GitHub 构建

1. 打开 Actions → `Build IPA` → 运行 workflow，下载 `AI-INPUT-Status-v3.3.2`。
2. 使用 TrollStore 或其他适用签名工具安装未签名 IPA。
3. 打开 Actions → `Build RootHide Background DEB`，下载 `AI-INPUT-Status-Background-v1.1.1-arm64e`。
4. 在 Dopamine RootHide 环境安装 DEB，重启 SpringBoard，再打开 IPA。
5. 在设置页确认“后台插件：运行中”。

## 设备排查

```sh
curl -sS http://127.0.0.1:17891/status
curl -sS http://127.0.0.1:17891/refresh
cat /var/aiinputstatusd-state.json
cat /var/aiinputstatusd.log
```

注意：RootHide 使用随机 jbroot，工程没有硬编码 `/var/jb`。如果 daemon 未运行，先检查 launchd 服务和 SpringBoard tweak 注入，不要重复安装 IPA。
