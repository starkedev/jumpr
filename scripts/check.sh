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
