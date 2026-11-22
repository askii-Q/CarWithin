# AGENTS.md · CarWithin 项目初始化说明

面向在本仓库里工作的开发者与自动化代理。读完这一页应当能：知道每个目录做什么、在什么系统上跑什么命令、哪些东西绝对不能提交。

## 1. 项目是什么

CarWithin 是一个 iOS 16+ 应用：在同一台 iPhone 上启动、显示并触控本机 CarPlay，并把画面和声音转发给局域网内的浏览器、平板、电脑或指定车机仪表（CarLife 无线、AirPlay、极核/九号/台铃仪表）。

- 核心库 `TDSCarKitCore`：CarPlay 配件协议（IAP2、MFiSAP、Pair-Setup/Verify、OPACK、RTSP、Screen/Audio Stream、Annex-B、FragmentedMP4）。
- 应用层 `App/`：UIKit 界面、输出通路、HTTPS 接收页、项目内嵌的更新与诊断。
- 语言与许可：Swift 5 + 少量 C/ObjC 桥接；整体 AGPL-3.0-only，第三方许可见 `THIRD_PARTY_NOTICES.txt`、`LICENSES/`、`ThirdParty/`。

## 2. 目录结构

| 路径 | 作用 |
| --- | --- |
| `App/` | iOS 应用全部源码、`Info.plist`、`Assets.xcassets`、`TDSCarKit-Bridging-Header.h`、entitlements |
| `Sources/TDSCarKitCore/` | 纯协议实现，可被 SwiftPM 单独编译与测试；`Vendor/BigInt` 为 MIT 引入的第三方实现 |
| `Sources/CTDSCarKitCrypto/` | C 层加解密/哈希封装，头文件在 `include/` |
| `Tests/TDSCarKitCoreTests/` | XCTest 用例（依赖 `CryptoKit` / `Security`，只在 Apple 平台运行） |
| `Tools/` | 工程生成、Smoke 工具、测试与构建脚本 |
| `TDSCarKit.xcodeproj/` | **生成产物**，由 `Tools/generate_project.py` 从磁盘上的源码生成 |
| `docs/support/` | README 用的赞赏码图片 |
| `LICENSES/`、`ThirdParty/` | 许可全文与第三方声明 |

## 3. 环境要求

两个层次，按能做的事区分：

**A. 完整开发（macOS + Xcode 15 及以上）**

- Xcode 15+，命令行工具指向同一 Xcode（`xcode-select -p`）。
- `swift`、`xcodebuild`、`plutil`、`python3`、`bash`。
- 真机联调需要自己的开发团队、Bundle ID、签名；CarPlay 本机连接还需要有效的配件认证身份材料，仓库不提供。

**B. 只改代码 / 静态校验（Windows、Linux）**

- `git`、`python3`（或 `python`）、`bash`。
- 能做：阅读与修改源码、跑 Python 脚本语法检查、核对工程文件与源码一致性、维护文档。
- 不能做：`swift build` / `swift test`、`xcodebuild`、`generate_project.py`（它调用 `plutil` 保留本机签名配置）。这些必须在 macOS 上完成。

## 4. 常用命令

```bash
# 环境自检（首次克隆后先跑这个）
bash Tools/init.sh

# 单元测试（macOS；工程内已固定模块缓存路径，避免污染仓库）
bash Tools/test.sh

# 生成/刷新 Xcode 工程（macOS；会保留已有工程的签名设置）
python3 Tools/generate_project.py

# Catalyst 构建并做代码签名校验
bash Tools/build_mac.sh          # 加 --open 可直接启动

# 其它 Smoke 工具
bash Tools/test_listener.sh
bash Tools/test_tailing.sh
bash Tools/test_audio.sh
bash Tools/test_browser_stream.py
```

Visual Studio / Xcode 之外的编辑器可以直接改源码，但**新增或删除 `App/` 下的源文件后，必须在 macOS 上重跑 `generate_project.py`**，否则工程不会引用到新文件。

## 5. 换行与格式约定

- 仓库统一 **LF**，规则写在 `.gitattributes`（`* text=auto eol=lf`）；二进制资源标记为 `binary`。
- 本地已设置 `git config core.autocrlf false`。在 Windows 上工作请不要改回 `true`，否则 `git status` 会把整库标成已修改。
- 缩进为 4 空格，UTF-8，文件末尾保留换行，见 `.editorconfig`。

## 6. 不能提交的内容

`.gitignore` 已覆盖，但仍需人肉确认：

- 配件认证身份材料：`App/BundledIdentity/`、`mfi/`、`offline-mfi/`、`IdentityImport/`、`*.p12`、`*.p8`、`*.cer`、`*.mobileprovision`。
- 本机配置与凭据：`.local/`、`.env*`、`*.key`、`*.pem`、`*.x963`。
- 构建产物：`.build/`、`DerivedData/`、`*.app/`、`*.ipa`、`*.xcarchive/`。

## 7. 修改代码时的注意点

- `Sources/TDSCarKitCore` 不依赖 UIKit，新逻辑尽量放在这里并补 XCTest；改动协议字段优先在 `Tests/` 里构造字节级用例。
- `App/` 大量使用 iOS 私有接口（虚拟配件、CarPlay 会话），系统升级后可能失效；不要把私有实现细节写进 README 的「已验证」结论里。
- 局域网接收页当前没有登录校验，改动网络出口时保持「默认最小暴露」：仅在用户主动开启时监听，端口可配置。
- 版本号同时存在 `App/Info.plist`（`CFBundleShortVersionString` / `CFBundleVersion`）与 README 顶部说明，发版时一起改。

## 8. 常见故障

| 现象 | 处理 |
| --- | --- |
| `git status` 全库已修改 | 说明换行被改成 CRLF：`git config core.autocrlf false && git checkout-index -f -a` |
| `generate_project.py` 报找不到 `plutil` | 当前不是 macOS，工程生成只能在 macOS 上跑 |
| `swift test` 报找不到 `Security` / `CryptoKit` | 非 Apple 平台不支持，改在 macOS 或 CI 上跑 |
| 新增 Swift 文件后 Xcode 里看不到 | 重跑 `generate_project.py`，或临时在 Xcode 里手动加入 |
