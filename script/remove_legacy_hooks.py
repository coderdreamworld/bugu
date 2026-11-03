#!/usr/bin/env python3
"""Remove only Bugu's old JSON hooks after the passive build is installed."""

import argparse
import json
import os
import shutil
import tempfile
from pathlib import Path

CONFIGS = (
    ".codex/hooks.json",
    ".claude/settings.json",
    ".gemini/settings.json",
    ".trae/hooks.json",
    ".workbuddy/settings.json",
)


def remove_bugu(root):
    hooks = root.get("hooks")
    if not isinstance(hooks, dict):
        return root, 0
    removed = 0
    kept_events = {}
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            kept_events[event] = groups
            continue
        kept_groups = []
        for group in groups:
            if not isinstance(group, dict):
                kept_groups.append(group)
                continue
            if isinstance(group.get("hooks"), list):
                inner = []
                for entry in group["hooks"]:
                    if isinstance(entry, dict) and "bugu-bridge" in str(entry.get("command", "")):
                        removed += 1
                    else:
                        inner.append(entry)
                if inner:
                    kept_groups.append({**group, "hooks": inner})
            elif "bugu-bridge" in str(group.get("command", "")):
                removed += 1
            else:
                kept_groups.append(group)
        if kept_groups:
            kept_events[event] = kept_groups
    updated = dict(root)
    if kept_events:
        updated["hooks"] = kept_events
    else:
        updated.pop("hooks", None)
    return updated, removed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    for relative in CONFIGS:
        path = args.home / relative
        if not path.is_file():
            continue
        original = path.read_bytes()
        if b"bugu-bridge" not in original:
            continue
        root = json.loads(original)
        updated, count = remove_bugu(root)
        if not count:
            continue
        print(f"{relative}: {count} Bugu hooks" + (" removed" if args.apply else " found"))
        if not args.apply:
            continue
        backup = path.with_name(path.name + ".before-bugu-passive")
        if not backup.exists():
            shutil.copy2(path, backup)
        if path.read_bytes() != original:
            raise RuntimeError(f"{path} changed during cleanup")
        if not updated:
            path.unlink()
            continue
        encoded = (json.dumps(updated, ensure_ascii=False, indent=2) + "\n").encode()
        fd, temp_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
        try:
            os.fchmod(fd, path.stat().st_mode & 0o777)
            with os.fdopen(fd, "wb") as file:
                file.write(encoded)
            os.replace(temp_name, path)
        finally:
            if os.path.exists(temp_name):
                os.unlink(temp_name)


if __name__ == "__main__":
    main()
