#!/usr/bin/env bash
# Dino one-line installer — no git clone needed:
#   curl -fsSL https://raw.githubusercontent.com/dinhkhang1511/capybaclaude/main/install.sh | bash
# Options (pass after `bash -s --`):
#   --branch <name>   install from a branch (default: main)
#   --hooks           also merge claude-hooks.json into ~/.claude/settings.json
set -euo pipefail

REPO="dinhkhang1511/capybaclaude"
BRANCH="main"
MERGE_HOOKS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="$2"; shift 2 ;;
    --hooks)  MERGE_HOOKS=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if ! command -v swiftc >/dev/null 2>&1; then
  echo "✗ Cần Xcode Command Line Tools (swiftc). Chạy: xcode-select --install" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▸ Downloading ${REPO}@${BRANCH}..."
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" | tar -xz -C "$TMP"
SRC="$TMP/$(basename "$REPO")-$BRANCH"

cd "$SRC"
chmod +x build.sh
./build.sh

if [ "$MERGE_HOOKS" = 1 ]; then
  echo "▸ Merging Claude Code hooks…"
  python3 - "$SRC/claude-hooks.json" <<'EOF'
import json, pathlib, sys
src = json.loads(pathlib.Path(sys.argv[1]).read_text())["hooks"]
p = pathlib.Path.home()/".claude/settings.json"
s = json.loads(p.read_text()) if p.exists() else {}
hooks = s.setdefault("hooks", {})
added = 0
for ev, groups in src.items():
    cur = hooks.setdefault(ev, [])
    for g in groups:
        if g not in cur:
            cur.append(g)
            added += 1
p.parent.mkdir(exist_ok=True)
p.write_text(json.dumps(s, indent=2))
print(f"  ok -> {p} ({added} hook group(s) added)")
EOF
  echo "  Mở session Claude Code mới, gõ /hooks để kiểm tra."
else
  echo
  echo "Tip: tự nối vào Claude Code luôn thì chạy với --hooks:"
  echo "  curl -fsSL https://raw.githubusercontent.com/$REPO/$BRANCH/install.sh | bash -s -- --hooks"
fi
