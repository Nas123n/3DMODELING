#!/usr/bin/env bash
# The layer-0 gate (spec §11): formatting, strict type analysis against the Roblox definitions,
# the require graph (cycles fail), and the Lune suite inside its 180-second wall-time budget.
# Self-contained for a fresh clone: it locates the repository from its own path and needs only
# stylua, rojo, luau-lsp and lune on PATH (/root/.local/bin is added for this machine).
# Usage: bash tools/lune/check.sh
#
# stylua runs over tools/lune rather than tools: tools/globalTypes.d.luau is a type-definition
# file (declare syntax) that stylua cannot parse, and it is only an input to luau-lsp.
set -u
export PATH=/root/.local/bin:$PATH
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
BUDGET=180
status=0

echo "== stylua --check src tools/lune tests"
stylua --check src tools/lune tests || status=1

echo "== rojo sourcemap + luau-lsp analyze (strict, roblox platform, tools/globalTypes.d.luau)"
SOURCEMAP="$(mktemp "${TMPDIR:-/tmp}/humanlike-npc-sourcemap.XXXXXX")"
if rojo sourcemap default.project.json -o "$SOURCEMAP" >/dev/null; then
	luau-lsp analyze --platform=roblox --definitions=tools/globalTypes.d.luau --sourcemap="$SOURCEMAP" src || status=1
else
	echo "rojo sourcemap failed"
	status=1
fi
rm -f "$SOURCEMAP"

echo "== lune run tools/lune/DepGraph"
lune run tools/lune/DepGraph || status=1

echo "== lune run tests/run (budget ${BUDGET} s)"
LOG="$(mktemp "${TMPDIR:-/tmp}/humanlike-npc-suite.XXXXXX")"
started=$(date +%s)
lune run tests/run 2>&1 | tee "$LOG"
suite=${PIPESTATUS[0]}
elapsed=$(( $(date +%s) - started ))
[ "$suite" -eq 0 ] || status=1
# T.report prints "... (wall N s)"; fall back to the shell's own timing when the line is missing.
wall=$(sed -n 's/.*(wall \([0-9.]*\) s).*/\1/p' "$LOG" | tail -n 1)
rm -f "$LOG"
[ -n "$wall" ] || wall=$elapsed
if awk -v w="$wall" -v b="$BUDGET" 'BEGIN { exit !(w > b) }'; then
	echo "suite wall time ${wall} s exceeds the ${BUDGET}-s budget"
	status=1
else
	echo "suite wall time ${wall} s (budget ${BUDGET} s)"
fi

if [ $status -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "CHECKS FAILED"; fi
exit $status
