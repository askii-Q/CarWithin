# 源码构建说明

使用 Xcode 打开 TDSCarKit.xcodeproj，选择 TDSCarKit scheme，配置自己的开发团队、Bundle ID 和签名，再构建 iOS 目标。最低部署目标为 iOS 16.0。

源码不包含配件认证身份、私钥、证书或 Apple 签名材料。没有可用身份时应用可编译，但本机 CarPlay 连接需要另行配置有效身份。Tools/generate_project.py 会将本地 App/BundledIdentity 内的文件加入生成的工程，请勿把该目录中的身份材料提交到公开仓库。

发布安装包与源码应对应同一代码版本。第三方许可与来源见 THIRD_PARTY_NOTICES.txt 和 LICENSES。

## 让装好的包直接带身份

应用启动时按三条路径找身份：Keychain（同签名、同 Team 的旧安装遗留）→ 应用包内置资源 → 手动导入。CI 里的干净构建三者都没有，所以会显示「需要导入 MFi 身份」，启动按钮置灰。要出货即用，二选一：

```bash
# 1) 本机 macOS：把三件套放进被 .gitignore 忽略的目录，再打包
mkdir -p App/BundledIdentity
# certificate.p7b / leaf.cer / private.x963 三个文件名必须一字不差
bash Tools/build_ipa.sh
```

2) GitHub Actions：仓库变量 `INJECT_MFI_IDENTITY=true`，并配置 Secrets `MFI_CERTIFICATE_P7B_B64`、`MFI_LEAF_CER_B64`、`MFI_PRIVATE_X963_B64`（文件内容 base64），`ipa.yml` 会在构建前把它们写进 `App/BundledIdentity/`。注入后的 IPA 内含身份材料，公开仓库的 artifact 会被他人下载，私有使用请把仓库设为 private 或改走本机打包。

身份材料缺失时应用仍可编译、可起 HTTP 接收页，只是无法启动本机 CarPlay。

## 初始化自检

首次克隆或换机器后，先运行：

```bash
bash Tools/init.sh          # 自检：换行、Python 脚本、工程一致性、工具链
bash Tools/init.sh --fix-eol  # 发现 CRLF 时归一化为 LF
```

Windows/Linux 只能做源码修改与静态校验；`swift test`、`xcodebuild` 与 `generate_project.py` 需要 macOS。
完整的目录说明、命令与提交禁区见 [AGENTS.md](AGENTS.md)。
