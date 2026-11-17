--!strict
-- Agent kind validation and launch command behaviour.

local Agent = require("../lib/shared/agent")
local Identity = require("../lib/shared/identity")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

-- Agent kinds accept their exact grammar and enforce both length boundaries.
check(Agent.OMP == "omp", "the omp kind is exported")
check(Agent.valid_kind("a"), "a one-character alphanumeric kind is valid")
check(Agent.valid_kind("claude_code-2"), "a kind may contain underscores, hyphens and digits after its first character")
check(Agent.valid_kind(string.rep("a", 32)), "a 32-character kind is valid")
check(not Agent.valid_kind(string.rep("a", 33)), "a 33-character kind is refused")
check(not Agent.valid_kind(""), "an empty kind is refused")
check(not Agent.valid_kind("-h"), "a kind may not start with a hyphen")
check(not Agent.valid_kind("_agent"), "a kind may not start with an underscore")
check(not Agent.valid_kind("--continue"), "a flag is refused as a kind")

-- Session ids accept their exact grammar and enforce both length boundaries.
check(Agent.valid_session("a"), "a one-character alphanumeric session id is valid")
check(
	Agent.valid_session("session_2-old"),
	"a session id may contain underscores, hyphens and digits after its first character"
)
check(Agent.valid_session(string.rep("s", 64)), "a 64-character session id is valid")
check(not Agent.valid_session(string.rep("s", 65)), "a 65-character session id is refused")
check(not Agent.valid_session(""), "an empty session id is refused")
check(not Agent.valid_session("-h"), "a session id may not start with a hyphen")
check(not Agent.valid_session("_session"), "a session id may not start with an underscore")
check(not Agent.valid_session("--continue"), "a flag is refused as a session id")

-- Only the four specified launch modes are accepted.
check(Agent.valid_mode("new"), "new is a valid mode")
check(Agent.valid_mode("resume"), "resume is a valid mode")
check(Agent.valid_mode("continue"), "continue is a valid mode")
check(Agent.valid_mode("pick"), "pick is a valid mode")
check(not Agent.valid_mode(""), "an empty mode is refused")
check(not Agent.valid_mode("sessions"), "an unknown mode is refused")

-- Claude and Codex are CLI kinds; omp and ACP kinds are not.
check(Agent.CLAUDE == "claude", "the claude kind is exported")
check(Agent.CODEX == "codex", "the codex kind is exported")
check(Agent.is_cli("claude"), "claude runs as its CLI")
check(Agent.is_cli("codex"), "codex runs as its CLI")
check(not Agent.is_cli("omp"), "omp is not a CLI kind")
check(not Agent.is_cli("copilot"), "copilot stays an ACP kind")
check(not Agent.is_cli("Claude"), "CLI kind matching is case-sensitive")

-- Each ACP launch mode builds its exact command.
check(
	Agent.command("copilot", "agent-1", "new") == "env JUMPR_ID=agent-1 tern acp copilot",
	"new builds the ACP command"
)
check(
	Agent.command("copilot", "agent-1", "resume", "session_2")
		== "env JUMPR_ID=agent-1 tern acp copilot --resume session_2",
	"resume builds the ACP command with its session id"
)
check(
	Agent.command("copilot", "agent-1", "continue") == "env JUMPR_ID=agent-1 tern acp copilot --continue",
	"continue builds the ACP command with its flag"
)
check(
	Agent.command("copilot", "agent-1", "pick") == "env JUMPR_ID=agent-1 tern acp copilot --sessions",
	"pick builds the ACP command with its picker flag"
)
check(Agent.command("copilot", "agent-1", "resume") == nil, "resume without a session id is refused")

-- Claude runs its CLI: new and resume share one line that resumes the owned uuid or creates it, pick opens its
-- picker, and continue is refused because it could open another agent's session.
local UUID_V4 = "123e4567-e89b-42d3-a456-426614174000"
local UUID_V7 = "01928f3a-6b7c-7def-8a12-3456789abcde"
local CLAUDE_OWNED = "env JUMPR_ID=agent-1 sh -c 'claude --resume "
	.. UUID_V4
	.. " || claude --session-id "
	.. UUID_V4
	.. "'"
check(Agent.command("claude", "agent-1", "new", UUID_V4) == CLAUDE_OWNED, "claude new resumes-or-creates its uuid")
check(
	Agent.command("claude", "agent-1", "resume", UUID_V4) == CLAUDE_OWNED,
	"claude resume resumes-or-creates its uuid"
)
check(Agent.command("claude", "agent-1", "continue", UUID_V4) == nil, "claude continue is refused")
check(Agent.command("claude", "agent-1", "continue") == nil, "claude continue without a session is refused")
check(
	Agent.command("claude", "agent-1", "pick") == "env JUMPR_ID=agent-1 claude --resume",
	"claude pick opens its picker"
)
check(Agent.command("claude", "agent-1", "new") == nil, "claude new without a uuid is refused")
check(Agent.command("claude", "agent-1", "resume") == nil, "claude resume without a uuid is refused")

