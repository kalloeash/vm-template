#!/usr/bin/env bash
# Enforces docs/STYLE.md: no AI attribution, no hard-banned AI-tell vocabulary.
# Usage:
#   scripts/lint-language.sh FILE...          lint file contents
#   scripts/lint-language.sh --commit-msg F   lint a commit message file
# Exits 1 with per-hit lines on any violation. STYLE.md and this script are
# excluded (they must name the banned terms).
set -euo pipefail

ATTRIBUTION='Co-Authored-By:.*(Claude|GPT|Copilot|Gemini|AI)|Generated with|As an AI|AI-generated|written (by|with) (ChatGPT|Claude|Copilot)'
BANNED='\bdelve\b|\btapestry\b|in today.s|it.s worth noting|it.s important to note|\bin conclusion\b|\bfurthermore\b|\bmoreover\b|game.changer|\bseamless(ly)?\b|\bembark\b|let.s dive|dive into|let.s explore|\belevate\b|\bsupercharge\b|unlock the'

mode=files
if [[ "${1:-}" == --commit-msg ]]; then
  mode=msg
  shift
fi

fail=0
for f in "$@"; do
  case "$f" in
    docs/STYLE.md | scripts/lint-language.sh) continue ;;
  esac
  [[ -f $f ]] || continue
  if hits=$(grep -inE "$ATTRIBUTION|$BANNED" "$f"); then
    printf '%s: STYLE.md violation(s):\n%s\n' "$f" "$hits" >&2
    fail=1
  fi
done

if [[ $mode == msg && $fail -ne 0 ]]; then
  printf 'Commit message violates docs/STYLE.md (no AI attribution / AI-tell words).\n' >&2
fi
exit $fail
