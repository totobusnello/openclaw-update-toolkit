#!/usr/bin/env python3
"""
Recipe J — Patch session-status emoji label.
🔑 token → 🛡️ OAuth (Max) quando provider=claude-cli.
Idempotente. Aplica em todos status-message-*.js + chattr +i pra resistir upgrades.
https://github.com/totobusnello/openclaw-update-toolkit
"""
import re
import sys
import os
import glob
import subprocess
import time

KEY = "\U0001F511"      # 🔑
SHIELD = "\U0001F6E1️"   # 🛡️ (com VS16)
SEP = " · "

def patch_file(path: str) -> str:
    """Returns: 'patched', 'skipped', or 'failed'."""
    if not os.path.isfile(path):
        return "missing"
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    if "OAuth (Max)" in content:
        return "skipped"
    original = content
    for var in ("selectedAuthLabelValue", "activeAuthLabelValue"):
        pattern = rf"`{re.escape(SEP)}{re.escape(KEY)} \$\{{{var}\}}`"
        replacement = (
            f'`{SEP}${{(typeof {var} === "string" && '
            f'{var}.includes("claude-cli")) ? '
            f'"{SHIELD} OAuth (Max)" : '
            f'"{KEY} " + {var}}}`'
        )
        content = re.sub(pattern, replacement, content)
    if content == original:
        return "failed"
    backup = f"{path}.bak-pre-emoji-patch-{time.strftime('%Y%m%d-%H%M%S')}"
    subprocess.run(["cp", path, backup], check=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return "patched"


def main():
    if os.geteuid() != 0:
        print("ERRO: rode como root", file=sys.stderr)
        sys.exit(1)
    print("## Recipe J — Patch session-status emoji label")
    targets = glob.glob(
        "/root/.openclaw/plugin-runtime-deps/openclaw-*/dist/status-message-*.js"
    )
    targets = [t for t in targets if not t.endswith(".bak") and ".bak-" not in t]
    if not targets:
        print("ERRO: nenhum target encontrado em /root/.openclaw/plugin-runtime-deps/")
        sys.exit(2)
    failures = 0
    patched = 0
    skipped = 0
    for path in targets:
        # Remove imutability if set
        subprocess.run(["chattr", "-i", path],
                       capture_output=True, check=False)
        result = patch_file(path)
        if result == "patched":
            print(f"OK patched: {path}")
            patched += 1
            subprocess.run(["chattr", "+i", path], check=True)
        elif result == "skipped":
            print(f"SKIP (já patched): {path}")
            skipped += 1
            subprocess.run(["chattr", "+i", path],
                           capture_output=True, check=False)
        else:
            print(f"❌ FAIL: {path}")
            failures += 1

    print()
    print(f"Resumo: patched={patched}, skipped={skipped}, failed={failures}")
    if patched > 0:
        print("Restartando gateway pra hot-reload...")
        subprocess.run(["systemctl", "restart", "openclaw-gateway"], check=True)
        time.sleep(12)
        result = subprocess.run(["systemctl", "is-active", "openclaw-gateway"],
                                capture_output=True, text=True)
        if result.stdout.strip() == "active":
            print("✅ Gateway active")
        else:
            print("❌ Gateway não está active após restart")
            sys.exit(3)
    print("✅ Recipe J aplicada")
    print("INVARIANTE: reaplicar após qualquer 'npm install -g openclaw'")
    sys.exit(failures)


if __name__ == "__main__":
    main()
