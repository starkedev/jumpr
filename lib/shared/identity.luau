--!strict
-- Agent identity: a deck agent is the omp session directory `~/.omp/deck/<id>`, and both
-- halves read the deck id out of command-line text. Pure: no `tern`, everything comes in as arguments.

local M = {}

local ID_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567"
local ID_LENGTH = 8
local MAX_ID_LENGTH = 64
local DECK_PATH = "/%.omp/deck/([%w_%-]+)"

-- True when `path` has a `..` path segment.
local function has_dotdot(path: string): boolean
	return string.find("/" .. path .. "/", "/%.%./") ~= nil
end

-- The session directory of a deck id. `~` is expanded by the login shell Tern runs the command in.
function M.dir_for(id: string): string
	return "~/.omp/deck/" .. id
end

-- The deck id named by the first `/.omp/deck/<segment>` in `text`, and its session dir. The segment counts only when
-- the next character is end of text, whitespace, `"` or `'`; anything else (`/`, `;`, …) is no match.
function M.match(text: string): (string?, string?)
	local _, last, id = string.find(text, DECK_PATH)
	if id == nil or last == nil then
		return nil, nil
	end
	-- The capture ends the pattern, so `last` is the id's last character.
	local next_char = string.sub(text, last + 1, last + 1)
	if next_char ~= "" and string.find(next_char, "^[%s\"']$") == nil then
		return nil, nil
	end
	return id, M.dir_for(id)
end

-- A new deck id: 8 characters from a-z2-7. `rand(n)` returns an integer in [1, n], like `math.random(n)`.
function M.new_id(rand: (number) -> number): string
	local chars = table.create(ID_LENGTH)
	for i = 1, ID_LENGTH do
		local k = rand(#ID_ALPHABET)
		chars[i] = string.sub(ID_ALPHABET, k, k)
	end
	return table.concat(chars)
end

-- The whole string is `[%w_%-]+`, 1 to 64 characters.
function M.valid_id(id: string): boolean
	return #id >= 1 and #id <= MAX_ID_LENGTH and string.find(id, "^[%w_%-]+$") ~= nil
end

-- The command that starts or resumes the agent in `dir`. nil unless `dir` is a plain deck session dir: `match`
-- accepts it, it ends at the deck id, and it holds only path characters (nothing a shell would read as syntax).
function M.command_for(dir: string): string?
	local id = M.match(dir)
	if id == nil or string.find(dir, "^[%w_%-./~]+$") == nil or has_dotdot(dir) then
		return nil
	end
	local tail = "/.omp/deck/" .. id
	if string.sub(dir, -#tail) ~= tail then
		return nil
	end
	return "omp --continue --session-dir " .. dir
end

-- A folder an agent may start in: absolute, only `[%w_%-./ ]` characters, no `..` segment.
function M.valid_cwd(path: string): boolean
	return string.sub(path, 1, 1) == "/" and string.find(path, "^[%w_%-./ ]+$") ~= nil and not has_dotdot(path)
end

return M
