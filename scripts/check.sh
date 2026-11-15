#!/usr/bin/env bash
# Format, unit tests, strict type check and the design-principle fitness rules. Run it before every commit.
# It runs from the repo root whatever the caller's directory, and stops at the first failing stage.
#
# Tools on PATH: stylua, luau, luau-lsp, rg. The type check needs Tern's definitions: when tern.d.luau is
# missing, `tern plugin types .` writes it (so tern is needed too, the first time on each machine).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

echo "==> tools"
missing=()
for tool in stylua luau luau-lsp rg; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		missing+=("$tool")
	fi
done
if [ "${#missing[@]}" -gt 0 ]; then
	echo "check: missing tool(s) on PATH: ${missing[*]}" >&2
	exit 1
fi

echo "==> files"
absent=()
for path in host.luau window.luau lib test; do
	if [ ! -e "$path" ]; then
		absent+=("$path")
	fi
done
if [ "${#absent[@]}" -gt 0 ]; then
	echo "check: missing in $root: ${absent[*]}" >&2
	exit 1
fi

echo "==> format"
stylua --check host.luau window.luau lib test

echo "==> tests"
shopt -s nullglob
suites=(test/*.luau)
shopt -u nullglob
if [ "${#suites[@]}" -eq 0 ]; then
	echo "check: no test suites in test/" >&2
	exit 1
fi
for suite in "${suites[@]}"; do
	luau "$suite"
done


echo "==> vibe reader script"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/deck"
printf '{"type":"custom","customType":"vibe-session-lifecycle","data":{"action":"turn-started"},"timestamp":"2026-01-01T00:00:00.000Z"}\nnoise\n' >"$tmp/deck/old.jsonl"
printf '{"type":"mode_change","mode":"none"}\n' >"$tmp/deck/new.jsonl"
touch -d "2026-01-01 00:00:00" "$tmp/deck/old.jsonl"
touch -d "2026-01-02 00:00:00" "$tmp/deck/new.jsonl"
script="$(awk '/^local SCRIPT = \[\[/{sub(/^local SCRIPT = \[\[/, ""); if (length($0) > 0) print; f=1; next} f && /\]\]$/{sub(/\]\]$/, ""); print; f=0; next} f' lib/host/vibe.luau)"
size="$(wc -c <"$tmp/deck/new.jsonl")"
line='{"type":"mode_change","mode":"none"}'
got="$(sh -c "$script" sh 0 - "$tmp/deck/old.jsonl" "$tmp/deck/new.jsonl" "$tmp/deck/none.jsonl" 5 "$tmp/deck/old.jsonl" "$tmp/deck/old.jsonl" "$tmp/deck/new.jsonl" 5 "$tmp/deck/new.jsonl" "$tmp/deck/old.jsonl" "$tmp/deck/new.jsonl")"
want="$(printf '\036%s\036%s\n%s\n\036%s\036%s\n%s\n\036%s\036%s\n' "$tmp/deck/new.jsonl" "$size" "$line" "$tmp/deck/new.jsonl" "$size" "$line" "$tmp/deck/new.jsonl" "$size")"
if [ "$got" != "$want" ]; then
	echo "check: the vibe reader script did not answer as expected:" >&2
	printf 'want: %q\ngot:  %q\n' "$want" "$got" >&2
	exit 1
fi
echo "==> types"
if [ ! -f tern.d.luau ]; then
	if ! command -v tern >/dev/null 2>&1; then
		echo "check: tern.d.luau is missing and tern is not on PATH to write it (run \`tern plugin types .\`)" >&2
		exit 1
	fi
	tern plugin types .
fi
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau host.luau window.luau lib test

echo "==> fitness"
scripts/fitness.sh

echo "check: all stages passed"
