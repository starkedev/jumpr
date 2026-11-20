--!strict
-- "Jumpr: hide or show other panes", run against the fake window's split trees: a press parks every tiled pane of the
-- focused tab but its core, the copy of the list and the tab's agent, wherever focus is (focus in a pane it hides goes
-- to the agent), and the next press brings them back where they were, at their old shares, around the copy of the
-- list, which is never moved or resized, with focus left where it is. A pane closed meanwhile is skipped, a
-- pane the user parked stays his, and once the user changed the tab (a pane opened, a pane brought back by hand)
-- nothing in it moves, while the list hidden and shown again counts as no change. A floating block is left alone, a
-- zoomed tab (zen mode included) is refused, every tab keeps its own hidden panes, and a tab that closes says where its
-- hidden panes went. Tern refusing a park, an unpark, a move or a resize is answered with a toast or a log line.

local Block = require("../lib/window/block")
local Fake = require("./support/fake_window")
local Others = require("../lib/window/others")
local Protocol = require("../lib/shared/protocol")
local Pusher = require("../lib/window/pusher")
local Router = require("../lib/window/router")
local Zen = require("../lib/window/zen")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local cx = Fake.cx
local COPY: Fake.PaneOpts = { kind = "plugin", block = Protocol.BLOCK_KIND, title = "jumpr" }

Fake.host("laptop", "local")
local h = Fake.host("devbox")
local deck = Fake.session(h, "deck")
Fake.view(deck)

-- What the tests call each pane in a tree's text.
local names: { [number]: string } = {}

-- `tab`'s split tree as text: a pane by its name, a split as R(...) side by side or D(...) one above the other, with
-- its first side's share to three places.
local function shape(tab: number): string
	local function walk(node: any): string
		if node.pane ~= nil then
			return names[node.pane] or tostring(node.pane)
		end
		local kind = if node.split == "down" then "D" else "R"
		return string.format("%s(%.3f %s %s)", kind, node.ratio, walk(node[1]), walk(node[2]))
	end
	local root = Fake.tree(tab)
	return if root ~= nil then walk(root) else "-"
end

local function parked(pane: number): boolean
	local p = Fake.world().panes[pane]
	return p ~= nil and p.tab == nil
end

-- Whether `pane` is in `list` past its first `from` entries.
local function among(list: { number }, from: number, pane: number): boolean
	for i = from + 1, #list do
		if list[i] == pane then
			return true
		end
	end
	return false
end

local function last_toast(): any
	local toasts = Fake.world().toasts
	return toasts[#toasts]
end

local function key(id: number): string
	return string.format("%.0f", id)
end

-- Whether the window logged `text` as an error of this feature (`diag.error("others", text)`).
local function logged(text: string): boolean
	return table.find(Fake.logs(), "jumpr: others: " .. text) ~= nil
end

-- Every copy of the list the tests open, so the suite can check that no press ever moves or resizes one.
local copies: { [number]: boolean } = {}

-- A copy of the list opened as copies.luau opens one: left of `pane`, the tab's leftmost, at a fifth of its room (or
-- at `share`, as if the user had widened it).
local function open_copy(pane: number, share: number?): number
	local copy = Fake.split(pane, "left", share or 0.2, COPY)
	copies[copy] = true
	return copy
end

-- Whether a press since the moves and resizes counted in `moved` and `resized` asked Tern to move or resize a copy of
-- the list.
local function list_touched(moved: number, resized: number): boolean
	local world = Fake.world()
	for i = moved + 1, #world.moved do
		if copies[world.moved[i]] then
			return true
		end
	end
	for i = resized + 1, #world.resized do
		if copies[world.resized[i]] then
			return true
		end
	end
	return false
end

-- A tab of the deck session holding agent `id`, with its copy of the list on its left, the agent bound as the window
-- binds a pane when it opens. Returns the tab, the copy and the agent.
local function agent_tab(id: string): (number, number, number)
	local tab = Fake.tab(deck)
	local agent = Fake.agent(tab, id)
	local copy = open_copy(agent)
	Pusher.rebuild(cx)
	return tab, copy, agent
end

-- The pane the jumpr key goes back to: focus lands on `pane`, and block.luau sees it as window.luau hands it on.
local function worked_in(pane: number)
	Fake.focus(pane)
	Block.on_focus(cx, { pane = pane, tab = Fake.world().panes[pane].tab :: number })
end

