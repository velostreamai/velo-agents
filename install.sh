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

# The files this checkout ships from directory $1, NUL separated: python artifacts (__pycache__, *.pyc) are not tooling,
# see the drift check below (#2091). Every walk of $SRC goes through this one function, so none can forget the
# exclusion (the hook exec check below once did).
tooling_files() { find "$1" -type d -name __pycache__ -prune -o -type f ! -name '*.pyc' -print0; }

# ── drift check ───────────────────────────────────────────────────────────────
# Compare BOTH ways round. A file newer in the live copy is unpushed work; a
# file newer here is a pending install. Both matter, and only one is fixed by
# re-running install.
drift=0
for d in bin rules skills hooks launchd requirements; do
  [[ -d "$SRC/$d" ]] || continue
  # __pycache__/*.pyc are python runtime artifacts, not tooling: python drops
  # them next to any module it imports, including .agents/bin. A .pyc embeds the
  # source mtime, so comparing them reported drift no install could ever fix
  # (#2091). Excluded from both this walk and the copy below.
  while IFS= read -r -d '' f; do
    rel="${f#"$SRC"/}"
    if [[ ! -e "$DEST/$rel" ]]; then
      warn "not installed: $rel"; drift=1
    elif ! cmp -s "$f" "$DEST/$rel"; then
      # mtime is NOT evidence of provenance, and trusting it inverted this
      # warning exactly when it mattered. Editing the REPO copy makes it newer
      # than a live copy holding work the repo has never seen, so the alarming
      # "LIVE COPY IS NEWER" silently became the reassuring "repo is newer".
      # That fired on velo-dispatch, whose live copy carried 133 lines the repo
      # lacked — a whole worker route plus two validation gates — and installing
      # would have deleted all of it without a word.
      #
      # Count the lines each way instead. Content cannot lie about which side
      # holds something the other does not.
      live_only=$(diff "$f" "$DEST/$rel" | grep -c '^>' || true)
      repo_only=$(diff "$f" "$DEST/$rel" | grep -c '^<' || true)
      if [[ "$live_only" -gt 0 ]]; then
        # This cannot distinguish "work the repo never received" from "lines you
        # deliberately replaced" — only a human reading the diff can. It reports
        # the fact and insists you look, which is the whole job: the old check
        # answered confidently and was wrong.
        warn "LIVE COPY HAS $live_only LINE(S) THE REPO LACKS: $rel"
        warn "      READ THE DIFF before installing — these are either unmerged"
        warn "      work or lines you meant to replace, and install cannot tell:"
        warn "      diff $f $DEST/$rel"
      else
        warn "differs, repo ahead by $repo_only line(s), live has nothing unique: $rel"
      fi
      drift=1
    fi
    # Python artifacts excluded — see the note on the copy below.
  done < <(tooling_files "$SRC/$d")
done

# Hooks are registered as `[ -x HOOK ] || exit 0; exec HOOK` (fail open when missing), so an installed hook that is
# not executable is skipped without a word and the guard it implements is off. Content equality does not see that.
if [[ -d "$SRC/hooks" ]]; then
  while IFS= read -r -d '' f; do
    rel="${f#"$SRC"/}"
    if [[ -e "$DEST/$rel" && ! -x "$DEST/$rel" ]]; then
      warn "installed but NOT executable, so its registration guard skips it silently: $rel"; drift=1
    fi
  done < <(tooling_files "$SRC/hooks")
fi

if [[ $CHECK -eq 1 ]]; then
  [[ $drift -eq 0 ]] && ok "live copy matches this checkout" || die "drift detected (see above)"
  exit 0
fi

# ── install ───────────────────────────────────────────────────────────────────
mkdir -p "$DEST" "$SKILLS"
for d in bin rules skills hooks launchd requirements; do
  [[ -d "$SRC/$d" ]] || continue
  mkdir -p "$DEST/$d"
  # Same exclusion as the drift check above: python artifacts are never shipped.
  while IFS= read -r -d '' f; do
    rel="${f#"$SRC"/}"
    mkdir -p "$DEST/$(dirname "$rel")"
    cp -p "$f" "$DEST/$rel"
  done < <(tooling_files "$SRC/$d")
  # An install over a pre-#2091 live copy still carries the .pyc it shipped —
  # remove those. Python recreates them at runtime; they are not drift.
  while IFS= read -r -d '' p; do rm -rf "$p"; done \
    < <(find "$DEST/$d" -depth -type d -name __pycache__ -print0)
  ok "$d -> $DEST/$d"
done

# chmod +x on exactly the files this checkout ships from $SRC/$1, never on a file only the live copy has: the exec bit is
# what switches a registered hook on (see the drift check above), so a hook someone switched off by removing it, or a
# file that is not a hook, stays as it is.
chmod_shipped() {  # <dir> <what>
  local f n=0
  while IFS= read -r -d '' f; do
    chmod +x "$DEST/${f#"$SRC"/}"
    n=$((n + 1))
  done < <(tooling_files "$SRC/$1")
  ok "chmod +x on $n $2"
}

# Every script, not a hand-listed subset — a missed chmod fails at dispatch time.
chmod_shipped bin scripts
# Every hook too.
if [[ -d "$SRC/hooks" ]]; then
  chmod_shipped hooks "hook scripts"
fi

# Expose the orchestrator-facing skills to Claude Code. Review skills
# (check-code, check-spec) are NOT linked here — workers get them inlined via
# `--skill`, and the orchestrator already resolves them from ~/.claude/commands.
for s in velo-deepseek velo-haiku velo-glm velo-local; do
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
