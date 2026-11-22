# 源码构建说明

使用 Xcode 打开 TDSCarKit.xcodeproj，选择 TDSCarKit scheme，配置自己的开发团队、Bundle ID 和签名，再构建 iOS 目标。最低部署目标为 iOS 16.0。

源码不包含配件认证身份、私钥、证书或 Apple 签名材料。没有可用身份时应用可编译，但本机 CarPlay 连接需要另行配置有效身份。Tools/generate_project.py 会将本地 App/BundledIdentity 内的文件加入生成的工程，请勿把该目录中的身份材料提交到公开仓库。

发布安装包与源码应对应同一代码版本。第三方许可与来源见 THIRD_PARTY_NOTICES.txt 和 LICENSES。

## 初始化自检

首次克隆或换机器后，先运行：

```bash
bash Tools/init.sh          # 自检：换行、Python 脚本、工程一致性、工具链
bash Tools/init.sh --fix-eol  # 发现 CRLF 时归一化为 LF
```

Windows/Linux 只能做源码修改与静态校验；`swift test`、`xcodebuild` 与 `generate_project.py` 需要 macOS。
完整的目录说明、命令与提交禁区见 [AGENTS.md](AGENTS.md)。
