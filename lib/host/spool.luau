--!strict
-- The spool: how a script on this machine asks the host half to start an omp agent Jumpr lists. Pure: no `tern`
-- here, everything comes in as arguments; the host reads and removes the request file and writes the reply.
--
-- Both files are `key=value` lines, one per line, split at the first `=`, and the last line is `end` (a file
-- without it is still being written). Values never hold control bytes, so nothing is escaped.
--
-- A request (`requests/<rid>.req`, the rid taken from the file name, never the body):
--   v=1                         required; the request format's version
--   ts=<unix ms>                required; served only when at most 60 s old and at most 5 s ahead of the host clock
--   group=<name>                required; trimmed, 1-40 characters, no leading `-`
--   cwd=<folder>                optional; the agent's folder (else its group's), and needed to create a missing group
--   cli=omp                     optional; the only agent a script can start
--   prompt_file=<absolute path> required; sent to the agent as its first message (`@<path>`)
--   label=<text>                optional; trimmed, at most 60 characters, no leading `-`; empty means none
-- Any other key, or a key given twice, refuses the request.
--
-- A reply (`replies/<rid>.reply`), rendered by `reply`:
--   ok=1, id, gid, session, cwd, then one `argv=` line per word of the start line in order, then label (when
--   given), then `end`; or ok=0, error=<one line>, end.

local Agent = require("../shared/agent")
local Identity = require("../shared/identity")
local keys = require("./keys")
local model = require("./model")
local store = require("./store")

local M = {}

-- The largest request file the host reads.
M.MAX_BYTES = 4096

local MAX_AGE_MS = 60 * 1000
local MAX_AHEAD_MS = 5 * 1000
local MAX_GROUP = 40
local MAX_LABEL = 60
local MAX_TS_DIGITS = 16

-- A parsed, checked request. `group` and `label` are trimmed; `cli` is always "omp".
export type Request = {
	rid: string,
	ts: number,
	group: string,
	cwd: string?,
	cli: string,
	prompt_file: string,
	label: string?,
}