-- Codex runs its CLI: new starts fresh, resume reopens the recorded thread uuid, pick opens its picker.
check(Agent.command("codex", "agent-1", "new") == "env JUMPR_ID=agent-1 codex", "codex new starts its CLI")
check(
	Agent.command("codex", "agent-1", "resume", UUID_V7) == "env JUMPR_ID=agent-1 codex resume " .. UUID_V7,
	"codex resume reopens its v7 thread uuid"
)
check(Agent.command("codex", "agent-1", "continue") == nil, "codex continue is refused")
check(Agent.command("codex", "agent-1", "pick") == "env JUMPR_ID=agent-1 codex resume", "codex pick opens its picker")
check(Agent.command("codex", "agent-1", "resume") == nil, "codex resume without a uuid is refused")

-- CLI session ids must be canonical lowercase uuids; anything else, shell syntax especially, is refused.
local NOT_UUIDS = {
	"session_2",
	"123E4567-E89B-42D3-A456-426614174000",
	"123e4567e89b42d3a456426614174000",
	"123e4567-e89b-42d3-a456-42661417400",
	"123e4567-e89b-42d3-a456-426614174000 ",
	"123e4567-e89b-42d3-a456 426614174000",
	"123e4567-e89b-42d3-a456-426614174000;rm",
	"123e4567-e89b-42d3-a456-426614174000'",
	"'123e4567-e89b-42d3-a456-426614174000",
	'123e4567-e89b-42d3-a456-426614174000"',
	"--continue",
	"",
}
for _, value in NOT_UUIDS do
	check(Agent.command("claude", "agent-1", "new", value) == nil, "claude new refuses a non-uuid: " .. value)
	check(Agent.command("claude", "agent-1", "resume", value) == nil, "claude resume refuses a non-uuid: " .. value)
	check(Agent.command("codex", "agent-1", "resume", value) == nil, "codex resume refuses a non-uuid: " .. value)
end

-- Omp keeps its byte-identical command for every supported mode.
local OMP_COMMAND = "omp --continue --session-dir ~/.omp/deck/agent-1"
check(Agent.command("omp", "agent-1", "new") == OMP_COMMAND, "omp ignores new mode")
check(Agent.command("omp", "agent-1", "resume") == OMP_COMMAND, "omp ignores resume mode and its absent session id")
check(Agent.command("omp", "agent-1", "continue") == OMP_COMMAND, "omp ignores continue mode")
check(Agent.command("omp", "agent-1", "pick") == OMP_COMMAND, "omp ignores pick mode")

-- Kind, id and resumed-session shell syntax is refused instead of entering a command.
local UNSAFE = { "a b", "a;b", "a$b", "a/b" }
for _, value in UNSAFE do
	check(Agent.command(value, "agent1", "new") == nil, "an unsafe kind is refused: " .. value)
	check(Agent.command("copilot", value, "new") == nil, "an unsafe agent id is refused: " .. value)
	check(Agent.command("copilot", "agent1", "resume", value) == nil, "an unsafe session id is refused: " .. value)
	check(Agent.command("claude", value, "new", UUID_V4) == nil, "an unsafe claude agent id is refused: " .. value)
	check(Agent.command("codex", value, "new") == nil, "an unsafe codex agent id is refused: " .. value)
end
check(Agent.command("--continue", "agent1", "new") == nil, "a flag is refused as a command kind")
check(Agent.command("-h", "agent1", "new") == nil, "a short flag is refused as a command kind")
check(Agent.command("copilot", "agent1", "resume", "--continue") == nil, "a flag is refused as a resumed session id")
check(Agent.command("copilot", "agent1", "resume", "-h") == nil, "a short flag is refused as a resumed session id")

-- Every kind on offer, in every mode, with or without a uuid, builds nil or a line made only of fixed words, offered
-- kinds, the validated id and the validated uuid; quotes appear only as the one pair around the composite claude part.
local VOCABULARY: { [string]: boolean } = {
	env = true,
	sh = true,
	["-c"] = true,
	claude = true,
	codex = true,
	omp = true,
	tern = true,
	acp = true,
	resume = true,
	["--resume"] = true,
	["--session-id"] = true,
	["--continue"] = true,
	["--sessions"] = true,
	["--session-dir"] = true,
	["||"] = true,
	["JUMPR_ID=agent-1"] = true,
	["~/.omp/deck/agent-1"] = true,
	-- The validated ACP session id, which only ACP kinds may carry.
	session_2 = true,
	[UUID_V4] = true,
}
local offered = Agent.options("x")
for _, kind in offered do
	VOCABULARY[kind] = true
