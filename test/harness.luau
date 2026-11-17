--!strict

local Harness = require("../lib/harness")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local function cleans(title: string?, want: string?, kind: string?)
	local got = Harness.clean_title(title, kind)
	check(
		got == want,
		string.format(
			"clean_title(%s, %s) gave %s, want %s",
			tostring(title),
			tostring(kind),
			tostring(got),
			tostring(want)
		)
	)
end

-- A leading braille spinner frame is stripped, with the space after it.
cleans("⠋ fix the tests", "fix the tests")
cleans("⠼fix the tests", "fix the tests")
cleans("⣿ refactor", "refactor")
cleans("⠀ blank braille", "blank braille")
-- A trailing frame is stripped too, with the space before it.
cleans("fix the tests ⠼", "fix the tests")
cleans("task · dir ⠋", "task · dir")
cleans("both ⠙ ends ⠹", "both ⠙ ends")
cleans("⠋ both ends ⠹", "both ends")
-- Other titles are kept (trimmed).
cleans("fix the tests", "fix the tests")
cleans("  padded title  ", "padded title")
cleans("日本語 title", "日本語 title")
cleans("title ending in ü", "title ending in ü")
cleans("a ⠼ in the middle", "a ⠼ in the middle")
cleans("omp-session", "omp-session")
cleans("\xff not utf-8", "\xff not utf-8")
-- Empty, nil, a frame alone and default agent titles give nil.
cleans(nil, nil)
cleans("", nil)
cleans("   ", nil)
cleans("⠋", nil)
cleans("⠋ ", nil)
cleans("omp", nil)
cleans("⠋ omp", nil)
cleans("omp ⠼", nil)
cleans("Claude Code", nil)
cleans("⠋ Claude Code", nil)
cleans("Codex", nil)
cleans("Codex ⠼", nil)
cleans("GitHub Copilot", nil)
cleans("Codex", nil, "codex")

-- omp keeps its titles, with or without a kind: the card icon is not a status glyph and ` | ` is not cut.
local card = "\u{F07E5} DEPLOY: Deploy pipeline cleanup"
for _, name in { "", "omp" } do
	local kind = if name == "" then nil else name
	cleans("omp", nil, kind)
	cleans(card, card, kind)
	cleans("omp-session · #42", "omp-session · #42", kind)
	cleans("fix A | B", "fix A | B", kind)
	cleans("[ ! ] note", "[ ! ] note", kind)
end
cleans("fix A | B", "fix A | B", "copilot")

-- Claude Code: `✳ Claude Code` at start and `Claude Code` are its default; its session title keeps no status glyph.
for _, name in { "", "claude" } do
	local kind = if name == "" then nil else name
	cleans("✳ Claude Code", nil, kind)
	cleans("Claude Code", nil, kind)
	cleans("Counting from 1 to 400", "Counting from 1 to 400", kind)
	cleans("✳ Counting from 1 to 400", "Counting from 1 to 400", kind)
	cleans("✶ Counting from 1 to 400", "Counting from 1 to 400", kind)
	cleans("⠂ Counting from 1 to 400", "Counting from 1 to 400", kind)
	cleans("✳", nil, kind)
	-- A glyph joined to the next word is part of the title.
	cleans("✳star", "✳star", kind)
end

-- Codex: the bare folder name is its default; every state of a thread gives the same thread title.
local thread = "Count to 400"
local codex_titles: { string } = {
	`{thread} | probe-repo`,
	`[ . ] Action Required | {thread} | probe-repo`,
	`[ ! ] Action Required | {thread} | probe-repo`,
}
for _, frame in { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" } do
	table.insert(codex_titles, `{frame} {thread} | probe-repo`)
end
for _, title in codex_titles do
	cleans(title, thread, "codex")
end
cleans("probe-repo", nil, "codex")
cleans("⠋ probe-repo", nil, "codex")
cleans("[ ! ] Action Required | probe-repo", nil, "codex")
cleans("[ . ] Action Required", nil, "codex")
cleans(" | probe-repo", nil, "codex")
-- A thread title holding ` | ` keeps it; only the last part, the folder, is dropped.
cleans("⠼ fix A | B | probe-repo", "fix A | B", "codex")
-- Without a kind the spinner and approval prefix still go, so the label is stable, but the folder stays.
cleans(`⠋ {thread} | probe-repo`, `{thread} | probe-repo`)
cleans(`[ ! ] Action Required | {thread} | probe-repo`, `{thread} | probe-repo`)
cleans(`[ . ] Action Required | {thread} | probe-repo`, `{thread} | probe-repo`)
cleans("probe-repo", "probe-repo")

print("Harness: " .. checks .. " checks passed")
