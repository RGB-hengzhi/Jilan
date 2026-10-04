#!/usr/bin/env python3
"""Package the signed local application with its corresponding GPL sources."""
from pathlib import Path
import hashlib
import json
import plistlib
import os
import stat
import zipfile

project = Path(__file__).resolve().parent.parent
delivery = project / "交付"
app = delivery / "疾览.app"
if not app.is_dir():
    raise SystemExit("请先运行 scripts/build.sh 构建应用。")

app_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
version = app_info["CFBundleShortVersionString"]
prefix = "疾览_" + version

paths = [project / name for name in ("README.md", "LICENSE")]
for directory in ("Sources", "Tests", "scripts", "docs", "vendor", "验证记录"):
    paths.extend(p for p in (project / directory).rglob("*") if p.is_file())
paths.extend(p for p in app.rglob("*") if p.is_file())
paths = sorted(p for p in paths if not p.name.startswith("._") and p.name != ".DS_Store"
               and "__pycache__" not in p.parts)
manifest = {
    "application": app_info["CFBundleDisplayName"], "version": version, "build": app_info["CFBundleVersion"], "architecture": "arm64",
    "files": {str(p.relative_to(project)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in paths},
}
manifest_path = delivery / "交付清单.json"
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
paths.append(manifest_path)
archive = delivery / (prefix + "_完整交付.zip")
temporary = archive.with_suffix(".zip.tmp")
with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as bundle:
    for path in paths:
        info = zipfile.ZipInfo.from_file(path, prefix + "/" + str(path.relative_to(project)))
        info.create_system = 3
        info.external_attr = (stat.S_IFREG | stat.S_IMODE(path.stat().st_mode)) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        bundle.writestr(info, path.read_bytes())
with zipfile.ZipFile(temporary) as bundle:
    if corrupt := bundle.testzip():
        raise SystemExit("ZIP 校验失败：" + corrupt)
    for path, digest in manifest["files"].items():
        data = bundle.read(prefix + "/" + path)
        if hashlib.sha256(data).hexdigest() != digest:
            raise SystemExit("文件哈希校验失败：" + path)
os.replace(temporary, archive)
print(f"完整交付包：{archive}，{len(paths)} 个文件，{archive.stat().st_size:,} 字节")
