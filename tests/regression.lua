-- Run from the repository root with Lua 5.1+: lua tests/regression.lua
-- WoW APIs are mocked; this does not emulate the client's secret-value engine.
local realPrint = print
local state, eventFrame
local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end
local function widget(name)
    local w = { name = name, scripts = {} }
    return setmetatable(w, { __index = function(_, key)
        if key == "SetScript" then return function(self, k, fn) self.scripts[k] = fn end end
        if key == "GetName" then return function(self) return self.name end end
        if key == "CreateFontString" then return function() return widget() end end
        if key == "GetID" then return function() return 1 end end
        return function() end
    end })
end
local function emit(event, ...)
    eventFrame.scripts.OnEvent(eventFrame, event, ...)
end
local function advance(seconds)
    local target = state.now + seconds
    while true do
        local chosen
        for _, timer in ipairs(state.timers) do
            if not timer.cancelled and timer.at <= target and (not chosen or timer.at < chosen.at) then
                chosen = timer
            end
        end
        if not chosen then break end
        state.now = chosen.at
        if chosen.interval then chosen.at = chosen.at + chosen.interval else chosen.cancelled = true end
        chosen.fn()
    end
    state.now = target
end
local function init(db)
    state = { now = 1000, solo = false, ignores = {}, units = {}, timers = {}, guild = {}, messages = {}, deletes = {} }
    SSBlockerDB = db
    UIParent = widget()
    UNKNOWN = "Unknown"
    SlashCmdList = {}
    print = function(msg) table.insert(state.messages, msg) end
    wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    canaccessvalue = function(v) return state.secret == nil or v ~= state.secret end
    CreateFrame = function(_, name)
        local w = widget(name)
        if not eventFrame or name == nil then eventFrame = w end
        if name then
            _G[name] = w
            for _, suffix in ipairs({"Low", "High", "Text"}) do _G[name .. suffix] = widget() end
        end
        return w
    end
    GetRealmName = function() return "Home Realm" end
    UnitName = function() return "Me", "HomeRealm" end
    UnitExists = function(unit) return state.units[unit] ~= nil end
    UnitIsUnit = function(a, b) return a == b end
    GetUnitName = function(unit) return state.units[unit].name end
    UnitGUID = function(unit) return state.units[unit].guid end
    IsInRaid = function() return false end
    GetNumSubgroupMembers = function() return state.partyCount or 2 end
    GetTime = function() return state.now end
    time = GetTime
    IsInGuild = function() return state.inGuild or false end
    GetNumGuildMembers = function() return #state.guild end
    GetGuildRosterInfo = function(i)
        local p = state.guild[i]
        return p.name, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, p.guid
    end
    C_GuildInfo = { GuildRoster = function() state.guildRequests = (state.guildRequests or 0) + 1 end }
    C_PvP = {
        IsSoloShuffle = function() return state.solo end,
        IsRatedSoloShuffle = function() return state.solo end,
        GetScoreInfo = function(i) return (state.scores or {})[i] end,
    }
    local function key(name)
        name = name:gsub("%s+", "")
        if not name:find("-", 1, true) then name = name .. "-HomeRealm" end
        return name:lower()
    end
    C_FriendList = {
        IsFriend = function(guid) return guid == "Player-Friend" end,
        GetNumIgnores = function() return count(state.ignores) end,
        IsIgnored = function(name)
            if state.unavailable then return nil end
            return state.ignores[key(name)] == true
        end,
        AddIgnore = function(name)
            if state.addError then error("API not ready") end
            if state.addFail or count(state.ignores) >= 40 then return false end
            state.ignores[key(name)] = true
            return true
        end,
        DelIgnore = function(name)
            table.insert(state.deletes, name)
            if state.delFail then return false end
            local existed = state.ignores[key(name)]
            state.ignores[key(name)] = nil
            return existed == true
        end,
        GetIgnoreName = function(i)
            if state.ignoreNames then return state.ignoreNames[i] end
            local keys = {}
            for name in pairs(state.ignores) do table.insert(keys, name) end
            table.sort(keys)
            return keys[i]
        end,
    }
    C_Timer = {}
    C_Timer.NewTimer = function(delay, fn)
        local timer = {at = state.now + delay, fn = fn, Cancel = function(self) self.cancelled = true end}
        table.insert(state.timers, timer)
        return timer
    end
    C_Timer.After = C_Timer.NewTimer
    C_Timer.NewTicker = function(delay, fn)
        local timer = C_Timer.NewTimer(delay, fn)
        timer.interval = delay
        return timer
    end
    Settings = { RegisterCanvasLayoutCategory = function() return widget() end, RegisterAddOnCategory = function() end }
    assert(loadfile(ADDON_SOURCE or "SoloShuffleBlocker.lua"))("SoloShuffleBlocker", {})
    emit("ADDON_LOADED", "SoloShuffleBlocker")
