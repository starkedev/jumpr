--!strict

local Transport = require("../lib/host/transport")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local T = 100000

-- live_hosts: the names every window heard within the last minute gives the host, over every copy.
do
	local state = Transport.new()
	local a = Transport.new_status()
	local b = Transport.new_status()
	Transport.register(state, a)
	Transport.register(state, b)
	a.windows.linux = { seq = 1, at_ms = T, a = {}, carried = {}, hn = "devbox" }
	b.windows.mac = { seq = 1, at_ms = T - 30000, a = {}, carried = {}, hn = "me@devbox" }
	b.windows.old = { seq = 1, at_ms = T - 60000, a = {}, carried = {}, hn = "gone" }
	b.windows.quiet = { seq = 1, at_ms = T, a = {}, carried = {} }
	local live = Transport.live_hosts(state, T)
	check(live.devbox == true and live["me@devbox"] == true, "both machines' names for the host are live")
	check(live.gone == nil, "a window silent for a minute no longer holds its name")
	local count = 0
	for _ in live do
		count += 1
	end
	check(count == 2, "a window that sent no name adds none")
	Transport.unregister(state, b)
	check(Transport.live_hosts(state, T)["me@devbox"] == nil, "a dropped copy's windows no longer count")
end

-- settled: a minute after the first status message since the host half started.
do
	local state = Transport.new()
	check(not Transport.settled(state, T), "before any status the host is not settled")
	state.since = T
	check(not Transport.settled(state, T + 59999), "under a minute it is not")
	check(Transport.settled(state, T + 60000), "a minute after the first status it is")
end

print("Transport: " .. checks .. " checks passed")
