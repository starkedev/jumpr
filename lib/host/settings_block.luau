--!strict
-- Per-block settings state and effect handling. Not pure: injected compat performs Tern effects.

local protocol = require("../shared/protocol")
local requests = require("./requests")
local settings = require("./settings")
local settings_view = require("./settings_view")
local Store = require("./store")

local M = {}

export type Block = {
	state: settings.State,
	sender: requests.Sender,
	cfg: protocol.WindowCfg?,
}

export type Compat = {
	block_exit: (cx: BlockCx, code: number) -> (boolean, string?),
	json_null: () -> any,
	json_decode: (text: string) -> (any, string?),
	render: (cx: BlockCx) -> (boolean, string?),
}

export type List = {
	settings: () -> Store.Settings,
	readonly: () -> boolean,
	new_sender: () -> requests.Sender,
	send_from: (
		cx: BlockCx,
		sender: requests.Sender,
		verb: string,
		fields: { [string]: string }
	) -> (boolean, string?),
	set_agent: (kind: string) -> string?,
	set_key: (action: string, key: string?) -> string?,
	reset_keys: () -> string?,
	host_name: () -> string?,
}

export type Api = {
	open: (cx: BlockCx, args: { string }) -> Block,
	view: (blk: Block, cx: BlockCx) -> BlockView,
	key: (blk: Block, key: Key, cx: BlockCx) -> boolean,
	event: (blk: Block, ev: UiEvent, cx: BlockCx) -> (),
}

local function str(value: any): string?
	return if type(value) == "string" then value else nil
end

-- JSON null is only the Reset sentinel. A string choice must never compare equal to it.
local function absent(value: any, null: any): boolean
	if value == nil then
		return true
	end
	if type(value) == "string" or type(value) == "boolean" or type(value) == "number" then
		return false
	end
	return value == null
end

function M.new(compat: Compat, list: List): Api
	local function context(blk: Block): settings.Context
		return { settings = list.settings(), readonly = list.readonly(), cfg = blk.cfg }
	end

	local function run(blk: Block, cx: BlockCx, event: settings.Event): boolean
		local state, effects = settings.reduce(blk.state, context(blk), event)
		blk.state = state
		local rendered = false
		for _, effect in effects do
			if effect.kind == "set_agent" and effect.agent ~= nil then
				local reason = list.set_agent(effect.agent)
				if reason ~= nil then
					local with_notice = table.clone(blk.state)
					with_notice.notice = reason
					blk.state = with_notice
				end
			elseif effect.kind == "set_key" and effect.action ~= nil then
				local reason = list.set_key(effect.action, effect.key)
				if reason ~= nil then
					local with_notice = table.clone(blk.state)
					with_notice.notice = reason
					blk.state = with_notice
				end
			elseif effect.kind == "reset_keys" then
				local reason = list.reset_keys()
				if reason ~= nil then
					local with_notice = table.clone(blk.state)
					with_notice.notice = reason
					blk.state = with_notice
				end
			elseif effect.kind == "cfg" and effect.fields ~= nil then
				local ok, reason = list.send_from(cx, blk.sender, "cfg", effect.fields)
				if not ok then
					local with_notice = table.clone(blk.state)
					with_notice.notice = reason or "Could not send window settings request."
					blk.state = with_notice
					rendered = true
				end
			elseif effect.kind == "exit" then
				local ok, reason = compat.block_exit(cx, 0)
				if not ok then
					local with_notice = table.clone(blk.state)
					with_notice.notice = reason or "Could not close settings."
					blk.state = with_notice
					rendered = true
				end
			elseif effect.kind == "render" then
				rendered = true
			end
		end
		return rendered
	end

	local function cfg_notice(blk: Block, notice: string)
		local state = table.clone(blk.state)
		state.notice = notice
		blk.state = state
	end

	local function receive_cfg(blk: Block, value: any)
		if type(value) ~= "string" then
			cfg_notice(blk, "Could not read window settings.")
			return
		end
		local decoded, decode_err = compat.json_decode(value)
		if type(decoded) ~= "table" then
			cfg_notice(blk, "Could not read window settings: " .. tostring(decode_err or "invalid message"))
			return
		end
		local verdict = protocol.check_cfg(decoded)
		if verdict ~= "ok" then
			cfg_notice(blk, settings.version_notice(verdict))
			return
		end
		local cfg = decoded :: protocol.WindowCfg
		if cfg.err ~= nil then
			cfg_notice(blk, cfg.err)
			return
		end
		blk.cfg = cfg
		local state = table.clone(blk.state)
		state.notice = nil
		if state.page == "window" and state.focus == "waiting" then
			state.focus = "esc"
		end
		blk.state = state
	end

	local api = {}

	function api.open(_cx: BlockCx, _args: { string }): Block
		return { state = settings.new(), sender = list.new_sender(), cfg = nil }
	end

	function api.view(blk: Block, _cx: BlockCx): BlockView
		return settings_view.view(blk.state, context(blk), list.host_name())
	end

	function api.key(blk: Block, key: Key, cx: BlockCx): boolean
		return run(blk, cx, {
			kind = "key",
			name = key.name,
			text = key.text,
			ctrl = key.ctrl,
			alt = key.alt,
			shift = key.shift,
			meta = key.meta,
		})
	end

	function api.event(blk: Block, ev: UiEvent, cx: BlockCx)
		local raw: any = ev
		if ev.ev == "action" and str(raw.act) == "cfg" then
			receive_cfg(blk, raw.value)
			compat.render(cx)
			return
		end
		local value: any = raw.value
		if absent(value, compat.json_null()) then
			value = nil
		end
		if
			run(blk, cx, {
				kind = "ui",
				ev = ev.ev,
				item = str(raw.item),
				act = str(raw.act),
				value = value,
			})
		then
			compat.render(cx)
		end
	end

	return api :: Api
end

return M
