#!/usr/bin/env bash
# install.sh — install the .agents tooling into ~/.agents and ~/.claude/skills.
#
# Idempotent: safe to re-run. This is the ONLY supported way to get from the
# versioned source (this directory) to the live copy — hand-copying a subset is
# how a runner and its policy drift apart.
#
#   ./.agents/install.sh            install / update
#   ./.agents/install.sh --check    report drift, change nothing
#
# `--check` exists because the live copy is what actually runs: if someone edits
# ~/.agents directly, the repo stops describing reality and the next install
# silently discards their change.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${VELO_AGENTS_HOME:-$HOME/.agents}"
SKILLS="${VELO_CLAUDE_SKILLS:-$HOME/.claude/skills}"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

ok()   { printf '\033[32m  ok\033[0m %s\n' "$1"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

[[ -d "$SRC/bin" ]] || die "run this from a checkout: $SRC/bin not found"

# ── drift check ───────────────────────────────────────────────────────────────
# Compare BOTH ways round. A file newer in the live copy is unpushed work; a
# file newer here is a pending install. Both matter, and only one is fixed by
# re-running install.
drift=0
for d in bin rules skills; do
  [[ -d "$SRC/$d" ]] || continue
  while IFS= read -r -d '' f; do
    rel="${f#"$SRC"/}"
    if [[ ! -e "$DEST/$rel" ]]; then
      warn "not installed: $rel"; drift=1
    elif ! cmp -s "$f" "$DEST/$rel"; then
      if [[ "$DEST/$rel" -nt "$f" ]]; then
        warn "LIVE COPY IS NEWER: $rel — copy it back into the repo before installing, or the edit is lost"
      else
        warn "differs (repo is newer): $rel"
      fi
      drift=1
    fi
  done < <(find "$SRC/$d" -type f -print0)
done

if [[ $CHECK -eq 1 ]]; then
  [[ $drift -eq 0 ]] && ok "live copy matches this checkout" || die "drift detected (see above)"
  exit 0
fi

# ── install ───────────────────────────────────────────────────────────────────
mkdir -p "$DEST" "$SKILLS"
for d in bin rules skills tasks; do
  [[ -d "$SRC/$d" ]] || continue
  mkdir -p "$DEST/$d"
  cp -R "$SRC/$d/." "$DEST/$d/"
  ok "$d -> $DEST/$d"
done

# Every script, not a hand-listed subset — a missed chmod fails at dispatch time.
chmod +x "$DEST"/bin/* 2>/dev/null || true
ok "chmod +x on $(find "$DEST/bin" -type f | wc -l | tr -d ' ') scripts"

# Expose the orchestrator-facing skills to Claude Code. Review skills
# (check-code, check-spec) are NOT linked here — workers get them inlined via
# `--skill`, and the orchestrator already resolves them from ~/.claude/commands.
for s in velo-deepseek velo-glm velo-local; do
  [[ -f "$DEST/skills/$s/SKILL.md" ]] || continue
  mkdir -p "$SKILLS/$s"
  ln -sf "$DEST/skills/$s/SKILL.md" "$SKILLS/$s/SKILL.md"
  ok "skill linked: $s"
done

case ":$PATH:" in
  *":$DEST/bin:"*) ok "PATH already includes $DEST/bin" ;;
  *) warn "add to your shell rc:  export PATH=\"$DEST/bin:\$PATH\"" ;;
esac

echo
ok "installed. Verify with:  velo-dispatch <issue> <brief> --dry-run"