end
local function player(unit, name, guid)
    state.units[unit] = { name = name, guid = guid or "Player-" .. unit }
end
local function enter()
    state.solo = true
    emit("PLAYER_ENTERING_WORLD")
end
local function leave()
    state.solo = false
    emit("PLAYER_ENTERING_WORLD")
end
local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; realPrint("PASS " .. name)
    else failed = failed + 1; realPrint("FAIL " .. name .. ": " .. tostring(err)) end
end

test("failed AddIgnore is never recorded as a success", function()
    init(); state.addFail = true; player("party1", "Other"); enter()
    assert(count(SSBlockerDB.blockedDict) == 0)
    state.addFail = false; advance(2)
    assert(count(SSBlockerDB.blockedDict) == 1)
end)
test("same name on another realm is not mistaken for self", function()
    init(); player("party1", "Me-OtherRealm"); enter()
    assert(state.ignores["me-otherrealm"])
end)
test("permanent ignores and friends remain protected", function()
    init(); state.ignores["permanent-homerealm"] = true
    player("party1", "Permanent"); player("party2", "Friend", "Player-Friend"); enter()
    assert(count(SSBlockerDB.blockedDict) == 0)
    SlashCmdList.SSBLOCKER("unblock")
    assert(state.ignores["permanent-homerealm"])
end)
test("unblock does not touch an identically named other-realm ignore", function()
    init({blockedDict = {Twin = true}, blockedQueue = {"Twin"}})
    state.ignores["twin-homerealm"] = true; state.ignores["twin-otherrealm"] = true
    state.ignoreNames = {"Twin-HomeRealm", "Twin-OtherRealm"}
    SlashCmdList.SSBLOCKER("unblock")
    assert(not state.ignores["twin-homerealm"] and state.ignores["twin-otherrealm"])
end)
test("manual unblock cancels the timer before a new match", function()
    init(); player("party1", "First"); enter(); leave(); advance(20)
    SlashCmdList.SSBLOCKER("unblock"); player("party1", "Second"); enter(); advance(281)
    assert(state.ignores["second-homerealm"])
end)
test("expired login cleanup cannot clear a newly entered match", function()
    init({blockedDict = {Old = true}, blockedQueue = {"Old"}, unblockTimestamp = 1})
    state.ignores["old-homerealm"] = true; emit("PLAYER_ENTERING_WORLD")
    player("party1", "New"); enter(); advance(2)
    assert(state.ignores["new-homerealm"])
    for _, name in ipairs(state.deletes) do
        assert(name ~= "New" and name ~= "New-HomeRealm", "old login timer removed a new match ignore")
    end
end)
test("reload in a match preserves temporary ignores", function()
    init({blockedDict = {Old = true}, blockedQueue = {"Old"}, wasInSoloShuffle = true})
    state.ignores["old-homerealm"] = true; enter()
    assert(state.ignores["old-homerealm"] and #state.deletes == 0)
end)
test("asynchronous guild roster protects guildmates then scans opponents", function()
    init(); state.inGuild = true
    player("party1", "Guildmate", "Player-Guild"); player("party2", "Opponent"); enter()
    assert(count(SSBlockerDB.blockedDict) == 0)
    state.guild = {{name = "Guildmate-HomeRealm", guid = "Player-Guild"}}
    emit("GUILD_ROSTER_UPDATE")
    assert(not state.ignores["guildmate-homerealm"] and state.ignores["opponent-homerealm"])
    assert(state.guildRequests == 1)
end)
test("failed removal retains ownership for retry", function()
    init(); player("party1", "Other"); enter(); state.delFail = true
    SlashCmdList.SSBLOCKER("unblock")
    assert(count(SSBlockerDB.blockedDict) == 1)
    state.delFail = false; SlashCmdList.SSBLOCKER("unblock")
    assert(count(SSBlockerDB.blockedDict) == 0)
end)
test("players loading after initial scan window are discovered", function()
    init(); enter(); advance(25); player("party1", "Late"); advance(2)
    assert(state.ignores["late-homerealm"])
end)
test("leave timer honors configured delay", function()
    init({unblockDelay = 1}); player("party1", "Other"); enter(); leave(); advance(59)
    assert(state.ignores["other-homerealm"]); advance(1)
    assert(count(state.ignores) == 0 and count(SSBlockerDB.blockedDict) == 0)
end)
test("test command ignores expire outside a match", function()
    init({unblockDelay = 1}); player("party1", "Other"); SlashCmdList.SSBLOCKER("test")
    assert(state.ignores["other-homerealm"]); advance(60)
    assert(count(state.ignores) == 0)
end)
test("expired deadline is not extended by logout", function()
    init({blockedDict = {Old = true}, unblockTimestamp = 1}); emit("PLAYER_LOGOUT")
    assert(SSBlockerDB.unblockTimestamp == 1)
end)
test("disabled mode never adds ignores", function()
    init({enabled = false}); player("party1", "Other"); enter(); advance(30)
    assert(count(state.ignores) == 0)
end)
test("secret names and GUIDs are skipped", function()
    init(); state.secret = {}; player("party1", state.secret); player("party2", "Other", state.secret); enter()
    assert(count(state.ignores) == 0)
end)
test("full permanent list is preserved and unsuccessful additions are not tracked", function()
    init(); for i = 1, 40 do state.ignores["permanent" .. i .. "-homerealm"] = true end
    player("party1", "Other"); enter(); advance(4)
    assert(count(state.ignores) == 40 and count(SSBlockerDB.blockedDict) == 0 and #state.deletes == 0)
end)
test("all five other players are collected across rounds", function()
    init(); player("party1", "One"); player("party2", "Two"); enter()
    player("party1", "Three"); player("party2", "Four"); advance(2)
    player("party1", "Five"); advance(2)
    assert(count(SSBlockerDB.blockedDict) == 5)
end)
test("scoreboard fallback skips self and blocks known players", function()
    init(); state.scores = {{name = "Me-HomeRealm", guid = "Player-Me"}, {name = "ScorePlayer", guid = "Player-Score"}}
    enter(); emit("UPDATE_BATTLEFIELD_SCORE"); advance(2)
    assert(count(SSBlockerDB.blockedDict) == 1 and state.ignores["scoreplayer-homerealm"])
end)
test("login resumes only the remaining delay", function()
    init({blockedDict = {Old = true}, unblockTimestamp = 1030})
    state.ignores["old-homerealm"] = true; emit("PLAYER_ENTERING_WORLD"); advance(29)
    assert(state.ignores["old-homerealm"]); advance(1); assert(count(state.ignores) == 0)
end)
test("unavailable friend list does not lose saved ownership", function()
    init({blockedDict = {Old = true}}); state.delFail = true; state.unavailable = true
    SlashCmdList.SSBLOCKER("unblock"); assert(count(SSBlockerDB.blockedDict) == 1)
end)
test("API exceptions are recoverable on subsequent scans", function()
    init(); state.addError = true; player("party1", "Other"); enter()
    assert(count(SSBlockerDB.blockedDict) == 0)
    state.addError = false; advance(2); assert(state.ignores["other-homerealm"])
end)
realPrint(string.format("%d passed, %d failed", passed, failed))
assert(failed == 0, "Regression tests failed")
