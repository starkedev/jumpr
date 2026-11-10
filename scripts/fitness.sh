#!/usr/bin/env bash
# Fitness rules for Jumpr's design principles, plus hygiene rules that catch what review once had to;
# scripts/check.sh runs this last. The principles:
#   P1  The host half owns the machine's list: the window half never writes tern.kv.
#   P2  Agents are joined by deck id, never by a pane id the other half supplied.
#   P3  One seam to Tern: only lib/compat.luau reaches cx and the tern APIs with side effects.
#   P4  A pure core: pure modules never use tern, and JSON is encoded only at the edges.
#   P5  Every message between the halves carries the protocol version `p`.
# Each failure prints the principle it guards and file:line; the script exits non-zero if any rule fails.
#
# Scope: the plugin's code is host.luau, window.luau and lib/ (tests are not plugin code, so only the
# --!strict rule reads test/). The text rules (rg) read code only: a line whose first non-blank characters
# are `--` is a comment and never matches. A trailing comment after code on the same line, or a line inside
# a --[[ ]] block comment, still counts as code: keep such mentions on whole-line comments.
# P5 (every message carries `p`) is a case in test/protocol.luau; P2 is checked there in part and by review.
#
# Written for bash 3.2 too (macOS): no mapfile, no GNU-only tools.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

failed=0

# Prints one failure: the principle, then file:line and the offending text.
report() {
	echo "FAIL $1: $2"
	failed=1
}

# Reports every line of $2 (newline-separated hits) under principle $1.
report_lines() {
	local line
	if [ -z "$2" ]; then
		return 0
	fi
	while IFS= read -r line; do
		report "$1" "$line"
	done <<<"$2"
}

# Prints the paths among the arguments that exist.
present() {
	local p
	for p in "$@"; do
		if [ -e "$p" ]; then
			echo "$p"
		fi
	done
	return 0
}

# Prints `file:line:text` for every code line (not a whole-line comment) of the given .luau files that matches
# the PCRE2 pattern $1. rg exits 1 for no match (fine) and 2 for an error (fails the script).
code_matches() {
	local pattern=$1 rc=0
	shift
	if [ "$#" -eq 0 ]; then
		return 0
	fi
	rg --no-heading --with-filename --line-number --no-require-git -P "^(?!\s*--).*(?:$pattern)" "$@" || rc=$?
	if [ "$rc" -gt 1 ]; then
		return "$rc"
	fi
	return 0
}