-- The usual crowded tab: the list, the agent, and a shell opened beside the agent to run a command, taking 3/8 of
-- the room right of the list. The press hides the shell and gives its room to the agent; the next brings it back.
do
	local tab, copy, agent = agent_tab("a1")
	local shell = Fake.split(agent, "right", 0.375)
	names[copy], names[agent], names[shell] = "L", "A", "S"
	Fake.focus(agent)
	local before = shape(tab)
	check(before == "R(0.200 L R(0.625 A S))", "the tab as built: " .. before)
	Others.toggle(cx)
	check(parked(shell), "the shell is parked, its program still running")
	check(shape(tab) == "R(0.200 L A)", "the list keeps its width and the agent takes the rest: " .. shape(tab))
	check(Fake.world().focused == agent, "focus stays on the agent")
	Others.toggle(cx)
	check(not parked(shell), "the next press deals the shell back")
	check(shape(tab) == before, "beside the agent again, at its old share: " .. shape(tab))
	check(Fake.world().focused == agent, "and focus is still on the agent")
end

-- Should Tern's unpark take the focus though asked not to, the press still leaves focus on the pane it was on.
do
	local _, _, agent = agent_tab("a8")
	local shell = Fake.split(agent, "right", 0.375)
	Fake.focus(agent)
	Others.toggle(cx)
	Fake.world().unpark_takes_focus = true
	Others.toggle(cx)
	Fake.world().unpark_takes_focus = false
	check(not parked(shell) and Fake.world().focused == agent, "focus goes back to the agent")
end

-- A shell under the agent that was there before the list, so it runs under the list too: it comes back under both,
-- with the list and the agent above it as they were. The list stays put: the shell and the agent are placed around it,
-- and every divider beside it is moved from the agent's side.
do
	local tab = Fake.tab(deck)
	local agent = Fake.agent(tab, "a2")
	local shell = Fake.split(agent, "down", 0.25)
	local copy = open_copy(agent)
	Pusher.rebuild(cx)
	names[copy], names[agent], names[shell] = "L", "A", "S"
	Fake.focus(agent)
	local before = shape(tab)
	check(before == "D(0.750 R(0.200 L A) S)", "the tab as built: " .. before)
	Others.toggle(cx)
	check(parked(shell) and shape(tab) == "R(0.200 L A)", "the shell is hidden: " .. shape(tab))
	local moved, resized = #Fake.world().moved, #Fake.world().resized
	Others.toggle(cx)
	check(shape(tab) == before, "the shell spans the tab's width again, at its old height: " .. shape(tab))
	check(Fake.world().focused == agent, "focus is still on the agent")
	check(not list_touched(moved, resized), "the list is never moved or resized")
	check(among(Fake.world().moved, moved, agent), "the agent is placed beside it instead")
end

-- Two shells hidden, and one of them closed while hidden: the other comes back where it sat, and the split the closed
-- one shared with it is gone.
do
	local tab, copy, agent = agent_tab("a3")
	local top = Fake.split(agent, "right", 0.375)
	local bottom = Fake.split(top, "down", 0.5)
	names[copy], names[agent], names[top], names[bottom] = "L", "A", "T", "B"
	Fake.focus(agent)
	check(shape(tab) == "R(0.200 L R(0.625 A D(0.500 T B)))", "the tab as built: " .. shape(tab))
	Others.toggle(cx)
	check(parked(top) and parked(bottom), "both shells are hidden")
	Fake.close(top)
	local dealt = #Fake.world().unparked
	Others.toggle(cx)
	check(not parked(bottom), "the shell still running comes back")
	check(not among(Fake.world().unparked, dealt, top), "the closed one is never asked for")
	check(shape(tab) == "R(0.200 L R(0.625 A B))", "in the place the two shared: " .. shape(tab))
end

-- Panes the user parked himself, before the press or while the others are hidden, stay parked: the press deals back
-- only what it parked.
do
	local tab, copy, agent = agent_tab("a4")
	local shell = Fake.split(agent, "right", 0.375)
	local own = Fake.split(shell, "down", 0.5)
	names[copy], names[agent], names[shell] = "L", "A", "S"
	Fake.park(own)
	Fake.focus(agent)
	Others.toggle(cx)
	check(parked(shell), "the press hides the shell")
	local later = Fake.split(agent, "down", 0.5)
	Fake.park(later)
	Fake.focus(agent)
	local dealt = #Fake.world().unparked
	Others.toggle(cx)
	check(not parked(shell), "the shell comes back")
	check(parked(own) and parked(later), "the panes the user parked stay parked")
	check(
		#Fake.world().unparked == dealt + 1 and among(Fake.world().unparked, dealt, shell),
		"the shell is the only pane dealt back"
	)
	check(shape(tab) == "R(0.200 L R(0.625 A S))", "the tab is as it was at the press: " .. shape(tab))
end

