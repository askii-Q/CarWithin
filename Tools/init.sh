#!/usr/bin/env bash
# CarWithin 环境自检 / 初始化脚本
#
# 幂等：只读取与修复可安全修复的本地状态，不改动任何源码内容。
#
#   bash Tools/init.sh                 自检
#   bash Tools/init.sh --fix-eol       检查到 CRLF 时一并归一化为 LF
#   bash Tools/init.sh --regenerate    在 macOS 上重跑 generate_project.py
#
# 退出码：0 全部通过（允许的跳过不计），1 存在需要处理的问题。
set -uo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root" || exit 1

fix_eol=0
regenerate=0
for arg in "$@"; do
  case "$arg" in
    --fix-eol) fix_eol=1 ;;
    --regenerate) regenerate=1 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf '未知参数：%s（可用 --fix-eol / --regenerate）\n' "$arg"; exit 2 ;;
  esac
done

fails=0
warns=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[36m–\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; warns=$((warns + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fails=$((fails + 1)); }

uname_s="$(uname -s 2>/dev/null || echo unknown)"
printf 'CarWithin 环境自检\n项目根目录：%s\n平台：%s\n\n' "$project_root" "$uname_s"

# ---------------------------------------------------------------- 1. git 仓库
printf '[1/6] Git 仓库\n'
if ! command -v git >/dev/null 2>&1; then
  bad "未找到 git"
elif ! git rev-parse --git-dir >/dev/null 2>&1; then
  bad "当前目录不是 git 仓库"
else
  ok "仓库可识别，分支 $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  tracked="$(git ls-files | wc -l | tr -d ' ')"
  ok "已跟踪文件 $tracked 个"
  autocrlf="$(git config --get core.autocrlf 2>/dev/null || true)"
  if [ "$autocrlf" = "false" ]; then
    ok "core.autocrlf=false"
  elif [ -z "$autocrlf" ]; then
    git config core.autocrlf false && ok "core.autocrlf 未设置，已写为 false"
  else
    git config core.autocrlf false && warn "core.autocrlf 为 '$autocrlf'，已改为 false"
  fi
fi

# ------------------------------------------------------------------ 2. 换行
printf '\n[2/6] 换行格式（应为 LF）\n'
if git rev-parse --git-dir >/dev/null 2>&1; then
  crlf_files="$(git ls-files --eol | awk '$2 == "w/crlf" { print $NF }')"
  crlf_count="$(printf '%s' "$crlf_files" | grep -c . || true)"
  if [ "${crlf_count:-0}" -eq 0 ]; then
    ok "工作区全部为 LF"
  elif [ "$fix_eol" -eq 1 ]; then
    git checkout-index -f -a && ok "已按 .gitattributes 归一化 $crlf_count 个文件为 LF"
  else
    warn "$crlf_count 个文件为 CRLF：$(printf '%s' "$crlf_files" | head -3 | tr '\n' ' ')..."
    printf '    修复：bash Tools/init.sh --fix-eol\n'
  fi
  if [ -f .gitattributes ]; then ok ".gitattributes 存在"; else bad "缺少 .gitattributes"; fi
else
  skip "非 git 仓库，跳过"
fi

# ------------------------------------------------------------------ 3. Python
printf '\n[3/6] Python（Tools/ 脚本）\n'
# Windows 控制台默认 GBK，强制子进程按 UTF-8 输出中文，避免乱码
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8
py=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1; then
    if ver="$("$cand" --version 2>&1)" && printf '%s' "$ver" | grep -qE 'Python 3\.'; then
      py="$cand"; break
    fi
  fi
done
if [ -z "$py" ]; then
  warn '未找到可用的 Python 3（Windows 上 python 可能只是应用商店占位符）'
  printf '    Tools/generate_project.py 等脚本需要在装有 Python 3 的机器上运行\n'
else
  ok "$py：$("$py" --version 2>&1)"
  if "$py" - <<'PY'
import glob, sys
files = sorted(glob.glob('Tools/*.py'))
for f in files:
    source = open(f, encoding='utf-8').read()
    compile(source, f, 'exec')
print('检查 %d 个脚本' % len(files))
PY
  then ok "Tools/*.py 语法通过"; else bad "Tools/*.py 存在语法错误"; fi
fi

# ------------------------------------------------------------- 4. 工程一致性
printf '\n[4/6] Xcode 工程与源码一致性\n'
if [ -z "$py" ]; then
  skip "缺少 Python，跳过"
elif [ ! -f TDSCarKit.xcodeproj/project.pbxproj ]; then
  bad "缺少 TDSCarKit.xcodeproj/project.pbxproj"
else
  if "$py" - <<'PY'
import pathlib, sys
root = pathlib.Path('.')
text = (root / 'TDSCarKit.xcodeproj/project.pbxproj').read_text(encoding='utf-8', errors='replace')
patterns = ('App/*.swift', 'App/*.m', 'App/*.c',
            'Sources/TDSCarKitCore/**/*.swift', 'Sources/CTDSCarKitCrypto/*.c')
missing = [str(p.relative_to(root)).replace('\\', '/')
           for pattern in patterns for p in root.glob(pattern)
           if str(p.relative_to(root)).replace('\\', '/') not in text]
if missing:
    print('工程未引用：' + ', '.join(missing[:5]))
    sys.exit(1)
print('磁盘源码全部被工程引用')
PY
  then ok "工程引用完整（新增文件后请在 macOS 上重跑 generate_project.py）"
  else bad "工程文件落后于源码，需在 macOS 上重跑 Tools/generate_project.py"; fi
fi

# ------------------------------------------------------------ 5. 平台工具链
printf '\n[5/6] 构建工具链\n'
have_xcode=0
if [ "$uname_s" = "Darwin" ]; then
  for tool in xcodebuild swift plutil; do
    if command -v "$tool" >/dev/null 2>&1; then ok "$tool 可用"; else bad "缺少 $tool"; fi
  done
  if command -v xcode-select >/dev/null 2>&1; then
    ok "开发者目录：$(xcode-select -p 2>/dev/null || echo '未配置')"
  fi
  have_xcode=1
else
  skip "非 macOS：xcodebuild / swift / plutil 均不可用"
  printf '    本机可做：读改源码、Python/bash 静态校验、文档维护\n'
  printf '    需 macOS：swift test、xcodebuild、generate_project.py\n'
fi

# --------------------------------------------------------------- 6. 本地状态
printf '\n[6/6] 本地状态\n'
for dir in App/BundledIdentity mfi offline-mfi IdentityImport .local; do
  if [ -d "$dir" ]; then
    if git rev-parse --git-dir >/dev/null 2>&1 && [ -n "$(git ls-files -- "$dir" 2>/dev/null)" ]; then
      bad "$dir 存在且已被 git 跟踪，身份/凭据材料不应入库"
    else
      warn "$dir 存在（本地材料，确认未入库）"
    fi
  fi
done
dirty="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
if [ "${dirty:-0}" -eq 0 ]; then ok "工作区干净"; else warn "工作区有 $dirty 项未提交改动"; fi

if [ "$regenerate" -eq 1 ]; then
  printf '\n[重生成] Tools/generate_project.py\n'
  if [ "$have_xcode" -eq 1 ] && [ -n "$py" ]; then
    if "$py" Tools/generate_project.py; then ok "工程已重新生成"; else bad "工程生成失败"; fi
    git status --porcelain -- TDSCarKit.xcodeproj | sed 's/^/    /'
  else
    skip "需要 macOS + python3，已跳过"
  fi
fi

printf '\n———— 结果：'
if [ "$fails" -eq 0 ]; then
  printf '\033[32m可用\033[0m（提示 %d 项）\n' "$warns"
  if [ "$have_xcode" -eq 1 ]; then
    printf '下一步：bash Tools/test.sh 跑单元测试，bash Tools/build_mac.sh 构建 Catalyst 应用\n'
  else
    printf '下一步：源码可直接修改；编译与测试请转到 macOS 或 CI\n'
  fi
  exit 0
else
  printf '\033[31m有 %d 项需要处理\033[0m（提示 %d 项）\n' "$fails" "$warns"
  exit 1
fi
