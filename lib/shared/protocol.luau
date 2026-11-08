--!strict
-- Message and URL shapes between the halves. Every message carries the protocol
-- version `p`, so a mismatch is seen, and agents are named by deck id, never by pane id.
-- Pure: tables and strings only; JSON encoding happens at the edges.

local M = {}

M.P = 2

-- The request verbs a window knows.
M.VERBS = table.freeze({
	hello = true,
	jump = true,
	start = true,
	stop = true,
	back = true,
	diag = true,
	show = true,
	name = true,
}) :: { [string]: boolean }

-- Query keys the URL itself owns; a verb field may not reuse them, and `dir` never travels (each half derives it from the deck id).
local RESERVED: { [string]: boolean } = { p = true, b = true, r = true, host = true, dir = true }

-- A status message (`act = "st"`). `a` maps deck id to a list of status entries (one per live pane); in a diff a
-- gone id carries an empty list (`tern.json.decode` drops null members, so null would never arrive), so its values
-- are left untyped here.
export type StatusMsg = {
	p: number,
	w: string,
	seq: number,
	full: boolean,
	t: number,
	h: string?,
	sn: string?,
	hn: string?,
	dupb: boolean,
	em: string,
	a: { [string]: any },
}

export type Request = {
	verb: string,
	p: number,
	b: string,
	r: number,
	host: string,
	fields: { [string]: string },
}

-- A reply (`act = "res"`) to the block that sent request `r`.
export type Reply = { p: number, b: string, r: number, ok: boolean, err: string? }

function M.status_msg(
	window_uid: string,
	seq: number,
	full: boolean,
	t: number,
	host_state: string?,
	session_name: string?,
	host_name: string?,
	dupb: boolean,
	esc_mode: string,
	agents: { [string]: any }
): StatusMsg
	return {
		p = M.P,
		w = window_uid,
		seq = seq,
		full = full,
		t = t,
		h = host_state,
		sn = session_name,
		hn = host_name,
		dupb = dupb,
		em = esc_mode,
		a = agents,
	}
end

-- The other side's version against this side's. A missing or non-number `p` is read as older (unversioned).
local function check_version(p: any): string
	if type(p) ~= "number" or p < M.P then
		return "bad_p_older"
	end
	if p > M.P then
		return "bad_p_newer"
	end
	return "ok"
end

-- "ok" | "gap" | "old" | "bad_p_newer" | "bad_p_older". "gap" means send `jumpr://hello`: a sequence gap in a diff,
-- or a first message from a window that is not full. A full message is a whole snapshot, so it is "ok" after a gap,
-- and also at or below the last `seq` from that window: the window renumbered the block's pane (a reconnect), a
-- restart of its numbering, never dropped. A diff at or below the last `seq` is "old" (ignore), as is a message
-- with no usable `w`/`seq`. Never mutates `last_seq_by_window`: the caller records `msg.seq` for `msg.w` on "ok"
-- and "gap", which is what restarts the numbering.
function M.check_status(msg: { [string]: any }, last_seq_by_window: { [string]: number }): string
	local version = check_version(msg.p)
	if version ~= "ok" then
		return version
	end
	local w, seq = msg.w, msg.seq
	if type(w) ~= "string" or type(seq) ~= "number" then
		return "old"
	end
	local full = msg.full == true
	local last = last_seq_by_window[w]
	if last == nil then
		return if full then "ok" else "gap"
	end
	if full then
		return "ok"
	end
	if seq <= last then
		return "old"
	end
	if seq == last + 1 then
		return "ok"
	end
	return "gap"
end

local function encode(s: string): string
	return (
		string.gsub(s, "[^%w%-%._~]", function(c: string): string
			return string.format("%%%02X", string.byte(c))
		end)
	)
end

local function decode(s: string): string
	return (
		string.gsub(s, "%%(%x%x)", function(hex: string): string
			return string.char(tonumber(hex, 16) :: number)
		end)
	)
end

