#!/usr/bin/env python3
"""交互式保存 Whaleness R2 发布凭据；不输出密钥。"""

import getpass
import json
import os
from pathlib import Path
import tempfile


def main():
    destination = Path.home() / ".config" / "whaleness" / "r2-release.json"
    if destination.exists():
        answer = input("已有 R2 配置，是否替换？输入 yes 确认：").strip()
        if answer != "yes":
            print("保留现有配置。")
            return
    access_key = getpass.getpass("Access Key ID（输入不显示）：").strip()
    secret_key = getpass.getpass("Secret Access Key（输入不显示）：").strip()
    if not access_key or not secret_key:
        raise SystemExit("凭据不能为空，未保存配置。")
    configuration = {
        "endpoint": "https://878f37e94a0b2f19271aed151dff95b2.r2.cloudflarestorage.com",
        "bucket": "whaleness-apks",
        "publicBaseUrl": "https://download.whaleness.cc",
        "accessKeyId": access_key,
        "secretAccessKey": secret_key,
    }
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(destination.parent, 0o700)
    descriptor, temporary = tempfile.mkstemp(dir=destination.parent, prefix=".r2-release-")
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(configuration, output, ensure_ascii=False, indent=2)
            output.write("\n")
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"配置已保存：{destination}")
    print("文件权限为 600，仅当前用户可读写。")


if __name__ == "__main__":
    main()