-- A pane opened while the others are hidden stays where it was opened and is never moved; the hidden shell comes back
-- beside the agent at its old share.
do
	local tab, copy, agent = agent_tab("a5")
	local shell = Fake.split(agent, "right", 0.375)
	names[copy], names[agent], names[shell] = "L", "A", "S"
	Fake.focus(agent)
	Others.toggle(cx)
	local new = Fake.split(agent, "down", 0.5)
	names[new] = "N"
	Fake.focus(agent)
	local moved = #Fake.world().moved
	Others.toggle(cx)
	check(not parked(shell) and not parked(new), "the shell is back and the new pane is still there")
	check(not among(Fake.world().moved, moved, new), "the new pane is never moved")
	check(shape(tab) == "R(0.200 L D(0.500 R(0.625 A S) N))", "the shell is beside the agent again: " .. shape(tab))
end

-- Pressed in the list: the list keeps the focus, the tab's agent stays, and the shell is hidden, even as the pane the
-- jumpr key goes back to; no copy of the list is ever parked, and the shell coming back leaves focus in the list.
do
	local tab, copy, agent = agent_tab("a6")
	local shell = Fake.split(agent, "right", 0.375)
	names[copy], names[agent], names[shell] = "L", "A", "S"
	local before = shape(tab)
	worked_in(shell)
	Fake.focus(copy)
	Others.toggle(cx)
	check(parked(shell) and not parked(agent), "the shell is hidden and the agent stays")
	check(not parked(copy) and Fake.world().focused == copy, "the list stays, with the focus")
	Others.toggle(cx)
	check(shape(tab) == before, "the shell comes back: " .. shape(tab))
	check(Fake.world().focused == copy, "and focus stays in the list")
end

-- Pressed from inside the shell beside the agent: the shell is an extra, hidden all the same, and focus goes to the
-- agent; pressed again, the shell comes back where it was and focus stays on the agent rather than following it.
do
	local tab, copy, agent = agent_tab("a9")
	local shell = Fake.split(agent, "right", 0.375)
	names[copy], names[agent], names[shell] = "L", "A", "S"
	local before = shape(tab)
	Fake.focus(shell)
	Others.toggle(cx)
	check(parked(shell) and shape(tab) == "R(0.200 L A)", "the shell focus was in is hidden: " .. shape(tab))
	check(Fake.world().focused == agent, "and focus goes to the agent")
	Others.toggle(cx)
	check(not parked(shell) and shape(tab) == before, "the shell comes back where it was: " .. shape(tab))
	check(Fake.world().focused == agent, "focus stays on the agent")
end

-- Two agents in one tab: the core keeps one, the focused agent, else the one the jumpr key goes back to, else the
-- lowest; the other agent is an extra like the shell, and every round trip puts the tab back as it was.
do
	local tab, copy, first = agent_tab("a10")
	local second = Fake.agent(tab, "a11")
	local shell = Fake.split(second, "down", 0.5)
	Pusher.rebuild(cx)
	names[copy], names[first], names[second], names[shell] = "L", "A", "B", "S"
	local before = shape(tab)
	check(before == "R(0.500 R(0.200 L A) D(0.500 B S))", "the tab as built: " .. before)

	Fake.focus(second)
	Others.toggle(cx)
	check(parked(first) and parked(shell) and not parked(second), "on the second agent, the first hides with the shell")
	check(Fake.world().focused == second, "and focus stays on the second")
	Others.toggle(cx)
	check(shape(tab) == before and Fake.world().focused == second, "both come back: " .. shape(tab))

	worked_in(first)
	Fake.focus(shell)
	Others.toggle(cx)
	check(parked(second) and parked(shell) and not parked(first), "from the shell, the jumpr key's agent stays")
	check(Fake.world().focused == first, "and takes the focus")
	Others.toggle(cx)
	check(shape(tab) == before and Fake.world().focused == first, "both come back again: " .. shape(tab))

	local _, _, elsewhere = agent_tab("a12")
	worked_in(elsewhere)
	Fake.focus(shell)
	Others.toggle(cx)
	check(parked(second) and parked(shell) and not parked(first), "with the way back in another tab, the lowest stays")
	check(Fake.world().focused == first, "and takes the focus")
	Others.toggle(cx)
	check(shape(tab) == before, "both come back once more: " .. shape(tab))
end