-- Where `place` put the new agent: the new deck (a clone; the caller's deck is untouched), the agent's deck id and
-- its group's gid.
export type Placement = { deck: store.Deck, id: string, gid: string }

local KNOWN: { [string]: true } =
	{ v = true, ts = true, group = true, cwd = true, cli = true, prompt_file = true, label = true }

-- The reply's keys in the order they are written; `argv` lines go right after `cwd`.
local REPLY_ORDER: { string } = { "ok", "error", "id", "gid", "session", "cwd" }
local REPLY_TAIL: { string } = { "label" }

local function trim(s: string): string
	return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", ""))
end

-- A trimmed name or label: nil with the refusal when it is too long or starts with `-`.
local function check_name(what: string, value: string, max: number): (string?, string?)
	local s = trim(value)
	if #s > max then
		return nil, what .. " is longer than " .. max .. " characters"
	end
	if string.sub(s, 1, 1) == "-" then
		return nil, what .. " may not start with -"
	end
	return s, nil
end

-- The request in `text` (the file `requests/<rid>.req`, `rid` already checked by the caller), checked against the
-- clock `now_ms`; or nil with a one-line refusal in plain words.
function M.parse(text: string, rid: string, now_ms: number): (Request?, string?)
	if not Identity.valid_id(rid) then
		return nil, "bad request name"
	end
	if #text > M.MAX_BYTES then
		return nil, "request is larger than " .. M.MAX_BYTES .. " bytes"
	end
	local lines = string.split(text, "\n")
	if lines[#lines] == "" then
		table.remove(lines)
	end
	if lines[#lines] ~= "end" then
		return nil, "request is incomplete: its last line is not end"
	end
	table.remove(lines)
	local got: { [string]: string } = {}
	for i, line in lines do
		local key, value = string.match(line, "^([^=]*)=(.*)$")
		if key == nil or value == nil then
			return nil, "line " .. i .. " is not key=value"
		end
		if not KNOWN[key] then
			if string.find(key, "^[%w_]+$") ~= nil and #key <= 20 then
				return nil, "unknown key " .. key
			end
			return nil, "line " .. i .. " has an unknown key"
		end
		if got[key] ~= nil then
			return nil, "key " .. key .. " is given twice"
		end
		if string.find(value, "%c") ~= nil then
			return nil, key .. " holds a control character"
		end
		got[key] = value
	end
	for _, key in { "v", "ts", "group", "prompt_file" } do
		if got[key] == nil then
			return nil, "request has no " .. key
		end
	end
	if got.v ~= "1" then
		return nil, "request version must be 1; update Jumpr or the script"
	end
	local ts_text = got.ts :: string
	if string.find(ts_text, "^%d+$") == nil or #ts_text > MAX_TS_DIGITS then
		return nil, "ts is not a time in milliseconds"
	end
	local ts = tonumber(ts_text) :: number
	if ts < now_ms - MAX_AGE_MS then
		return nil, "request is more than 60 s old"
	end
	if ts > now_ms + MAX_AHEAD_MS then
		return nil, "request is from the future; check the clock"
	end
	local group, group_err = check_name("group name", got.group :: string, MAX_GROUP)
	if group == nil then
		return nil, group_err
	end
	if group == "" then
		return nil, "group name is empty"
	end
	local cwd = got.cwd
	if cwd ~= nil and not Identity.valid_cwd(cwd) then
		return nil, "cwd must be an absolute folder of letters, digits, spaces and _ - . / with no .. part"
	end
	if got.cli ~= nil and got.cli ~= Agent.OMP then
		return nil, "only omp agents can be started from a script"
	end
	local prompt_file = got.prompt_file :: string
	if not Agent.valid_prompt_file(prompt_file) then
		return nil, "prompt file must be an absolute path of letters, digits and _ - . / with no .. part"
	end
	local label: string? = nil
	if got.label ~= nil then
		local l, label_err = check_name("label", got.label, MAX_LABEL)
		if l == nil then
			return nil, label_err
		end
		label = if l ~= "" then l else nil
	end
	return {
		rid = rid,
		ts = ts,
		group = group,
		cwd = cwd,
		cli = Agent.OMP,
		prompt_file = prompt_file,
		label = label,
	},
		nil
end

-- Places the request's agent as `n` would: in the group named `req.group` (any group of that name, folded or not),
-- or in a new group appended last when none has that name and `req.cwd` is given. The record's folder is `req.cwd`
-- when given, else its group's, and must be a directory on this machine (`dir_ok`). The record is the one `n` stores
-- for an omp agent, plus `label` when given. Nil with a one-line refusal when the group is being deleted, is missing
-- without a cwd, the folder is missing, or no new id could be drawn. `deck` is never changed.
function M.place(
	deck: store.Deck,
	req: Request,
	now_ms: number,
	rand: (number) -> number,
	dir_ok: (string) -> boolean
): (Placement?, string?)
	local found: store.Group? = nil
	for _, g in deck.groups do
		if g.name == req.group then
			found = g
			break
		end
	end
	if found ~= nil and found.deleting == true then
		return nil, keys.DELETING
	end
	if found == nil and req.cwd == nil then
		return nil, "no group named " .. req.group .. "; pass --cwd to create it"
	end
	local cwd = req.cwd or (found :: store.Group).cwd
	if not dir_ok(cwd) then
		return nil, keys.FOLDER_MISSING .. model.host_label(deck) .. ": " .. cwd
	end
	local out = store.clone(deck)
	local gid: string
	if found ~= nil then
		gid = found.gid
	else
		local new_gid = model.fresh_id(deck, rand, "group")
		if new_gid == nil then
			return nil, "could not make a new id"
		end
		gid = new_gid
		table.insert(out.groups, { gid = gid, name = req.group, cwd = cwd, folded = false })
	end
	local id = model.fresh_id(deck, rand, "agent")
	if id == nil then
		return nil, "could not make a new id"
	end
	local pos = 0
	for _, r in deck.agents do
		if r.gid == gid and r.pos > pos then
			pos = r.pos
		end
	end
	out.agents[id] = {
		gid = gid,
		pos = pos + 1,
		cwd = cwd,
		created_ms = now_ms,
		state = "pending",
		cli = Agent.OMP,
		label = req.label,
	}
	return { deck = out, id = id, gid = gid }, nil
end

local function add_line(out: { string }, key: string, value: string)
	assert(string.find(value, "%c") == nil, "spool reply value for " .. key .. " holds a control character")
	table.insert(out, key .. "=" .. value)
end

-- A reply file's text. `fields` holds the single-valued keys (ok, error, id, gid, session, cwd, label); `argv`, the
-- start line's words, is written as one `argv=` line per word, in order, right after `cwd`. Keys are written in that
-- fixed order whatever the table's, then `end`. Raises on any other key or a value holding a control byte (a
-- newline would split a value into a line of its own).
function M.reply(fields: { [string]: string }, argv: { string }?): string
	for key in fields do
		assert(
			table.find(REPLY_ORDER, key) ~= nil or table.find(REPLY_TAIL, key) ~= nil,
			"spool reply has an unknown key " .. key
		)
	end
	local out: { string } = {}
	for _, key in REPLY_ORDER do
		local value = fields[key]
		if value ~= nil then
			add_line(out, key, value)
		end
	end
	local words: { string } = argv or {}
	for _, word in words do
		add_line(out, "argv", word)
	end
	for _, key in REPLY_TAIL do
		local value = fields[key]
		if value ~= nil then
			add_line(out, key, value)
		end
	end
	table.insert(out, "end")
	return table.concat(out, "\n") .. "\n"
end

return M
