# AI INPUT Status Native

独立 SwiftUI iOS App，最低支持 iOS 16.1。不包含 Widget Extension。

## 功能

- 前台运行时每 30 秒请求 `https://status.input.im/api/status`
- App 从后台回到前台时立即刷新
- 下拉刷新和右上角手动刷新
- 刷新失败时显示具体错误、缓存时间和重试入口
- 持久化记录最后尝试、成功、失败、请求间隔和执行来源
- 仅显示 `gpt-5.6-sol`、`gpt-5.6-terra`
- 保留最近状态缓存，网络失败时显示缓存并标记错误
- 双服务状态卡、可用率、延迟和最近 60 次探测历史
- 深色玻璃质感 SwiftUI 界面
- 最低 iOS 16.1

## GitHub 构建

1. 将本目录上传到自己的 GitHub 仓库。
2. 打开 `Actions` -> `Build IPA` -> `Run workflow`。
3. 在构建完成的 workflow 页面下载 `AI-INPUT-Status-v3.2.0` artifact。
4. 解压得到 `AI-INPUT-Status-v3.2.0.ipa`。
5. 使用 TrollStore 或签名工具安装/重新签名。

这是未签名 IPA。未签名包不能直接通过普通自签安装，TrollStore 或签名工具需要对包进行相应处理。

## 构建前提

GitHub workflow 使用 `macos-14`、Xcode 15.4 和 XcodeGen。工程配置目标为 iOS 16.1。

## 运行边界

30 秒刷新只在 App 处于前台时稳定执行。系统 background fetch 仅在 iOS 主动调度时执行一次请求，并会在设置页留下实际记录；不能作为严格 30 秒后台轮询保证。切回前台时 App 会立即刷新；不依赖 iOS WidgetKit。
