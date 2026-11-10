--!strict

local Input = require("../lib/host/input")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local function key(name: string?, text: string?): any
	return { kind = "key", name = name, text = text }
end

-- UTF-16 units: one per BMP character, two for one outside it, bytes for text that is not UTF-8.
check(Input.units("") == 0, "empty text has no units")
check(Input.units("abc") == 3, "ASCII counts one per character")
check(Input.units("é—") == 2, "BMP characters count one each")
check(Input.units("a😀b") == 4, "a character outside the BMP counts two")
check(Input.units("\xff\xfe") == 2, "text that is not UTF-8 counts bytes")

-- The caret is clamped into the text; nil means the end.
check(Input.clamp_cursor("abc", nil) == 3, "no caret is the end")
check(Input.clamp_cursor("abc", -4) == 0 and Input.clamp_cursor("abc", 9) == 3, "out of range clamps")
check(Input.clamp_cursor("abc", 1.7) == 1, "a fractional caret rounds down")

-- Typing at the caret.
do
	local text, cursor = Input.insert_at("ac", 1, "b")
	check(text == "abc" and cursor == 2, "typed text lands at the caret and moves it")
	text, cursor = Input.insert_at("a😀c", 3, "b")
	check(text == "a😀bc" and cursor == 4, "after a surrogate pair the caret counts it as two")
	text, cursor = Input.insert_at("ab", nil, "c")
	check(text == "abc" and cursor == 3, "with no caret text goes at the end")
end

-- Backspace removes the character before the caret.
do
	local text, cursor = Input.delete_before("abc", 2)
	check(text == "ac" and cursor == 1, "backspace in the middle")
	text, cursor = Input.delete_before("abc", 0)
	check(text == "abc" and cursor == 0, "backspace at the start does nothing")
	text, cursor = Input.delete_before("a😀", 3)
	check(text == "a" and cursor == 1, "backspace removes a whole surrogate pair")
	text, cursor = Input.delete_before("aé", nil)
	check(text == "a" and cursor == 1, "backspace removes a whole multi-byte character")
end

-- Left and right move by one character.
check(Input.move_cursor("abc", 2, -1) == 1 and Input.move_cursor("abc", 2, 1) == 3, "left and right by one")
check(Input.move_cursor("abc", 0, -1) == 0 and Input.move_cursor("abc", 3, 1) == 3, "the ends hold")
check(
	Input.move_cursor("a😀b", 1, 1) == 3 and Input.move_cursor("a😀b", 3, -1) == 1,
	"a surrogate pair is one step"
)

-- A native edit event replaces from..to with its text.
do
	local text, cursor = Input.apply_edit("abc", { from = 1, to = 2, text = "XY", len = 3 })
	check(text == "aXYc" and cursor == 3, "replace a range; the caret ends after the insert")
	text, cursor = Input.apply_edit("abc", { from = 3, to = 1, text = "", cursor = 1 })
	check(text == "a" and cursor == 1, "a reversed range deletes, and the event's caret wins")
	text, cursor = Input.apply_edit("abc", { from = 0, to = 0, text = "z", len = 5 })
	check(text == nil and cursor == nil, "an event computed against another text is refused")
	text, cursor = Input.apply_edit("abc", { from = "0", to = 0 })
	check(text == nil and cursor == nil, "a malformed event is refused")
end

-- Keys in the open input line: editing keys give the new line, the reducer's keys give nil.
do
	local text, cursor = Input.key("ab", 1, key(nil, "x"))
	check(text == "axb" and cursor == 2, "typed text inserts at the caret")
	text, cursor = Input.key("ab", 1, key("backspace"))
	check(text == "b" and cursor == 0, "backspace deletes before the caret")
	text, cursor = Input.key("ab", 1, key("left"))
	check(text == "ab" and cursor == 0, "left moves the caret")
	text, cursor = Input.key("ab", 1, key("right"))
	check(text == "ab" and cursor == 2, "right moves the caret")
	for _, name in { "enter", "tab", "escape", "up" } do
		text, cursor = Input.key("ab", 1, key(name))
		check(text == nil and cursor == nil, name .. " is left to the reducer")
	end
	local chord: any = { kind = "key", name = "a", text = "a", ctrl = true }
	text, cursor = Input.key("ab", 1, chord)
	check(text == nil and cursor == nil, "a chord is left to the reducer")
end

-- The caret rule: the caret stays while the line holds the text the host last edited; any other text (a prefill or a
-- refill) puts it at the end, and a closed line forgets it.
do
	local edited: Input.Caret = { cursor = 1, edited = "ab" }
	local same = Input.follow(edited, true, "ab")
	check(same.cursor == 1 and same.edited == "ab", "the caret stays on the text the host edited")
	local refill = Input.follow(edited, true, "xyz")
	check(refill.cursor == nil and refill.edited == "xyz", "other text puts the caret at the end")
	check(Input.follow(refill, true, "xyz").cursor == nil, "and it stays at the end")
	local closed = Input.follow(edited, false, "ab")
	check(closed.cursor == nil and closed.edited == nil, "a closed line forgets the caret")
	local typed, at = Input.key("Auth", nil, key("backspace"))
	check(typed == "Aut" and at == 3, "Backspace at the end deletes the last character")
end

print("Input: " .. checks .. " checks passed")
