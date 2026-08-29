#!/usr/bin/env bash
# update.sh — pull live edits from ~/.agents back INTO this checkout.
#
# The reverse of install.sh. `~/.agents` is what actually runs, so a fix made
# there during a live debugging session is real work — and `install.sh` would
# overwrite it. This copies it back so it can be committed.
#
#   ./.agents/update.sh            copy live -> repo, then show the diff
#   ./.agents/update.sh --dry-run  show what WOULD be copied
#
# Workflow: edit in the repo and `install.sh`. If you edited live instead, run
# this FIRST, review the diff, and commit.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE="${VELO_AGENTS_HOME:-$HOME/.agents}"
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

ok()   { printf '\033[32m  ok\033[0m %s\n' "$1"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

[[ -d "$LIVE/bin" ]] || die "no live install at $LIVE — run ./.agents/install.sh first"

changed=0
for d in bin rules skills; do
  [[ -d "$LIVE/$d" ]] || continue
  while IFS= read -r -d '' f; do
    rel="${f#"$LIVE"/}"
    dst="$SRC/$rel"
    # Only files the repo already tracks, plus genuinely new ones. This
    # deliberately does NOT sync tasks/ — per-issue specs are written in the
    # repo, and copying them back would resurrect ones deleted on purpose.
    if [[ ! -e "$dst" ]]; then
      warn "NEW in live copy: $rel"
      changed=1
      [[ $DRY -eq 1 ]] || { mkdir -p "$(dirname "$dst")"; cp "$f" "$dst"; }
    elif ! cmp -s "$f" "$dst"; then
      ok "updated: $rel"
      changed=1
      [[ $DRY -eq 1 ]] || cp "$f" "$dst"
    fi
  done < <(find "$LIVE/$d" -type f -print0)
done

if [[ $changed -eq 0 ]]; then
  ok "repo already matches the live copy — nothing to update"
  exit 0
fi

if [[ $DRY -eq 1 ]]; then
  echo; warn "--dry-run: nothing written"
  exit 0
fi

echo
git -C "$SRC/.." --no-pager diff --stat -- .agents/ || true
echo
ok "copied. REVIEW the diff above, then commit — and add a CHANGELOG.md entry."
