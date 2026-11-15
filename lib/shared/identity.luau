--!strict
-- Agent identity: both halves read an agent id from an omp session directory or an ACP command.
-- Pure: no `tern`, everything comes in as arguments.

local M = {}

local ID_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567"
local ID_LENGTH = 8
local MAX_ID_LENGTH = 64
local DECK_PATH = "/%.omp/deck/([%w_%-]+)"
local ACP_ID = "JUMPR_ID=([%w_%-]+)"

-- True when `path` has a `..` path segment.
local function has_dotdot(path: string): boolean
	return string.find("/" .. path .. "/", "/%.%./") ~= nil
end

-- The first carrier whose id ends at a command-token boundary.
local function match_carrier(text: string, pattern: string, check_start: boolean): string?
	local from = 1
	while from <= #text do
		local first, last, id = string.find(text, pattern, from)
		if first == nil or last == nil or id == nil then
			return nil
		end

		local before = string.sub(text, first - 1, first - 1)
		local after = string.sub(text, last + 1, last + 1)
		local starts_token = not check_start or first == 1 or string.find(before, "^[%s\"']$") ~= nil
		local ends_token = after == "" or string.find(after, "^[%s\"']$") ~= nil
		if starts_token and ends_token then
			return id
		end
		from = first + 1
	end
	return nil
end

-- The next whitespace-delimited word. A quoted word includes everything inside its quotes.
local function token_at(text: string, i: number): (string?, number)
	local _, ws_last = string.find(text, "^%s*", i)
	if ws_last ~= nil then
		i = ws_last + 1
	end
	if i > #text then
		return nil, i
	end
	local quote = string.sub(text, i, i)
	if quote == "'" or quote == '"' then
		local close = string.find(text, quote, i + 1, true)
		if close == nil then
			return string.sub(text, i + 1), #text + 1
		end
		return string.sub(text, i + 1, close - 1), close + 1
	end
	local finish = string.find(text, "%s", i)
	if finish == nil then
		return string.sub(text, i), #text + 1
	end
	return string.sub(text, i, finish - 1), finish
end

-- True for a shell name or a path to one, the wrapper Tern puts around a launch command.
local function is_shell(token: string): boolean
	local name = string.match(token, "([^/]+)$")
	return name == "sh" or name == "bash" or name == "zsh" or name == "fish" or name == "dash"
end

-- True for the `env` word that precedes an ACP id, including a path to that command.
local function is_env(token: string): boolean
	return token == "env" or string.match(token, "/env$") ~= nil
end

-- The text of a shell's `-c` argument, with one matching pair of quotes removed.
local function command_argument(text: string, at: number): string
	local _, ws_last = string.find(text, "^%s*", at)
	local rest = if ws_last == nil then at else ws_last + 1
	local quote = string.sub(text, rest, rest)
	if quote ~= "'" and quote ~= '"' then
		return string.sub(text, rest)
	end
	local close = string.find(text, quote, rest + 1, true)
	if close == nil then
		return string.sub(text, rest + 1)
	end
	return string.sub(text, rest + 1, close - 1)
end

-- The launched command after an optional shell and its `-c` argument. Other text is unchanged.
local function launched_text(text: string): string
	local token, at = token_at(text, 1)
	if token == nil then
		return text
	end
	if not is_shell(token) then
		return text
	end
	token, at = token_at(text, at)
	while token == "-l" or token == "-i" or token == "-s" do
		token, at = token_at(text, at)
	end
	if token == "-c" or token == "-lc" or token == "-cl" then
		return command_argument(text, at)
	end
	return text
end

-- The ACP id when the launched command starts with it, or with `env` and then it.
local function starting_acp(text: string): string?
	local token, at = token_at(text, 1)
	if token ~= nil then
		if is_env(token) then
			token = token_at(text, at)
		end
	end
	if token == nil then
		return nil
	end
	return string.match(token, "^JUMPR_ID=([%w_%-]+)$")
end

-- The agent id a command names. An ACP id that starts the command, after an optional shell
-- wrapper and an optional env word, wins over a later omp deck path. Otherwise the first deck
-- path wins, then the first ACP id. An id counts only at a token boundary.
function M.match(text: string): string?
	local id = starting_acp(launched_text(text))
	if id ~= nil then
		return id
	end
	id = match_carrier(text, DECK_PATH, false)
	if id ~= nil then
		return id
	end
	return match_carrier(text, ACP_ID, true)
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

-- A folder an agent may start in: absolute, only `[%w_%-./ ]` characters, no `..` segment.
function M.valid_cwd(path: string): boolean
	return string.sub(path, 1, 1) == "/" and string.find(path, "^[%w_%-./ ]+$") ~= nil and not has_dotdot(path)
end

return M
