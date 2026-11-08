--!strict

local Harness = require("../lib/harness")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local function cleans(title: string?, want: string?)
	local got = Harness.clean_title(title)
	check(
		got == want,
		string.format("clean_title(%s) gave %s, want %s", tostring(title), tostring(got), tostring(want))
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
-- Empty, nil, a frame alone and "omp" give nil.
cleans(nil, nil)
cleans("", nil)
cleans("   ", nil)
cleans("⠋", nil)
cleans("⠋ ", nil)
cleans("omp", nil)
cleans("⠋ omp", nil)
cleans("omp ⠼", nil)

print("Harness: " .. checks .. " checks passed")