-- The core pane from the panes alone: with an agent in the tab, the agent wherever focus is (of two, the focused one,
-- else the one the jumpr key goes back to, else the lowest); with none, the focused pane, else the jumpr key's, else
-- the lowest pane that is no copy; and none when only copies are tiled.
do
	local function is_copy(pane: number): boolean
		return pane == 1
	end
	local function no_agent(_pane: number): boolean
		return false
	end
	local function agent_five(pane: number): boolean
		return pane == 5
	end
	local function agents_five_seven(pane: number): boolean
		return pane == 5 or pane == 7
	end
	check(Others.keeper({ 1, 5, 3 }, 1, 9, is_copy, agent_five) == 5, "from the list, the agent before a lower shell")
	check(Others.keeper({ 1, 5, 3 }, 3, 3, is_copy, agent_five) == 5, "from a shell, the agent")
	check(Others.keeper({ 1, 5, 3, 7 }, 7, 5, is_copy, agents_five_seven) == 7, "of two agents, the focused one")
	check(Others.keeper({ 1, 5, 3, 7 }, 3, 7, is_copy, agents_five_seven) == 7, "else the jumpr key's")
	check(Others.keeper({ 1, 7, 3, 5 }, 3, 3, is_copy, agents_five_seven) == 5, "else the lowest")
	check(Others.keeper({ 1, 5, 3 }, 3, 5, is_copy, no_agent) == 3, "with no agent, the focused pane")
	check(Others.keeper({ 1, 5, 3 }, 1, 5, is_copy, no_agent) == 5, "from the list, the jumpr key's pane")
	check(Others.keeper({ 1, 5, 3 }, 1, nil, is_copy, no_agent) == 3, "else the lowest pane that is no copy")
	check(Others.keeper({ 1 }, 1, nil, is_copy, no_agent) == nil, "nothing to keep beside the list alone")
end

-- Each tab keeps its own hidden panes: a press brings back only the panes of the tab it is pressed in.
do
	local t1, c1, a1 = agent_tab("b1")
	local s1 = Fake.split(a1, "right", 0.375)
	local t2, c2, a2 = agent_tab("b2")
	local s2 = Fake.split(a2, "down", 0.25)
	names[c1], names[a1], names[s1], names[c2], names[a2], names[s2] = "L1", "A1", "H1", "L2", "A2", "H2"
	local before1, before2 = shape(t1), shape(t2)
	Fake.focus(a1)
	Others.toggle(cx)
	Fake.focus(a2)
	Others.toggle(cx)
	check(parked(s1) and parked(s2), "each tab hides its own shell")
	Fake.focus(a1)
	Others.toggle(cx)
	check(not parked(s1) and parked(s2), "a press in the first tab brings back its shell only")
	check(shape(t1) == before1, "the first tab is as it was: " .. shape(t1))
	Fake.focus(a2)
	Others.toggle(cx)
	check(not parked(s2) and shape(t2) == before2, "then the second tab's, as it was: " .. shape(t2))
end

-- A floating block in the tab is left alone: never parked and never moved.
do
	local tab, copy, agent = agent_tab("b3")
	local shell = Fake.split(agent, "right", 0.375)
	local pip = Fake.float(agent)
	names[copy], names[agent], names[shell] = "L", "A", "S"
	Fake.focus(agent)
	local moved = #Fake.world().moved
	Others.toggle(cx)
	check(parked(shell) and Fake.world().panes[pip].tab == tab, "the shell is hidden and the floating block stays")
	Others.toggle(cx)
	check(not parked(shell) and Fake.world().panes[pip].tab == tab, "the shell is back and the floating block stays")
	check(not among(Fake.world().moved, moved, pip), "the floating block is never moved")
	check(shape(tab) == "R(0.200 L R(0.625 A S))", "the tab is as it was: " .. shape(tab))
end

-- Zen mode, and a block the user zoomed with Tern's own Zoom block, are his to end: the press is refused with a toast
-- and changes nothing. In zen the list stays zoomed over its tab, as the list's own zen mode says, nothing is sent to
-- the list, and the list's own zen off (`jumpr://zen`) still gives the tab back, after which the press works.
do
	local tab, copy, agent = agent_tab("b4")
	local shell = Fake.split(agent, "right", 0.375)
	Pusher.rebuild(cx)
	worked_in(agent)
	Fake.focus(copy)
	local function zen(r: number, on: string): string?
		return Router.handle(cx, Protocol.request_url("zen", "others-zen", r, "devbox", { on = on }, "deck"), copy)
	end
	check(zen(1, "1") == "zen" and Fake.world().zoomed[tab] == true, "the list's zen mode zooms it over its tab")
	local events, zooms = #Fake.world().events, #Fake.world().actions_run
	Others.toggle(cx)
	local toast = last_toast()
	check(
		toast.text == "Jumpr: the list is in zen mode in this tab"
			and toast.sub == "Leave zen mode in the list, then try again",
		"the press says to leave zen mode first"
	)
	check(Fake.world().zoomed[tab] == true and Zen.zoomed_copy() == copy, "the list stays zoomed over its tab")
	check(not parked(shell) and not parked(agent), "nothing is hidden")
	check(
		#Fake.world().actions_run == zooms and #Fake.world().events == events,
		"no zoom runs and the list is told nothing"
	)
	check(zen(2, "0") == "zen" and Fake.world().zoomed[tab] == false, "the list's zen off gives the tab back")
	Others.toggle(cx)
	check(parked(shell) and not parked(agent), "then the press hides the rest")
	Others.toggle(cx)
	check(not parked(shell), "and the next brings it back")

	Fake.focus(agent)
	Fake.world().zoomed[tab] = true
	Others.toggle(cx)
	check(not parked(shell) and Fake.world().zoomed[tab] == true, "under the user's own zoom nothing changes")
	check(last_toast().text == "Jumpr: a block is zoomed in this tab", "and a toast says why")
	Fake.world().zoomed[tab] = false
