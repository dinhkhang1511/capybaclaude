#!/usr/bin/env bash
# Dino one-line installer — no git clone needed:
#   curl -fsSL https://raw.githubusercontent.com/dinhkhang1511/capybaclaude/main/install.sh | bash
# Options (pass after `bash -s --`):
#   --branch <name>   install from a branch (default: main)
#   --hooks           also merge claude-hooks.json into ~/.claude/settings.json
#   --prebuilt        skip compiling: download dist/Dino.app.zip (universal,
#                     macOS 13+). Auto-selected when swiftc is unavailable.
set -euo pipefail

REPO="dinhkhang1511/capybaclaude"
BRANCH="main"
MERGE_HOOKS=0
PREBUILT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --branch)   BRANCH="$2"; shift 2 ;;
    --hooks)    MERGE_HOOKS=1; shift ;;
    --prebuilt) PREBUILT=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ "$PREBUILT" = 0 ] && ! command -v swiftc >/dev/null 2>&1; then
  echo "▸ Không có swiftc — chuyển sang bản prebuilt."
  PREBUILT=1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ "$PREBUILT" = 1 ]; then
  echo "▸ Downloading prebuilt Dino.app (${BRANCH})..."
  curl -fsSL "https://raw.githubusercontent.com/$REPO/$BRANCH/dist/Dino.app.zip" -o "$TMP/Dino.app.zip"
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Dino.app"
  ditto -x -k "$TMP/Dino.app.zip" "$HOME/Applications"
  xattr -dr com.apple.quarantine "$HOME/Applications/Dino.app" 2>/dev/null || true
  pkill -x Dino 2>/dev/null || true
  sleep 0.3
  open "$HOME/Applications/Dino.app"
  echo "✓ Installed $HOME/Applications/Dino.app"
  SRC="$TMP"
  curl -fsSL "https://raw.githubusercontent.com/$REPO/$BRANCH/claude-hooks.json" -o "$SRC/claude-hooks.json"
else
  echo "▸ Downloading ${REPO}@${BRANCH}..."
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" | tar -xz -C "$TMP"
  SRC="$TMP/$(basename "$REPO")-$BRANCH"
  cd "$SRC"
  chmod +x build.sh
  ./build.sh
fi

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
