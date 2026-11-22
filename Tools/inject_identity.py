#!/usr/bin/env python3
"""把 MFi 身份三件套注入未签名 IPA。

用法：
    python3 Tools/inject_identity.py 未签名.ipa 带身份的.ipa 输出.ipa

三个文件从源包里按 `Payload/*.app/` 下的
`certificate.p7b`、`leaf.cer`、`private.x963` 取出，原样写进目标包的
`Payload/*.app/`。只改 zip 内容，不动签名结构（产物仍是未签名包，安装后
需要自签或用 TrollStore 之类的方式装入）。
"""

from __future__ import annotations

import sys
import zipfile
from pathlib import Path

NAMES = ("certificate.p7b", "leaf.cer", "private.x963")


def find_app_dir(names: list[str]) -> str:
    for name in names:
        parts = name.split("/")
        if len(parts) >= 3 and parts[0] == "Payload" and parts[1].endswith(".app"):
            return "/".join(parts[:2])
    raise SystemExit("IPA 里找不到 Payload/*.app")


def read_identity(ipa: Path) -> dict[str, bytes]:
    found: dict[str, bytes] = {}
    with zipfile.ZipFile(ipa) as archive:
        app_dir = find_app_dir(archive.namelist())
        for name in NAMES:
            entry = f"{app_dir}/{name}"
            try:
                found[name] = archive.read(entry)
            except KeyError:
                raise SystemExit(f"{ipa} 里缺少 {entry}") from None
    return found


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__.strip())
        return 2
    target, source, output = (Path(item) for item in argv[1:])
    identity = read_identity(source)
    with zipfile.ZipFile(target) as src, zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as dst:
        app_dir = find_app_dir(src.namelist())
        for item in src.infolist():
            payload = src.read(item.filename)
            dst.writestr(item, payload)
        for name, payload in identity.items():
            dst.writestr(f"{app_dir}/{name}", payload)
    print(f"已生成 {output}（{output.stat().st_size} 字节）")
    for name, payload in identity.items():
        print(f"  {name}: {len(payload)} 字节")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