end

-- Nothing to hide: the press says so and parks nothing.
do
	local _, copy, agent = agent_tab("b5")
	Fake.focus(agent)
	Others.toggle(cx)
	check(not parked(agent) and not parked(copy), "nothing is parked")
	check(last_toast().text == "Jumpr: no other panes to hide in this tab", "a toast says there was nothing to hide")
end

-- Panes the user brought back by hand are his: with none of them still parked, the press hides again rather than
-- moving them.
do
	local _, _, agent = agent_tab("b6")
	local shell = Fake.split(agent, "right", 0.375)
	Fake.focus(agent)
	Others.toggle(cx)
	Fake.unpark(shell)
	Fake.focus(agent)
	local dealt, moved = #Fake.world().unparked, #Fake.world().moved
	Others.toggle(cx)
	check(parked(shell), "the press hides the shell again")
	check(#Fake.world().unparked == dealt and #Fake.world().moved == moved, "nothing was dealt back or moved")
	Others.toggle(cx)
	check(not parked(shell), "and the next brings it back")
end

-- A tab with no copy of the list and no agent, in a session of its own: only the focused pane stays.
do
	local plain = Fake.session(h, "plain")
	local tab = Fake.tab(plain)
	local left = Fake.pane(tab)
	local mid = Fake.split(left, "right", 0.5)
	local low = Fake.split(mid, "down", 0.4)
	names[left], names[mid], names[low] = "P", "Q", "W"
	Fake.focus(mid)
	local before = shape(tab)
	check(before == "R(0.500 P D(0.600 Q W))", "the tab as built: " .. before)
	Others.toggle(cx)
	check(parked(left) and parked(low) and shape(tab) == "Q", "only the focused pane stays: " .. shape(tab))
	Others.toggle(cx)
	check(shape(tab) == before and Fake.world().focused == mid, "and the rest come back around it: " .. shape(tab))
	Fake.view(deck)
end

-- A tab closed while its other panes are hidden: a toast says they still run in Parked panes, and they stay out of
-- every later press.
do
	local tab, copy, agent = agent_tab("b7")
	local shell = Fake.split(agent, "right", 0.375)
	Fake.focus(agent)
	Others.toggle(cx)
	Fake.close(agent)
	Fake.close(copy)
	check(Fake.tree(tab) == nil, "the tab is closed")
	Others.tab_closed(cx, tab)
	local toast = last_toast()
	check(
		toast.text == "Jumpr: a tab closed while its other panes were hidden"
			and toast.sub == "1 pane runs on in Parked panes",
		"a toast says the hidden pane still runs in Parked panes"
	)
	check(parked(shell), "the shell stays parked")
	local _, _, a2 = agent_tab("b8")
	local s2 = Fake.split(a2, "right", 0.375)
	Fake.focus(a2)
	local dealt = #Fake.world().unparked
	Others.toggle(cx)
	Others.toggle(cx)
	check(not parked(s2) and parked(shell), "another tab hides and shows its own shell only")
	check(not among(Fake.world().unparked, dealt, shell), "the closed tab's shell is never dealt back")
end

-- A tab whose shell was opened beside the agent, on side `dir` with `share` of the room, before its copy of the list,
-- which then split the agent's leaf as copies.luau opens one: the list sits beside the agent alone, inside the shell's
-- split. Returns the tab, the copy, the agent and the shell.
local function nested_tab(id: string, dir: string, share: number): (number, number, number, number)
	local tab = Fake.tab(deck)
	local agent = Fake.agent(tab, id)
	local shell = Fake.split(agent, dir, share)
	local copy = open_copy(agent)
	Pusher.rebuild(cx)
	names[copy], names[agent], names[shell] = "L", "A", "S"
	return tab, copy, agent, shell
end

-- The shell under both the list and the agent is hidden, then a pane is opened under the agent: the tab is no longer
-- as the hide left it, so nothing in it moves. The shell comes back under the agent, which keeps its width, and the
-- new pane stays where it was opened.
do
	local tab, _, agent, shell = nested_tab("c1", "down", 0.25)
	check(shape(tab) == "D(0.750 R(0.200 L A) S)", "the tab as built: " .. shape(tab))
	Fake.focus(agent)
	Others.toggle(cx)
	check(shape(tab) == "R(0.200 L A)", "the shell is hidden: " .. shape(tab))
	local new = Fake.split(agent, "down", 1 / 3)
	names[new] = "N"
	Fake.focus(agent)
	local moved = #Fake.world().moved
	Others.toggle(cx)
	check(not parked(shell), "the shell comes back")
	check(
		#Fake.world().moved == moved + 1 and among(Fake.world().moved, moved, shell),
		"the shell is the only pane moved"
	)
	check(shape(tab) == "R(0.200 L D(0.667 D(0.750 A S) N))", "under the agent, at its old share: " .. shape(tab))
end

-- The shell right of both the list and the agent comes back right of both while the tab is as the hide left it, and
-- right of the agent alone, moving nothing else, once a pane was opened under the agent.
do
	local tab, _, agent, shell = nested_tab("c2", "right", 0.3)
	local before = shape(tab)
	check(before == "R(0.700 R(0.200 L A) S)", "the tab as built: " .. before)
	Fake.focus(agent)
	Others.toggle(cx)
	Others.toggle(cx)
	check(shape(tab) == before, "the round trip puts the shell back right of both: " .. shape(tab))
	Others.toggle(cx)
	local new = Fake.split(agent, "down", 0.5)
	names[new] = "N"
	Fake.focus(agent)
	local moved = #Fake.world().moved
	Others.toggle(cx)
	check(#Fake.world().moved == moved + 1 and among(Fake.world().moved, moved, shell), "only the shell moves")
	check(shape(tab) == "R(0.200 L D(0.500 R(0.700 A S) N))", "right of the agent: " .. shape(tab))
end

-- A pane the user brought back by hand while its sibling is still hidden stays where he put it: the sibling comes back
-- under the agent, and nothing in the tab moves.
do
	local tab, copy, agent = agent_tab("c3")
	local bottom = Fake.split(agent, "down", 0.4)
	local east = Fake.split(agent, "right", 0.5)
	names[copy], names[agent], names[east], names[bottom] = "L", "A", "E", "B"
	check(shape(tab) == "R(0.200 L D(0.600 R(0.500 A E) B))", "the tab as built: " .. shape(tab))
	Fake.focus(agent)
	Others.toggle(cx)
	Fake.unpark(east)
	Fake.focus(agent)
	check(parked(bottom) and shape(tab) == "R(0.200 L R(0.500 A E))", "one pane is back by hand: " .. shape(tab))
	local moved = #Fake.world().moved
	Others.toggle(cx)
	check(not parked(bottom), "the other comes back")
	check(#Fake.world().moved == moved + 1 and among(Fake.world().moved, moved, bottom), "and is the only pane moved")
	check(shape(tab) == "R(0.200 L R(0.500 D(0.600 A B) E))", "under the agent: " .. shape(tab))
end

-- Tern refusing to park one pane: the panes it parked are hidden and remembered, a toast gives Tern's reason, and the
-- next press brings back only what was hidden, where it was.
do
	local tab, copy, agent = agent_tab("c4")
	local top = Fake.split(agent, "right", 0.375)
	local bottom = Fake.split(top, "down", 0.5)
	names[copy], names[agent], names[top], names[bottom] = "L", "A", "T", "B"
	local before = shape(tab)
	Fake.world().refuse = function(call: string, pane: number): string?
		return if call == "park" and pane == bottom then "the pane is pinned" else nil
	end
	Fake.focus(agent)
	Others.toggle(cx)
	Fake.world().refuse = nil
	check(parked(top) and not parked(bottom), "the pane Tern parks is hidden and the other stays")
	local toast = last_toast()
	check(
		toast.level == "error"
			and toast.text == "Jumpr could not hide every other pane"
			and toast.sub == "the pane is pinned",
		"a toast gives Tern's reason"
	)
	check(logged("hide in tab " .. key(tab) .. ": the pane is pinned"), "and it is logged")
	Others.toggle(cx)
	check(not parked(top) and shape(tab) == before, "the next press brings back the hidden pane: " .. shape(tab))
end

-- Tern refusing to deal one pane back: the rebuild stops there with a toast that sends the user to Parked panes, the
-- pane stays parked, the one dealt back before it keeps its old share, the split the refused one was to make is never
-- sized, and the next press hides again.
do
	local tab, copy, agent = agent_tab("c5")
	local top = Fake.split(agent, "right", 0.375)
	local bottom = Fake.split(top, "down", 0.5)
	names[copy], names[agent], names[top], names[bottom] = "L", "A", "T", "B"
	Fake.focus(agent)
	Others.toggle(cx)
	Fake.world().refuse = function(call: string, pane: number): string?
		return if call == "unpark" and pane == bottom then "no room" else nil
	end
	Others.toggle(cx)
	Fake.world().refuse = nil
	check(not parked(top) and parked(bottom), "the first pane comes back and the refused one stays parked")
	check(shape(tab) == "R(0.200 L R(0.625 A T))", "where it was, at its old share: " .. shape(tab))
	local toast = last_toast()
	check(
		toast.level == "error"
			and toast.text == "Jumpr could not bring back every hidden pane; Parked panes has the rest"
			and toast.sub == "no room",
		"a toast sends the user to Parked panes"
	)
	check(logged("show in tab " .. key(tab) .. ": no room"), "and it is logged")
	check(
		not logged("resize in tab " .. key(tab) .. ": no split puts " .. key(top) .. " above " .. key(bottom)),
		"the split never made is not sized"
	)
	Others.toggle(cx)
	check(parked(top) and shape(tab) == "R(0.200 L A)", "the next press hides again")
	Others.toggle(cx)
	check(not parked(top) and parked(bottom), "and the one after brings back only what it hid")
end

-- Tern refusing a move: the rebuild stops there, the pane stays where Tern dealt it, nothing after it moves, no split
-- is sized, and the toast says the pane is back but not in its place, with nothing left in Parked panes.
do
	local tab, copy, agent, shell = nested_tab("c6", "down", 0.25)
	Fake.focus(agent)
	Others.toggle(cx)
	Fake.world().refuse = function(call: string, pane: number): string?
		return if call == "move" and pane == shell then "refused" else nil
	end
	local moved = #Fake.world().moved
	Others.toggle(cx)
	Fake.world().refuse = nil
	check(
		#Fake.world().moved == moved + 1 and among(Fake.world().moved, moved, shell),
		"the refused move is the last one asked"
	)
	check(not parked(shell) and shape(tab) == "R(0.200 L R(0.500 A S))", "the shell stays where Tern dealt it")
	local toast = last_toast()
	check(
		toast.text == "Jumpr could not put a hidden pane back in its place" and toast.sub == "Tern did not move it",
		"the toast says the pane is back but not in its place: " .. toast.text
	)
	check(
		not logged("resize in tab " .. key(tab) .. ": no split puts " .. key(copy) .. " above " .. key(shell)),
		"and no split is sized"
	)
end

-- Tern moving no divider: the panes come back in their places at even shares, and the failure is logged.
do
	local tab, copy, agent = agent_tab("c7")
	local shell = Fake.split(agent, "right", 0.375)
	names[copy], names[agent], names[shell] = "L", "A", "S"
	Fake.focus(agent)
	Others.toggle(cx)
	Fake.world().refuse = function(call: string, _pane: number): string?
		return if call == "resize" then "locked" else nil
	end
	Others.toggle(cx)
	Fake.world().refuse = nil
	check(shape(tab) == "R(0.200 L R(0.500 A S))", "the shell is back beside the agent, at half: " .. shape(tab))
	check(logged("resize in tab " .. key(tab) .. ": no divider moved"), "and the resize that failed is logged")
end

-- A move Tern answers but makes elsewhere than the rebuild meant: the split the rebuild expected is missing, which is
-- logged so a live test shows it, and it is not resized.
do
	local tab, copy, agent, shell = nested_tab("c8", "down", 0.25)
	Fake.focus(agent)
	Others.toggle(cx)
	Fake.world().move_noop = true
	Others.toggle(cx)
	Fake.world().move_noop = false
	check(not parked(shell) and shape(tab) == "R(0.200 L R(0.500 A S))", "the shell is where Tern dealt it")
	check(
		logged("resize in tab " .. key(tab) .. ": no split puts " .. key(copy) .. " above " .. key(shell)),
		"the missing split is logged"
	)
end

-- Every pane the hide kept has closed, and a pane opened since is all the tab holds: the first hidden pane is dealt
-- back beside the focused pane with no pane to go beside, the rest around it, and focus stays put.
do
	local tab, copy, agent = agent_tab("c9")
	local top = Fake.split(agent, "right", 0.375)
	local bottom = Fake.split(top, "down", 0.5)
	names[top], names[bottom] = "T", "B"
	Fake.focus(agent)
	Others.toggle(cx)
	local new = Fake.split(agent, "right", 0.5)
	names[new] = "N"
	Fake.close(agent)
	Fake.close(copy)
	Fake.focus(new)
	check(shape(tab) == "N", "only the new pane is left: " .. shape(tab))
	Others.toggle(cx)
	check(not parked(top) and not parked(bottom), "both hidden panes come back")
	check(shape(tab) == "R(0.500 N D(0.500 T B))", "beside the pane in the tab, as they sat together: " .. shape(tab))
	check(Fake.world().focused == new, "and focus stays on it")
end

-- Hiding and showing the list between the presses closes its copy and opens a new one in its place, as the jumpr key
-- does: the new copy stands for the old, so the tab is still as the hide left it, and the shell comes back under both
-- exactly, with the new copy never moved or resized.
do
	local tab, copy, agent, shell = nested_tab("d1", "down", 0.25)
	local before = shape(tab)
	Fake.focus(agent)
	Others.toggle(cx)
	Fake.close(copy)
	local again = open_copy(agent)
	names[again] = "L"
	Fake.focus(agent)
	check(shape(tab) == "R(0.200 L A)", "a new copy of the list stands in the old one's place: " .. shape(tab))
	local moved, resized = #Fake.world().moved, #Fake.world().resized
	Others.toggle(cx)
	check(not parked(shell) and shape(tab) == before, "the shell comes back under both, as it was: " .. shape(tab))
	check(not list_touched(moved, resized), "and the new copy is never moved or resized")
end

-- With the list widened past half its tab and a pane opened since, the shell that ran under both comes back under the
-- agent, never under the list alone: across a split, a side holding no pane but the list is passed over.
do
	local tab = Fake.tab(deck)
	local agent = Fake.agent(tab, "d2")
	local shell = Fake.split(agent, "down", 0.25)
	local copy = open_copy(agent, 0.6)
	Pusher.rebuild(cx)
	names[copy], names[agent], names[shell] = "L", "A", "S"
	check(shape(tab) == "D(0.750 R(0.600 L A) S)", "the tab as built: " .. shape(tab))
	Fake.focus(agent)
	Others.toggle(cx)
	local new = Fake.split(agent, "right", 0.5)
	names[new] = "N"
	Fake.focus(agent)
	Others.toggle(cx)
	check(shape(tab) == "R(0.600 L R(0.500 D(0.750 A S) N))", "under the agent: " .. shape(tab))
end

-- A tab holding two copies of the list (a duplicate a race can open): nothing in it moves, so neither copy does, and
-- the shell comes back under the agent.
do
	local tab = Fake.tab(deck)
	local agent = Fake.agent(tab, "d3")
	local shell = Fake.split(agent, "down", 0.25)
	local first = open_copy(agent)
	local second = open_copy(agent)
	Pusher.rebuild(cx)
	names[first], names[second], names[agent], names[shell] = "L", "L", "A", "S"
	check(shape(tab) == "D(0.750 R(0.200 L R(0.200 L A)) S)", "the tab as built: " .. shape(tab))
	Fake.focus(agent)
	Others.toggle(cx)
	local moved, resized = #Fake.world().moved, #Fake.world().resized
	Others.toggle(cx)
	check(not list_touched(moved, resized), "neither copy is moved or resized")
	check(shape(tab) == "R(0.200 L R(0.200 L D(0.750 A S)))", "the shell comes back under the agent: " .. shape(tab))
end

-- Tern refusing the move of the first of two hidden panes: the second is still parked, so the toast sends the user to
-- Parked panes for it.
do
	local _, _, agent = agent_tab("d4")
	local top = Fake.split(agent, "right", 0.375)
	local bottom = Fake.split(top, "down", 0.5)
	Fake.focus(agent)
	Others.toggle(cx)
	Fake.world().refuse = function(call: string, pane: number): string?
		return if call == "move" and pane == top then "refused" else nil
	end
	Others.toggle(cx)
	Fake.world().refuse = nil
	check(not parked(top) and parked(bottom), "the first is back and the second still parked")
	check(
		last_toast().text == "Jumpr could not put a hidden pane back in its place; Parked panes has the rest",
		"the toast sends the user to Parked panes for the rest: " .. last_toast().text
	)
end

-- Across every round trip above, no press asked Tern to move or resize a copy of the list.
check(not list_touched(0, 0), "no copy of the list was ever moved or resized")

print("Others: " .. checks .. " checks passed")
