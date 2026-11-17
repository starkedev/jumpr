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

-- CLI agent launch lines carry the id in the same leading env assignment.
local SESSION = "0f8e2a6c-4b1d-4c3e-9a7f-1234567890ab"
matches("env JUMPR_ID=x sh -c 'claude --resume " .. SESSION .. " || claude --session-id " .. SESSION .. "'", "x")
matches("env JUMPR_ID=x claude --resume", "x")
matches("env JUMPR_ID=x codex resume 019a2b3c-4d5e-7f60-8a1b-2c3d4e5f6a7b", "x")
matches("env JUMPR_ID=x codex", "x")
matches("/bin/fish -c 'env JUMPR_ID=x codex resume 019a2b3c-4d5e-7f60-8a1b-2c3d4e5f6a7b'", "x")

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

-- new_uuid gives a lowercase v4 UUID: 8-4-4-4-12 hex, version nibble 4, variant 8, 9, a or b.
local V4_SHAPE = "^[0-9a-f]+%-[0-9a-f]+%-4[0-9a-f]+%-[89ab][0-9a-f]+%-[0-9a-f]+$"
local function check_v4(uuid: string, label: string)
	check(#uuid == 36, label .. " is 36 characters")
	check(string.find(uuid, V4_SHAPE) ~= nil, label .. " has the v4 shape: " .. uuid)
	local groups = string.split(uuid, "-")
	check(
		#groups == 5
			and #groups[1] == 8
			and #groups[2] == 4
			and #groups[3] == 4
			and #groups[4] == 4
			and #groups[5] == 12,
		label .. " groups are 8-4-4-4-12"
	)
	check(Identity.valid_uuid(uuid), label .. " is a valid uuid")
end

-- A fixed rand gives a fixed uuid, and every index rand returns lands in the output.
local function lowest(_n: number): number
	return 1
end
local function highest(n: number): number
	return n
end
check(Identity.new_uuid(lowest) == "00000000-0000-4000-8000-000000000000", "rand(1) picks 0 and variant 8")
check(Identity.new_uuid(highest) == "ffffffff-ffff-4fff-bfff-ffffffffffff", "rand(n) picks f and variant b")
check_v4(Identity.new_uuid(lowest), "the lowest uuid")
check_v4(Identity.new_uuid(highest), "the highest uuid")
local asks: { number } = {}
local stepping = 0
local function stepping_rand(n: number): number
	table.insert(asks, n)
	stepping += 1
	return ((stepping - 1) % n) + 1
end
local stepped = Identity.new_uuid(stepping_rand)
check(stepped == "01234567-89ab-4cde-b012-3456789abcde", "new_uuid uses each rand result in order: " .. stepped)
local sixteens, fours = 0, 0
for _, n in asks do
	if n == 16 then
		sixteens += 1
	elseif n == 4 then
		fours += 1
	end
end
check(#asks == 31 and sixteens == 30 and fours == 1, "new_uuid asks rand(16) 30 times and rand(4) once")
stepping = 0
check(Identity.new_uuid(stepping_rand) == stepped, "the same rand sequence gives the same uuid")
local distinct: { [string]: boolean } = {}
for _ = 1, 200 do
	local uuid = Identity.new_uuid(math.random)
	check_v4(uuid, "a random uuid")
	distinct[uuid] = true
end
local distinct_count = 0
for _ in distinct do
	distinct_count += 1
end
check(distinct_count == 200, "200 random uuids are distinct")

-- valid_uuid takes the canonical lowercase shape of any version and nothing else.
check(Identity.valid_uuid(SESSION), "a v4 uuid is valid")
check(Identity.valid_uuid("019a2b3c-4d5e-7f60-8a1b-2c3d4e5f6a7b"), "a Codex v7 thread id is valid")
check(Identity.valid_uuid("00000000-0000-0000-0000-000000000000"), "the nil uuid has the shape")
local bad_uuids = {
	"0F8E2A6C-4B1D-4C3E-9A7F-1234567890AB",
	"0f8e2a6c-4b1d-4c3e-9a7f-1234567890aB",
	"0f8e2a6c-4b1d-4c3e-9a7f-1234567890a",
	"0f8e2a6c-4b1d-4c3e-9a7f-1234567890abc",
	"0f8e2a6-c4b1d-4c3e-9a7f-1234567890ab",
	"0f8e2a6c4b1d4c3e9a7f1234567890ab",
	"{0f8e2a6c-4b1d-4c3e-9a7f-1234567890ab}",
	" 0f8e2a6c-4b1d-4c3e-9a7f-1234567890ab",
	"0f8e2a6c-4b1d-4c3e-9a7f-1234567890ab ",
	"0f8e2a6c-4b1d 4c3e-9a7f-1234567890ab",
	"0f8e2a6c-4b1d-4c3e-9a7f-1234567890ab;rm",
	"0f8e2a6c-4b1d-4c3e-9a7f-1234567890a;",
	"'0f8e2a6c-4b1d-4c3e-9a7f-1234567890ab'",
	'"0f8e2a6c-4b1d-4c3e-9a7f-1234567890ab"',
	"0f8e2a6c-4b1d-4c3e-9a7f-1234567890ab\n",
	"0g8e2a6c-4b1d-4c3e-9a7f-1234567890ab",
	"",
}
for _, bad in bad_uuids do
	check(not Identity.valid_uuid(bad), string.format("valid_uuid rejects %q", bad))
end

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
