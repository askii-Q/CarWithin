#!/bin/bash
# 构建未签名 IPA，供 Sideloadly / AltStore / 自签工具在自有设备上重签安装。
# 只能在 macOS + Xcode 15 上跑；Windows/Linux 请改用 .github/workflows/ipa.yml。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="${TDS_IPA_DIR:-$root/build}"
version="$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleShortVersionString"])' \
  "$root/App/Info.plist" 2>/dev/null || echo 0.0.0)"
archive="$out_dir/TDSCarKit.xcarchive"
ipa="${1:-$out_dir/CarWithin-$version-unsigned.ipa}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "缺少 xcodebuild：请在 macOS 上运行，或推送后触发 GitHub Actions 的 IPA 流水线" >&2
  exit 1
fi

mkdir -p "$out_dir"
rm -rf "$archive" "$out_dir/Payload" "$ipa"

# 工程是生成产物：先按磁盘上的源码刷新，避免新增文件漏进 target。
python3 "$root/Tools/generate_project.py"

xcodebuild -project "$root/TDSCarKit.xcodeproj" -scheme TDSCarKit -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  -derivedDataPath "$out_dir/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="$root/App/TDSCarKit.entitlements" \
  archive

app="$archive/Products/Applications/TDSCarKit.app"
if [[ ! -d "$app" ]]; then
  echo "没有生成 $app" >&2
  exit 1
fi

mkdir -p "$out_dir/Payload"
cp -R "$app" "$out_dir/Payload/"
(cd "$out_dir" && zip -qry "$ipa" Payload)
rm -rf "$out_dir/Payload"

printf '未签名 IPA：%s\n大小：%s\n' "$ipa" "$(du -h "$ipa" | cut -f1)"