end
local swept = 0
for _, kind in offered do
	for _, mode: Agent.Mode in { "new", "resume", "continue", "pick" } :: { Agent.Mode } do
		for _, case in
			{ { sid = UUID_V4 }, { sid = nil }, { sid = "x' ; echo canary '" }, { sid = "session_2" } } :: { { sid: string? } }
		do
			local line = Agent.command(kind, "agent-1", mode, case.sid)
			if line ~= nil then
				swept += 1
				check(
					case.sid ~= "session_2"
						or not Agent.is_cli(kind)
						or mode == "pick"
						or (kind == "codex" and mode == "new"),
					"a CLI kind never carries a non-uuid session id: " .. line
				)
				local _, quotes = string.gsub(line, "'", "")
				local composite = string.find(line, " sh -c 'claude ", 1, true) ~= nil
				check(quotes == (if composite then 2 else 0), "only the composite claude part is quoted: " .. line)
				check(
					not composite or string.sub(line, -1) == "'",
					"the composite claude part closes its quotes at the end: " .. line
				)
				for token in string.gmatch(line, "%S+") do
					local word = string.gsub(token, "^'", "")
					word = string.gsub(word, "'$", "")
					check(
						VOCABULARY[word] == true,
						"a launch token is from the fixed vocabulary: " .. token .. " in " .. line
					)
				end
			end
		end
	end
end
check(swept > 0, "the invariant sweep built at least one line")

-- Names preserve ACP ids and omp's established spelling.
check(Agent.name("omp") == "omp", "omp keeps its default name")
check(Agent.name("copilot") == "copilot", "an ACP kind is its default name")
check(Agent.name("claude") == "claude", "a CLI kind is its default name")
check(Agent.name("my-agent") == "my-agent", "a custom ACP kind keeps its exact spelling")

-- Only exact built-in titles are recognised as defaults.
for _, title in { "omp", "Claude Code", "Codex", "GitHub Copilot" } do
	check(Agent.is_default_title(title), title .. " is a default title")
end
check(not Agent.is_default_title("omp 2"), "a numbered omp title is not a default title")
check(not Agent.is_default_title(""), "an empty title is not a default title")
check(not Agent.is_default_title("claude code"), "default title matching is case-sensitive")
-- For codex a title with no ` | ` is its folder-only default; a thread title is `<title> | <folder>`.
check(Agent.is_default_title("probe-repo", "codex"), "a codex folder-only title is a default title")
check(Agent.is_default_title("Codex", "codex"), "Codex is still a default title for codex")
check(not Agent.is_default_title("Count to 400 | probe-repo", "codex"), "a codex thread title is not a default title")
check(not Agent.is_default_title("", "codex"), "an empty codex title is not a default title")
for _, kind in { "omp", "claude", "copilot" } do
	check(not Agent.is_default_title("probe-repo", kind), "a bare word is not a default title for " .. kind)
end
check(not Agent.is_default_title("probe-repo"), "a bare word is not a default title without a kind")

-- Commands carry an identity that the shared matcher recovers without accepting other text.
local omp_id = Identity.match(Agent.command("omp", "roundtrip-1", "new") :: string)
check(omp_id == "roundtrip-1", "an omp command round-trips its agent id through identity matching")
local acp_id = Identity.match(Agent.command("copilot", "roundtrip-2", "continue") :: string)
check(acp_id == "roundtrip-2", "an ACP command round-trips its agent id through identity matching")
for _, case in
	{
		{ kind = "claude", mode = "new", sid = UUID_V4 },
		{ kind = "claude", mode = "resume", sid = UUID_V4 },
		{ kind = "claude", mode = "pick" },
		{ kind = "codex", mode = "new" },
		{ kind = "codex", mode = "resume", sid = UUID_V7 },
		{ kind = "codex", mode = "pick" },
	} :: { { kind: string, mode: Agent.Mode, sid: string? } }
do
	local line = Agent.command(case.kind, "roundtrip-3", case.mode, case.sid)
	check(line ~= nil, "a CLI command is built for " .. case.kind .. " " .. case.mode)
	check(
		Identity.match(line :: string) == "roundtrip-3",
		"a CLI command round-trips its agent id through identity matching: " .. case.kind .. " " .. case.mode
	)
end

print("Agent: " .. checks .. " checks passed")
