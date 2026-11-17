--!strict
-- Zen mode's window side: the copy of the list zoomed over its tab with Tern's own "Zoom block", and giving that tab
-- back. The window remembers which copy it zoomed, so zen can be left from any copy, and leaving the list (back, or
-- the hide and toggle chords) never leaves a tab zoomed onto it.

local compat = require("../compat")
local diag = require("./diag")

local M = {}

-- Tern's palette action that zooms the focused block over its tab, or gives the tab back; it acts on the focused pane.
local ZOOM_ACTION = "Zoom block"

-- The copy this window zoomed, while it is zoomed.
local zoomed: number? = nil

-- Whether `pane` is the block its tab is zoomed onto: the tab is zoomed and that pane has its focus.
local function zoomed_onto(cx: WindowCx, pane: number): boolean
	local tab = compat.session_tab_of(cx, pane)
	if tab == nil then
		return false
	end
	local layout = compat.tab_layout(cx, tab)
	return layout ~= nil and layout.zoomed and layout.focus == pane
end

-- Runs the zoom toggle on `pane`, focusing it first when another pane has focus and putting focus back after. The
-- toggle acts on whatever is focused, so it runs only once `pane` holds the focus.
local function toggle(cx: WindowCx, pane: number): boolean
	local focused = compat.session_focused(cx)
	if focused ~= pane then
		compat.focus(cx, pane)
	end
	local ok: boolean, why: string? = false, "the list's pane could not take the focus"
	if compat.session_focused(cx) == pane then
		ok, why = compat.actions_run(cx, ZOOM_ACTION)
	end
	if focused ~= nil and focused ~= pane then
		compat.focus(cx, focused)
	end
	if not ok then
		diag.error("zen", tostring(why))
		compat.toast(cx, "error", "Jumpr: zen mode could not zoom or unzoom the list", why)
	end
	return ok
end

-- Gives back the tab of the copy this window zoomed, when it is still zoomed onto it.
function M.release(cx: WindowCx)
	local pane = zoomed
	zoomed = nil
	if pane ~= nil and zoomed_onto(cx, pane) then
		toggle(cx, pane)
	end
end

-- `jumpr://zen` from the focused copy `pane`: on zooms it over its tab (giving back another copy's first); off gives
-- back whichever copy this window zoomed.
function M.set(cx: WindowCx, pane: number, on: boolean)
	if not on then
		M.release(cx)
		return
	end
	if zoomed ~= nil and zoomed ~= pane then
		M.release(cx)
	end
	if zoomed_onto(cx, pane) then
		zoomed = pane
		return
	end
	if toggle(cx, pane) then
		zoomed = pane
	end
end

diag.provide("zen", function(): any
	return { zoomed = zoomed }
end)

return M
