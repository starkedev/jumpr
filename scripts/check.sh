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

echo "==> codex reader scripts"
# Each script is lifted verbatim from lib/host/sessions.luau (`local NAME = [[ ... ]]`) and run under sh on a fixture
# sessions tree: a rollout's line 1 is its session_meta head, its line 2 conversation text that must never be read.
codex_script() {
	awk -v start="local $1 = [[" 'index($0, start) == 1 {$0 = substr($0, length(start) + 1); f = 1; if ($0 == "") next} f && /\]\]$/ {sub(/\]\]$/, ""); print; exit} f' lib/host/sessions.luau
}
codex_fail() {
	echo "check: the codex $1 did not answer as expected:" >&2
	printf 'want: %q\ngot:  %q\n' "$2" "$3" >&2
	exit 1
}
codex_uuid() {
	printf '019a9a3c-5e10-7%03x-9a2b-3c4d5e6f7a81' "$1"
}
codex_meta() {
	printf '{"timestamp":"2026-11-18T10:00:00.000Z","type":"session_meta","payload":{"id":"%s","timestamp":"2026-11-18T10:00:00.000Z","cwd":"/work","base_instructions":{"text":"%s"}}}' "$1" "$2"
}
codex_rollout() {
	printf '%s\n{"timestamp":"2026-11-18T10:00:01.000Z","type":"response_item","payload":{"text":"%s"}}\n' "$(codex_meta "$2" "$3")" "$canary" >"$1"
}
read_script="$(codex_script READ_SCRIPT)"
find_script="$(codex_script FIND_SCRIPT)"
if [ -z "$read_script" ] || [ -z "$find_script" ]; then
	echo "check: cannot lift READ_SCRIPT and FIND_SCRIPT out of lib/host/sessions.luau" >&2
	exit 1
fi
canary='CANARY-line-2-must-never-be-read'
pad="$(printf '%3000s' '' | tr ' ' x)"
sessions="$tmp/.codex/sessions"
day="$sessions/2026/11/18"
mkdir -p "$day" "$sessions/2026/11/16"
short="$day/rollout-2026-11-18T10-00-00-$(codex_uuid 1).jsonl"
long="$day/rollout-2026-11-18T10-00-01-$(codex_uuid 2).jsonl"
old="$sessions/2026/11/16/rollout-2026-11-16T10-00-00-$(codex_uuid 3).jsonl"
gone="$tmp/.codex/nowhere/2026/11/18/rollout-2026-11-18T10-00-00-$(codex_uuid 4).jsonl"
codex_rollout "$short" "$(codex_uuid 1)" short
codex_rollout "$long" "$(codex_uuid 2)" "$pad"
codex_rollout "$old" "$(codex_uuid 3)" short
codex_rollout "$day/notes.jsonl" "$(codex_uuid 5)" short
short_head="$(codex_meta "$(codex_uuid 1)" short)"
long_head="$(codex_meta "$(codex_uuid 2)" "$pad")"
long_head="${long_head:0:2048}"
# Only the modification time moves (`-m`), so a script that printed the access time instead would be caught.
recent=$(($(date +%s) - 120))
touch -m -d "@$recent" "$short" "$long" "$day/notes.jsonl"
touch -m -d "@$((recent - 2 * 86400))" "$old"

# The head reader: line 1 only, at most 2048 bytes of it, a mark line alone for a file it cannot read, exit 0.
if ! sh -c "$read_script" sh 2048 "$short" "$long" "$gone" >"$tmp/codex-read.out"; then
	echo "check: the codex head reader exited non-zero" >&2
	exit 1
fi
printf '\036- %s\n%s\n\036- %s\n%s\036- %s\n' "$short" "$short_head" "$long" "$long_head" "$gone" >"$tmp/codex-read.want"
if [[ "$(cat "$tmp/codex-read.out")" == *"$canary"* ]]; then
	echo "check: the codex head reader read past line 1 of a rollout" >&2
	exit 1
fi
if ! cmp -s "$tmp/codex-read.want" "$tmp/codex-read.out"; then
	codex_fail "head reader" "$(cat "$tmp/codex-read.want")" "$(cat "$tmp/codex-read.out")"
fi

# The picker search: rollouts modified in the window only, each with its mtime and its capped head, exit 0.
codex_records() {
	awk -v RS='\036' 'NR > 1 {nl = index($0, "\n"); hdr = substr($0, 1, nl - 1); body = substr($0, nl + 1); sub(/\n$/, "", body); print hdr "\t" body}' "$1" | sort
}
if ! sh -c "$find_script" sh "$sessions" 10 31 2048 >"$tmp/codex-find.out"; then
	echo "check: the codex picker search exited non-zero" >&2
	exit 1
fi
if [[ "$(cat "$tmp/codex-find.out")" == *"$canary"* ]]; then
	echo "check: the codex picker search read past line 1 of a rollout" >&2
	exit 1
