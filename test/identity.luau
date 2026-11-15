--!strict
-- Identity carrier and validation tests. Pure: no `tern`.

local Identity = require("../lib/shared/identity")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local function matches(text: string, want: string?)
	local id = Identity.match(text)
	check(id == want, string.format("match(%q) gave %s, want %s", text, tostring(id), tostring(want)))
end

-- A deck path inside a full omp command line.
matches("omp --continue --session-dir ~/.omp/deck/k2x7abcd", "k2x7abcd")
matches("zsh -l -c 'omp --continue --session-dir ~/.omp/deck/k2x7abcd'", "k2x7abcd")
-- A path with `~` and an absolute path.
matches("~/.omp/deck/ab", "ab")
matches("/home/me/.omp/deck/ab", "ab")
-- The segment must end at end of text, whitespace or a closing quote.
matches("~/.omp/deck/ab/../x", nil)
matches('~/.omp/deck/ab"', "ab")
matches("'~/.omp/deck/ab'", "ab")
matches("--session-dir ~/.omp/deck/ab cd", "ab")
matches("--session-dir ~/.omp/deck/ab\tcd", "ab")
matches("~/.omp/deck/ab;rm", nil)
matches("~/.omp/deck/ab&&rm -rf x", nil)
matches("omp --session-dir ~/.omp/sessions/ab", nil)
matches("", nil)

-- ACP commands carry the id in an environment assignment on both halves.
matches("env JUMPR_ID=abc tern acp claude", "abc")
matches("/bin/fish -c env JUMPR_ID=abc tern acp claude", "abc")
matches("JUMPR_ID=abc", "abc")
matches("env JUMPR_ID=abc\ttern acp claude", "abc")
matches('"JUMPR_ID=abc"', "abc")
matches("'JUMPR_ID=abc'", "abc")
-- The environment name and value must have exact token boundaries.
matches("XJUMPR_ID=abc", nil)
matches("NOT_JUMPR_ID=abc", nil)
matches("JUMPR_ID=abc/def", nil)
matches("JUMPR_ID=abc;rm", nil)
matches("JUMPR_ID=abc&&rm", nil)
matches("XJUMPR_ID=bad env JUMPR_ID=good tern acp claude", "good")
matches("JUMPR_ID=bad/def env JUMPR_ID=good tern acp claude", "good")
-- A command that starts with the ACP carrier keeps that id when a deck path appears later.
matches("env JUMPR_ID=abc tern acp claude --add-dir /work/.omp/deck/other", "abc")
matches("JUMPR_ID=abc tern acp claude --add-dir /work/.omp/deck/other", "abc")
matches("/bin/fish -c env JUMPR_ID=abc tern acp claude --add-dir /work/.omp/deck/other", "abc")
matches("/bin/fish -c 'env JUMPR_ID=abc tern acp claude --add-dir /work/.omp/deck/other'", "abc")
matches("/bin/fish -l -c 'env JUMPR_ID=abc tern acp claude --add-dir /work/.omp/deck/other'", "abc")
-- A deck path still wins when that command does not start with the ACP carrier.
matches("omp --continue --session-dir ~/.omp/deck/deckid env JUMPR_ID=acpid", "deckid")
matches("/bin/fish -l -c 'omp --continue --session-dir ~/.omp/deck/deckid env JUMPR_ID=acpid'", "deckid")
matches("echo JUMPR_ID=acpid /.omp/deck/deckid", "deckid")
matches("env JUMPR_ID=abc/def /.omp/deck/deckid", "deckid")
check(select("#", Identity.match("JUMPR_ID=abc")) == 1, "match returns exactly one value")

-- valid_id is anchored: `[%w_%-]+`, 1 to 64 characters.
check(Identity.valid_id("k2x7abcd"), "a new-style id is valid")
check(Identity.valid_id("s0test"), "a lowercase id with a digit is valid")
check(Identity.valid_id("a_b-C9"), "letters, digits, _ and - are valid")
check(not Identity.valid_id("a/b"), "valid_id rejects /")
check(not Identity.valid_id("a b"), "valid_id rejects spaces")
check(not Identity.valid_id(".."), "valid_id rejects ..")
check(not Identity.valid_id("ab..cd"), "valid_id rejects dots")
check(not Identity.valid_id(""), "valid_id rejects empty")
check(Identity.valid_id(string.rep("a", 64)), "valid_id accepts 64 characters")
check(not Identity.valid_id(string.rep("a", 65)), "valid_id rejects more than 64 characters")
check(not Identity.valid_id("ab\n"), "valid_id rejects a trailing newline")

-- new_id gives 8 characters from a-z2-7, using every index rand returns.
local ALPHABET = "abcdefghijklmnopqrstuvwxyz234567"
local seen: { number } = {}
local function counting_rand(n: number): number
	check(n == 32, "new_id asks rand for an index into 32 characters")
	local k = (#seen % n) + 1
	table.insert(seen, k)
	return k
end
local id = Identity.new_id(counting_rand)
check(#id == 8, "new_id gives 8 characters")
check(string.find(id, "^[a-z2-7]+$") ~= nil, "new_id uses only a-z2-7")
check(id == "abcdefgh", "new_id maps rand(1..8) to the first 8 alphabet characters")
check(Identity.new_id(function(_n: number): number
	return 32
end) == "77777777", "rand(32) picks the last alphabet character")
for _ = 1, 200 do
	local random_id = Identity.new_id(math.random)
	check(#random_id == 8 and string.find(random_id, "^[a-z2-7]+$") ~= nil, "a random new_id stays in a-z2-7")
	check(Identity.valid_id(random_id), "a random new_id is a valid id")
end
check(#ALPHABET == 32, "the test alphabet has 32 characters")

-- valid_cwd: absolute, `[%w_%-./ ]`, no `..` segment.
check(Identity.valid_cwd("/home/me/src/webapp"), "an absolute folder is valid")
check(Identity.valid_cwd("/home/me/My Projects/x-y_z.v2"), "spaces, -, _ and . are valid")
check(Identity.valid_cwd("/home/a/..hidden"), "a segment that only starts with .. is valid")
check(not Identity.valid_cwd("home/me"), "a relative folder is refused")
check(not Identity.valid_cwd("~/src"), "a ~ folder is refused")
check(not Identity.valid_cwd("/home/../etc"), "a .. segment is refused")
check(not Identity.valid_cwd("/home/a/.."), "a trailing .. segment is refused")
check(not Identity.valid_cwd("/home/a;rm"), "; is refused")
check(not Identity.valid_cwd("/home/$HOME"), "$ is refused")
check(not Identity.valid_cwd("/home/a\nb"), "a newline is refused")
check(not Identity.valid_cwd(""), "empty is refused")

print("Identity: " .. checks .. " checks passed")
