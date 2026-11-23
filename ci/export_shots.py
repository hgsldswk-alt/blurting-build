"""Recover named PNGs from xcresult attachments on cloud simulators."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys


SHOTS = ("01-home", "02-editor", "03-recall", "04-compare", "05-trend", "09-paper", "10-review-due")
LANGUAGES = ("en", "zh-Hans", "zh-Hant")
EXPECTED = {f"store-{language}-{shot}" for language in LANGUAGES for shot in SHOTS}
EXPECTED.add("paid-01-paywall")
ATTACHMENT_NAME = re.compile(r"^([a-zA-Z0-9-]+)(?=[_.]|$)")


def normalize_attachments(folder):
    manifest_path = folder / "manifest.json"
    if manifest_path.is_file():
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        for test in manifest:
            for attachment in test.get("attachments", []):
                match = ATTACHMENT_NAME.match(attachment.get("suggestedHumanReadableName", ""))
                if not match or match[1] not in EXPECTED:
                    continue
                source = folder / attachment["exportedFileName"]
                if source.suffix.lower() != ".png" or not source.resolve().is_relative_to(folder.resolve()):
                    continue
                target = folder / f"{match[1]}.png"
                if source.is_file() and source.resolve() != target.resolve():
                    shutil.copy2(source, target)
    return {name for name in EXPECTED if (folder / f"{name}.png").is_file()}


def main():
    result, output = sys.argv[1:3]
    folder = Path(output)
    folder.mkdir(parents=True, exist_ok=True)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", result,
                    "--output-path", str(folder)], check=True)
    found = normalize_attachments(folder)
    missing = sorted(EXPECTED - found)
    if missing:
        sys.exit(f"缺少截图：{', '.join(missing)}")
    print(f"已核对 {len(found)} 张命名截图")


if __name__ == "__main__":
    main()