-- `jumpr://<verb>?p=1&b=..&r=..&host=..&<fields>`, every key and value percent-encoded, fields in key order.
-- An unknown verb or a field named like a URL key (`p`, `b`, `r`, `host`) or `dir` is a programming error.
function M.request_url(verb: string, b: string, r: number, host: string, fields: { [string]: string }): string
	if not M.VERBS[verb] then
		error("unknown jumpr verb: " .. verb)
	end
	local keys = {}
	for k in fields do
		if RESERVED[k] then
			error("reserved jumpr url field: " .. k)
		end
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts = {
		"p=" .. tostring(M.P),
		"b=" .. encode(b),
		"r=" .. string.format("%d", r),
		"host=" .. encode(host),
	}
	for _, k in keys do
		table.insert(parts, encode(k) .. "=" .. encode(fields[k]))
	end
	return "jumpr://" .. verb .. "?" .. table.concat(parts, "&")
end

-- The keys and values of a URL query, decoded. The first of a repeated key wins; a pair with no `=` has an empty
-- value.
local function query_fields(query: string): { [string]: string }
	local raw: { [string]: string } = {}
	for pair in string.gmatch(query, "[^&]+") do
		local k, v = string.match(pair, "^([^=]*)=(.*)$")
		if k == nil or v == nil then
			k, v = pair, ""
		end
		local key = decode(k :: string)
		if raw[key] == nil then
			raw[key] = decode(v :: string)
		end
	end
	return raw
end

-- The request in a `jumpr://` URL, or nil when it is not one: an unknown verb, or no `p`, `b`, `r` or `host`.
-- The first of a repeated key wins. A `dir` field is dropped (the window rebuilds it from the id).
function M.parse_url(url: string): Request?
	local verb, query = string.match(url, "^jumpr://(%a+)%?(.*)$")
	if verb == nil or query == nil or not M.VERBS[verb] then
		return nil
	end
	local raw = query_fields(query)
	local p, r = tonumber(raw.p), tonumber(raw.r)
	local b, host = raw.b, raw.host
	if p == nil or r == nil or b == nil or b == "" or host == nil or host == "" then
		return nil
	end
	local fields: { [string]: string } = {}
	for k, v in raw do
		if not RESERVED[k] then
			fields[k] = v
		end
	end
	return { verb = verb, p = p, b = b, r = r, host = host, fields = fields }
end

-- "ok" | "bad_p_newer" | "bad_p_older" for a parsed request or a reply.
function M.check_request(req: { p: number? }): string
	return check_version(req.p)
end

-- The version verdict of any `jumpr://<word>?…` URL, read from its `p` before the verb or the other keys are checked
-- (a missing or non-number `p` reads as older), so a request from a block on another version is named even when
-- `parse_url` cannot read it (a verb this side does not know). Also gives the URL's `host`, the machine to update on
-- "bad_p_older". Nil for text that is not a `jumpr://` URL.
function M.check_url(url: string): (string?, string?)
	local query = string.match(url, "^jumpr://%a+%?(.*)$")
	if query == nil then
		return nil, nil
	end
	local raw = query_fields(query)
	local host = raw.host
	return check_version(if raw.p ~= nil then tonumber(raw.p) else nil), if host ~= "" then host else nil
end

function M.reply(b: string, r: number, ok: boolean, err: string?): Reply
	return { p = M.P, b = b, r = r, ok = ok, err = err }
end

-- True only when the reply names this block's `b` (a duplicate block ignores the other's replies).
function M.reply_for_me(msg: { [string]: any }, b: string): boolean
	return msg.b == b
end

-- Only `start` and `stop` get a `res` the block waits for.
function M.expects_reply(verb: string): boolean
	return verb == "start" or verb == "stop"
end

-- The jumpr block's kind as the window names it: plugin `jumpr`, block `list` (host.luau defines it).
M.BLOCK_KIND = "jumpr.list"

-- The deck block's launch arguments: the deck session's name and this host's name as the window's
-- `cx.hosts:list()` reports it.
function M.launch_args(session: string, host: string): { string }
	return { "session=" .. session, "host=" .. host }
end

-- The session and host names in a block's launch arguments; nil for one that is missing or empty.
-- The first of a repeated key wins; unknown arguments are ignored.
function M.parse_launch_args(args: { string }): (string?, string?)
	local session: string?, host: string? = nil, nil
	for _, a in args do
		local k, v = string.match(a, "^(%a+)=(.*)$")
		if v ~= nil and v ~= "" then
			if k == "session" and session == nil then
				session = v
			elseif k == "host" and host == nil then
				host = v
			end
		end
	end
	return session, host
end

return M