# Resolves a relative require string against the requiring file's folder, giving a repo-relative path without
# the .luau extension ("lib/host/keys.luau" + "../shared/status" -> "lib/shared/status").
resolve() {
	local seg out="" parts
	IFS=/ read -r -a parts <<<"$(dirname "$1")/$2"
	for seg in "${parts[@]}"; do
		case "$seg" in
		"" | .) ;;
		..) out=${out%/*} ;;
		*) out="$out/$seg" ;;
		esac
	done
	out=${out#/}
	echo "${out%.luau}"
}

is_pure() {
	case "$1" in
	lib/shared/* | lib/harness.luau | lib/host/model.luau | lib/host/keys.luau | lib/host/queue.luau) return 0 ;;
	esac
	return 1
}

# The plugin's .luau files (host.luau, window.luau, lib/), tern.d.luau excluded.
plugin_roots=$(present host.luau window.luau lib)
plugin_files=()
if [ -n "$plugin_roots" ]; then
	while IFS= read -r f; do
		plugin_files+=("$f")
	done < <(echo "$plugin_roots" | xargs rg --files --no-require-git --glob '*.luau' --glob '!tern.d.luau' | sort)
fi

# P1: the window half never writes kv.
window_files=()
for f in ${plugin_files[@]+"${plugin_files[@]}"}; do
	case "$f" in
	window.luau | lib/window/*) window_files+=("$f") ;;
	esac
done
hits=$(code_matches '\bkv_set\b|\btern\.kv\b' ${window_files[@]+"${window_files[@]}"})
report_lines "P1 (the window never writes kv)" "$hits"

# P3: only lib/compat.luau indexes cx or calls tern.pane, tern.kv, tern.fs, tern.process or tern.chrome.
# `cx.x` and `cx:x(` are uses; `cx: WindowCx` (a stylua-formatted annotation, a space after the colon) is not.
p3_files=()
for f in ${plugin_files[@]+"${plugin_files[@]}"}; do
	if [ "$f" != "lib/compat.luau" ]; then
		p3_files+=("$f")
	fi
done
hits=$(code_matches '\bcx(?:\.|:(?=[A-Za-z_]))|\btern\.(?:pane|kv|fs|process|chrome)\b' ${p3_files[@]+"${p3_files[@]}"})
report_lines "P3 (one seam to Tern: only lib/compat.luau calls cx or tern.pane/kv/fs/process/chrome)" "$hits"

# P4: pure modules never use tern. A second luau-lsp pass WITHOUT Tern's definitions makes any `tern` (or Tern
# type) an unknown global. luau-lsp prints `file(line,col): message`; it is reported as `file:line: message`.
# luau-lsp also checks the modules a pure module requires; their errors are skipped here, because the layering
# rule below already reports a pure module that requires compat, transport or window code.
pure=()
while IFS= read -r p; do
	pure+=("$p")
done < <(present lib/shared lib/harness.luau lib/host/model.luau lib/host/keys.luau lib/host/queue.luau)
if [ "${#pure[@]}" -gt 0 ]; then
	rc=0
	out=$(luau-lsp analyze --platform=standard "${pure[@]}" 2>&1) || rc=$?
	if [ "$rc" -ne 0 ]; then
		while IFS= read -r line; do
			case "$line" in
			"[INFO]"* | "[WARN]"* | "") ;;
			*)
				if [[ "$line" =~ ^(.+)\(([0-9]+),[0-9]+\):\ (.*)$ ]]; then
					if ! is_pure "${BASH_REMATCH[1]}"; then
						continue
					fi
					line="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}: ${BASH_REMATCH[3]}"
				fi
				report "P4 (pure core: pure modules type-check without Tern's definitions)" "$line"
				;;
			esac
		done <<<"$out"
	fi
fi

# P4: JSON is encoded only in the entry files, the transport edges, the file writers and compat (which encodes for the
# window modules, so a test can replace it).
json_allowed=" host.luau window.luau lib/compat.luau lib/host/transport.luau lib/window/pusher.luau lib/window/router.luau lib/window/leader.luau lib/window/diag.luau "
json_files=()
for f in ${plugin_files[@]+"${plugin_files[@]}"}; do
	if [[ "$json_allowed" != *" $f "* ]]; then
		json_files+=("$f")
	fi
done
hits=$(code_matches '\btern\.json\.encode\b' ${json_files[@]+"${json_files[@]}"})
report_lines "P4 (JSON only at the edges)" "$hits"

# Layering, on each require resolved against the requiring file's folder: pure modules never require compat,
# lib/host/transport or lib/window/*; lib/host/* and lib/window/* never require each other.
requires=""
if [ "${#plugin_files[@]}" -gt 0 ]; then
	rc=0
	requires=$(rg --no-heading --with-filename --line-number --only-matching --no-require-git \
		-P '^(?!\s*--).*?\brequire\(\s*"([^"]+)"' --replace '$1' "${plugin_files[@]}") || rc=$?
	if [ "$rc" -gt 1 ]; then
		exit "$rc"
	fi
fi
if [ -n "$requires" ]; then
	while IFS=: read -r file line req; do
		target=$(resolve "$file" "$req")
		if is_pure "$file"; then
			case "$target" in
			lib/compat | lib/host/transport | lib/window/*)
				report "Layering (pure modules never require compat, lib/host/transport or lib/window/*)" \
					"$file:$line: require(\"$req\")"
				;;
			esac
		fi
		case "$file:$target" in
		lib/host/*:lib/window/* | lib/window/*:lib/host/*)
			report "Layering (lib/host and lib/window never require each other)" "$file:$line: require(\"$req\")"
			;;
		esac
	done <<<"$requires"
fi

# Hygiene: every export of a lib module has a caller (a review once found two exports with none).
# A use is `M.<name>` in the module's own file beyond its definition line, or `<name>.<export>` in any code file whose `<name>` is the module's basename: the
# tree's one naming rule, which covers a require alias (`local keys = require(...)`), a module handed in
# as a parameter (P4: an I/O module takes `compat` as an argument) and the test suites'
# Capitalized aliases alike. Mentions in comments read as uses, which can only hide a dead export,
# never flag a live one.
hygiene_files=(host.luau window.luau)
if [ "${#plugin_files[@]}" -gt 0 ]; then
	hygiene_files+=("${plugin_files[@]}")
fi
test_root=$(present test)
if [ -n "$test_root" ]; then
	while IFS= read -r f; do
		hygiene_files+=("$f")
	done < <(rg --files --no-require-git "$test_root" --glob '*.luau' | sort)
fi
if [ "${#hygiene_files[@]}" -gt 0 ]; then
	# The lib modules' basenames ("keys", "compat", …), as one rg alternation.
	bases=""
	for f in ${plugin_files[@]+"${plugin_files[@]}"}; do
		case "$f" in
		lib/*.luau)
			base=${f##*/}
			bases+="${base%.luau}|"
			;;
		esac
	done

	bases=${bases%|}
	if [ -n "$bases" ]; then
		# One `basename export` row per `basename.export` token in every code file, lower-cased so the
		# test suites' Capitalized aliases resolve too.
		used=""
		for f in "${hygiene_files[@]}"; do
			rows=$(rg --no-filename --only-matching --no-require-git "\b($bases)\.[A-Za-z_][A-Za-z0-9_]*" "$f" \
				| awk -F. '{ print tolower($1) " " $2 }') || true
			if [ -n "$rows" ]; then
				used+="$rows"$'\n'
			fi
		done
		# An export is dead when its own file holds only its definition and no file names it.
		for f in ${plugin_files[@]+"${plugin_files[@]}"}; do
			case "$f" in
			lib/*.luau) ;;
			*) continue ;;
			esac
			base=${f##*/}
			base=${base%.luau}
			rc=0
			exports=$(rg --no-filename --only-matching --no-require-git \
				'^(function M\.|M\.)([A-Za-z_][A-Za-z0-9_]*)' --replace '$2' "$f" | sort -u) || rc=$?
			if [ "$rc" -gt 1 ]; then
				exit "$rc"
			fi
			while IFS= read -r name; do
				[ -n "$name" ] || continue
				own=$(rg --no-filename --only-matching --no-require-git "M\.$name\b" "$f" | wc -l) || true
				if [ "$own" -lt 2 ] && ! printf '%s' "$used" | grep -qFx -- "$base $name"; then
					report "Hygiene (every lib export has a caller; the review found compat.save and diag.waiting with none)" \
						"$f: M.$name is exported but nothing calls it"
				fi
			done <<<"$exports"
		done
	fi
fi

# --!strict is line 1 of every .luau file (tests included, tern.d.luau excluded).
while IFS= read -r f; do
	first=""
	IFS= read -r first <"$f" || true
	if [ "$first" != "--!strict" ]; then
		report "--!strict (line 1 of every .luau file)" "$f:1: $first"
	fi
done < <(rg --files --no-require-git --glob '*.luau' --glob '!tern.d.luau' | sort)

if [ "$failed" -ne 0 ]; then
	echo "fitness: failed"
	exit 1
fi
echo "fitness: all rules pass"
