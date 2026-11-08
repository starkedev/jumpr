--!strict

local Identity = require("../lib/shared/identity")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local function matches(text: string, want: string?)
	local id, dir = Identity.match(text)
	check(id == want, string.format("match(%q) gave %s, want %s", text, tostring(id), tostring(want)))
	if want ~= nil then
		check(dir == "~/.omp/deck/" .. want, string.format("match(%q) dir was %s", text, tostring(dir)))
	else
		check(dir == nil, string.format("match(%q) gave a dir with no id", text))
	end
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

-- dir_for and command_for round-trip through match.
check(Identity.dir_for("ab12") == "~/.omp/deck/ab12", "dir_for builds the deck session dir")
local command = Identity.command_for(Identity.dir_for("ab12"))
check(command == "omp --continue --session-dir ~/.omp/deck/ab12", "command_for builds the omp command")
local round_id, round_dir = Identity.match(command :: string)
check(round_id == "ab12" and round_dir == "~/.omp/deck/ab12", "command_for round-trips through match")
check(Identity.command_for("~/.omp/deck/ab/../x") == nil, "command_for refuses a dir match rejects")
check(Identity.command_for("~/.omp/deck/ab;rm") == nil, "command_for refuses shell syntax after the id")
check(Identity.command_for("~/.omp/deck/ab rm -rf x") == nil, "command_for refuses text after the id")
check(Identity.command_for("~/notes") == nil, "command_for refuses a dir outside the deck")

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
