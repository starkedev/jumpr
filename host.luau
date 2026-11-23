--!strict
-- Host entry, run by every machine's daemon. Wiring only: it registers the list and settings blocks and the host
-- hooks, then forwards their inputs to lib/host modules that own the state and logic and reach the machine through
-- compat.

local Agent = require("./lib/shared/agent")
local compat = require("./lib/compat")
local runtime = require("./lib/host/runtime")
local settings_block = require("./lib/host/settings_block")

local TICK_MS = 1000

math.randomseed(os.time() + math.floor(tern.now()))

local list = runtime.new(compat, function(n: number): number
	return math.random(n)
end)

local settings_page = settings_block.new(compat, list)

local def: BlockDef<runtime.Copy> = {
	features = { "edit" :: "edit" },

	init = function(cx: BlockCx, args: { string }, saved: any): runtime.Copy
		return list.open(cx, args, saved)
	end,

	view = function(blk: runtime.Copy, cx: BlockCx): BlockView
		return list.view(blk, cx)
	end,

	title = function(_blk: runtime.Copy): string?
		return list.title()
	end,

	key = function(blk: runtime.Copy, key: Key, cx: BlockCx): boolean?
		return list.key(blk, key, cx)
	end,

	event = function(blk: runtime.Copy, ev: UiEvent, cx: BlockCx)
		list.event(blk, ev, cx)
	end,

	save = function(blk: runtime.Copy): any
		return list.saved(blk)
	end,

	resize = function(blk: runtime.Copy, _cols: number, _rows: number, cx: BlockCx)
		list.resized(blk, cx)
	end,
}

tern.block.define("list", def)

local settings_def: BlockDef<settings_block.Block> = {
	init = function(cx: BlockCx, args: { string }, _saved: any): settings_block.Block
		return settings_page.open(cx, args)
	end,

	view = function(blk: settings_block.Block, cx: BlockCx): BlockView
		return settings_page.view(blk, cx)
	end,

	title = function(_blk: settings_block.Block): string?
		return "Jumpr settings"
	end,

	key = function(blk: settings_block.Block, key: Key, cx: BlockCx): boolean?
		return settings_page.key(blk, key, cx)
	end,

	event = function(blk: settings_block.Block, ev: UiEvent, cx: BlockCx)
		settings_page.event(blk, ev, cx)
	end,
}

tern.block.define("settings", settings_def)

-- One process per agent: a second start of an agent this machine already runs spawns a line saying so instead.
tern.on("spawn", function(spec: SpawnSpec): SpawnSpec?
	local instead = list.spawn(spec)
	if instead == nil then
		return nil
	end
	return { program = instead.program, args = instead.args, cwd = spec.cwd, env = spec.env }
end)

-- A reopened omp agent (after a restart, or in a fork) names its own session file, so it runs without `--continue`.
tern.on("reopen", function(ev: ReopenEvent): string?
	if ev.agent ~= "omp" then
		return nil
	end
	return Agent.reopen_command(ev.command)
end)

tern.on("command_started", function(ev: CommandStartedEvent, _cx: EffectCx)
	list.command_started(ev)
end)

tern.on("pane_exited", function(ev: PaneExitedEvent, _cx: EffectCx)
	list.pane_exited(ev)
end)

tern.on("title", function(ev: TitleEvent, _cx: EffectCx)
	list.label_changed(ev.pane)
end)

tern.on("cwd", function(ev: CwdEvent, _cx: EffectCx)
	list.label_changed(ev.pane)
end)

local function tick()
	list.tick()
	tern.timer(TICK_MS, tick)
end

tern.timer(TICK_MS, tick)
