--!strict
-- Pure session identity coherence for copies.luau.

local M = {}

-- Tabs are usable only when all three views of the current session identify the same generation.
function M.coherent_tabs(host: ManagedHost, session: ManagedSession, sessions: { SessionInfo }): { number }?
	if session.host ~= host.id then
		return nil
	end
	local hosted = false
	for _, id in host.sessions do
		if id == session.id then
			hosted = true
			break
		end
	end
	if not hosted then
		return nil
	end
	for _, item in sessions do
		if item.id == session.id then
			return item.tabs
		end
	end
	return nil
end

return M