fi
want="$(printf '%s %s\t%s\n%s %s\t%s\n' "$recent" "$short" "$short_head" "$recent" "$long" "$long_head" | sort)"
got="$(codex_records "$tmp/codex-find.out")"
if [ "$got" != "$want" ]; then
	codex_fail "picker search" "$want" "$got"
fi
if ! got="$(sh -c "$find_script" sh "$tmp/.codex/nowhere" 10 31 2048)" || [ -n "$got" ]; then
	codex_fail "picker search (missing folder)" "" "$got"
fi

# The picker search stops at its cap ($3): 31 of 33 recent rollouts.
mkdir -p "$tmp/cap"
for i in $(seq 1 33); do
	codex_rollout "$tmp/cap/rollout-2026-11-18T10-00-00-$(codex_uuid "$((i + 16))").jsonl" "$(codex_uuid "$((i + 16))")" short
done
touch -d "@$recent" "$tmp/cap"/rollout-*.jsonl
got="$(sh -c "$find_script" sh "$tmp/cap" 10 31 2048 | tr -cd '\036' | wc -c | tr -d ' ')"
if [ "$got" != 31 ]; then
	codex_fail "picker search (cap)" 31 "$got"
fi

echo "==> claude launch check"
# The real launch line comes from lib/shared/agent.luau; its quoted script runs unmodified under sh, with a fake
# `claude` first on PATH that prints its id and arguments, against a fixture home and config folder.
claude_fail() {
	echo "check: the claude launch line chose wrong $1:" >&2
	printf 'want: %q\ngot:  %q\n' "$2" "$3" >&2
	exit 1
}
claude_sid="0f8e2a6c-4b1d-4c3e-9a7f-1234567890ab"
mkdir -p "$tmp/claude/bin" "$tmp/claude/lib"
cp -R lib/. "$tmp/claude/lib"
printf 'print(require("./lib/shared/agent").command("claude", "x1", "new", "%s"))\n' "$claude_sid" >"$tmp/claude/line.luau"
claude_line="$(luau "$tmp/claude/line.luau")"
claude_prefix="env JUMPR_ID=x1 sh -c '"
if [ "${claude_line:0:${#claude_prefix}}" != "$claude_prefix" ] || [ "${claude_line: -1}" != "'" ]; then
	claude_fail "(no quoted sh script in the line)" "$claude_prefix...'" "$claude_line"
fi
claude_script="${claude_line:${#claude_prefix}}"
claude_script="${claude_script%\'}"
printf '#!/bin/sh\nprintf "%%s|%%s\\n" "${JUMPR_ID:-}" "$*"\n' >"$tmp/claude/bin/claude"
chmod +x "$tmp/claude/bin/claude"
claude_home="$tmp/claude/home"
claude_alt="$tmp/claude/alt"
mkdir -p "$claude_home/.claude/projects/-x" "$claude_alt/projects/-y"
claude_resume="|--resume $claude_sid"
claude_create="|--session-id $claude_sid"
claude_run() {
	env -u CLAUDE_CONFIG_DIR HOME="$claude_home" PATH="$tmp/claude/bin:$PATH" "$@"
}
claude_expect() {
	local what="$1" want="$2" got
	shift 2
	got="$(claude_run "$@")" || got="exit $? after: $got"
	if [ "$got" != "$want" ]; then
		claude_fail "$what" "$want" "$got"
	fi
}

touch "$claude_home/.claude/projects/-x/$claude_sid.jsonl"
claude_expect "with the transcript under ~/.claude" "$claude_resume" sh -c "$claude_script"
claude_expect "with CLAUDE_CONFIG_DIR set and the transcript only under ~/.claude" "$claude_create" \
	CLAUDE_CONFIG_DIR="$claude_alt" sh -c "$claude_script"
rm "$claude_home/.claude/projects/-x/$claude_sid.jsonl"
claude_expect "with no transcript" "$claude_create" sh -c "$claude_script"
touch "$claude_alt/projects/-y/$claude_sid.jsonl"
claude_expect "with the transcript under CLAUDE_CONFIG_DIR" "$claude_resume" \
	CLAUDE_CONFIG_DIR="$claude_alt" sh -c "$claude_script"
claude_expect "with the transcript only under CLAUDE_CONFIG_DIR, which is unset" "$claude_create" sh -c "$claude_script"

# The pane shell is fish: the whole line must reach sh with its expansion intact.
if command -v fish >/dev/null 2>&1; then
	claude_expect "through fish with the transcript under CLAUDE_CONFIG_DIR" "x1$claude_resume" \
		CLAUDE_CONFIG_DIR="$claude_alt" fish --no-config -c "$claude_line"
	claude_expect "through fish with CLAUDE_CONFIG_DIR unset" "x1$claude_create" fish --no-config -c "$claude_line"
else
	echo "note: fish is not on PATH, so the line was not run through fish"
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
