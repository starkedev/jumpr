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

-- Each ACP launch mode builds its exact command.
check(Agent.command("claude", "agent-1", "new") == "env JUMPR_ID=agent-1 tern acp claude", "new builds the ACP command")
check(
	Agent.command("claude", "agent-1", "resume", "session_2")
		== "env JUMPR_ID=agent-1 tern acp claude --resume session_2",
	"resume builds the ACP command with its session id"
)
check(
	Agent.command("claude", "agent-1", "continue") == "env JUMPR_ID=agent-1 tern acp claude --continue",
	"continue builds the ACP command with its flag"
)
check(
	Agent.command("claude", "agent-1", "pick") == "env JUMPR_ID=agent-1 tern acp claude --sessions",
	"pick builds the ACP command with its picker flag"
)
check(Agent.command("claude", "agent-1", "resume") == nil, "resume without a session id is refused")

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
	check(Agent.command("claude", value, "new") == nil, "an unsafe agent id is refused: " .. value)
	check(Agent.command("claude", "agent1", "resume", value) == nil, "an unsafe session id is refused: " .. value)
end
check(Agent.command("--continue", "agent1", "new") == nil, "a flag is refused as a command kind")
check(Agent.command("-h", "agent1", "new") == nil, "a short flag is refused as a command kind")
check(Agent.command("claude", "agent1", "resume", "--continue") == nil, "a flag is refused as a resumed session id")
check(Agent.command("claude", "agent1", "resume", "-h") == nil, "a short flag is refused as a resumed session id")

-- Names preserve ACP ids and omp's established spelling.
check(Agent.name("omp") == "omp", "omp keeps its default name")
check(Agent.name("claude") == "claude", "an ACP kind is its default name")
check(Agent.name("my-agent") == "my-agent", "a custom ACP kind keeps its exact spelling")

-- Only exact built-in titles are recognised as defaults.
for _, title in { "omp", "Claude Code", "Codex", "GitHub Copilot" } do
	check(Agent.is_default_title(title), title .. " is a default title")
end
check(not Agent.is_default_title("omp 2"), "a numbered omp title is not a default title")
check(not Agent.is_default_title(""), "an empty title is not a default title")
check(not Agent.is_default_title("claude code"), "default title matching is case-sensitive")

-- Commands carry an identity that the shared matcher recovers without accepting other text.
local omp_id = Identity.match(Agent.command("omp", "roundtrip-1", "new") :: string)
check(omp_id == "roundtrip-1", "an omp command round-trips its agent id through identity matching")
local acp_id = Identity.match(Agent.command("claude", "roundtrip-2", "continue") :: string)
check(acp_id == "roundtrip-2", "an ACP command round-trips its agent id through identity matching")

print("Agent: " .. checks .. " checks passed")
