local addonName, addon = ...
local frame = CreateFrame("Frame")
SSBlockerDB = SSBlockerDB or { unblockDelay = 5, enabled = true }
local unblockTimer = nil
local inSoloShuffle = false
local isTestMode = false
local optionsPanel
local UpdateBlockListDisplay
local toggleButton
local scanTicker

local function IsSecret(val)
    if canaccessvalue then
        return not canaccessvalue(val)
    elseif issecretvalue then
        return issecretvalue(val)
    end
    return false
end

-- Keep the realm in every identity, including same-realm names.
local function FullName(name)
    if IsSecret(name) or type(name) ~= "string" or name == "" then return nil end
    name = name:gsub("%s+", "")
    if not name:find("-", 1, true) then
        name = name .. "-" .. GetRealmName():gsub("%s+", "")
    end
    return name
end

local function CancelUnblockTimer()
    if unblockTimer then unblockTimer:Cancel() end
    unblockTimer = nil
end

local function UpdateButtonVisibility()
    if toggleButton then
        if inSoloShuffle or isTestMode then
            toggleButton:Show()
        else
            toggleButton:Hide()
        end
    end
end

local function UpdateButtonState()
    if not toggleButton then return end
    if SSBlockerDB and SSBlockerDB.enabled then
        toggleButton:SetText("SS 차단: ON")
    else
        toggleButton:SetText("SS 차단: OFF")
    end
end

local function GetBlockedQueue()
    if not SSBlockerDB then return {} end
    SSBlockerDB.blockedQueue = SSBlockerDB.blockedQueue or {}
    return SSBlockerDB.blockedQueue
end

local function GetBlockedDict()
    if not SSBlockerDB then return {} end
    SSBlockerDB.blockedDict = SSBlockerDB.blockedDict or {}
    return SSBlockerDB.blockedDict
end

local function GetBlockedCount()
    local count = 0
    local dict = GetBlockedDict()
    for _ in pairs(dict) do
        count = count + 1
    end
    return count
end

-- Helper to safely get the number of scoreboard entries
local function GetNumScores()
    if GetNumBattlefieldScores then
        local count = GetNumBattlefieldScores()
        if not IsSecret(count) and count and count > 0 then return count end
    end
    -- Fallback: Solo Shuffle has up to 6 players, safe to check up to 6 without infinite loop
    return 6
end

-- Helper to print messages
local function Print(msg)
    print("|cFF00FF00[SSBlocker]|r " .. msg)
end

local function SafeCall(fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok and SSBlockerDB.debug then
        Print("API 오류: " .. tostring(result))
    end
    return ok, result
end

-- A failed API call must not discard ownership of a temporary ignore.
local function RemoveTracked(name)
    local ok, removed = SafeCall(C_FriendList.DelIgnore, name)
    if ok and removed == true then
        GetBlockedDict()[name] = nil
        return true
    end
    local checked, ignored = SafeCall(C_FriendList.IsIgnored, name)
    if checked and ignored == false then
        GetBlockedDict()[name] = nil
        return true
    end
    return false
end

local function UnblockOldest(count)
    local queue = GetBlockedQueue()
    local dict = GetBlockedDict()
    local unblocked = 0
    local index = 1
    while unblocked < count and index <= #queue do
        local oldestName = queue[index]
        if not dict[oldestName] then
            table.remove(queue, index)
        elseif RemoveTracked(oldestName) then
            table.remove(queue, index)
            unblocked = unblocked + 1
        else
            index = index + 1
        end
    end
    if unblocked > 0 then
        Print("차단 목록 여유 공간 확보를 위해 오래된 임시 차단 " .. unblocked .. "명을 사전 자동 해제했습니다.")
    end
end

-- Function to unblock players tracked by this addon
local function UnblockAll()
    CancelUnblockTimer()
    local count = 0
    local dict = GetBlockedDict()
    for name in pairs(dict) do
        if RemoveTracked(name) then count = count + 1 end
    end
    local queue = GetBlockedQueue()
    for i = #queue, 1, -1 do
        if not dict[queue[i]] then table.remove(queue, i) end
    end
    if next(dict) == nil then
        SSBlockerDB.unblockTimestamp = nil
    else
        -- Keep failed removals for a later retry/relogin.
        SSBlockerDB.unblockTimestamp = time()
        Print("일부 임시 차단을 해제하지 못했습니다. /ssb unblock으로 다시 시도할 수 있습니다.")
    end
    if UpdateBlockListDisplay then UpdateBlockListDisplay() end
    if count > 0 then
        Print(count .. "명의 플레이어를 차단 해제했습니다.")
    end
end

-- Helper to check if a unit (by GUID) is in the player's guild
local guildMemberGuids = {}
local guildMemberNames = {}
local guildCacheReady = false

local function UpdateGuildCache()
    wipe(guildMemberGuids)
    wipe(guildMemberNames)
    guildCacheReady = not IsInGuild()
    if guildCacheReady then return end
    
    local numMembers = GetNumGuildMembers()
    guildCacheReady = numMembers > 0
    for i = 1, numMembers do
        local name, _, _, _, _, _, _, _, online, _, _, _, _, _, _, _, guid = GetGuildRosterInfo(i)
        if not IsSecret(guid) and guid then
            guildMemberGuids[guid] = true
        end
        local fullName = FullName(name)
        if fullName then guildMemberNames[fullName:lower()] = true end
    end
end

local function IsSameGuild(targetGuid)
    if IsSecret(targetGuid) or not targetGuid then return false end
    return guildMemberGuids[targetGuid]
end

-- Helper to attempt blocking a single player by name and guid
local function TryBlockPlayer(name, guid, isManualTest)
    if IsSecret(name) then return false end
    if not name or name == "" or name == UNKNOWN or name == "Unknown" or name == "알 수 없음" then return false end
    if not inSoloShuffle and not isManualTest then return false end
    if SSBlockerDB and SSBlockerDB.enabled == false and not isManualTest then return false end

    local cleanName = FullName(name)
    if not cleanName then return false end

    local dict = GetBlockedDict()
    for tracked in pairs(dict) do
        if tracked:lower() == cleanName:lower() then return false end
    end

    local myName, myRealm = UnitName("player")
    if not myRealm or myRealm == "" then myRealm = GetRealmName() end
    
    local myFullName = FullName(myName .. "-" .. myRealm):lower()
    if cleanName:lower() == myFullName then return false end
    if not guildCacheReady or guildMemberNames[cleanName:lower()] then return false end

    -- Defer identities we cannot inspect; a later roster scan can retry safely.
    if IsSecret(guid) or not guid then return false end
    if guid then
        if not string.match(guid, "^Player%-") then return false end
        -- Check if guild member
        if IsSameGuild(guid) then return false end
        -- Check if friend
        if C_FriendList.IsFriend and C_FriendList.IsFriend(guid) then return false end
    end

    -- Check if already ignored permanently by the user
    if C_FriendList.IsIgnored(cleanName) then return false end

    local numIgnores = C_FriendList.GetNumIgnores and C_FriendList.GetNumIgnores() or 0
    if numIgnores >= 40 and #GetBlockedQueue() > 0 then
        UnblockOldest(6)
    end

    local ok, added = SafeCall(C_FriendList.AddIgnore, cleanName)

    if ok and added == true then
        local queue = GetBlockedQueue()
        dict[cleanName] = true
        table.insert(queue, cleanName)
        Print("차단됨: " .. cleanName)
        
        if UpdateBlockListDisplay then
            UpdateBlockListDisplay()
        end
        return true
    else
        if SSBlockerDB and SSBlockerDB.debug then
            Print("차단 실패 (" .. cleanName .. "): " .. tostring(added))
        end
        return false
    end
end

-- Block players using group roster (works at match start)
local lastGroupScan = 0
local function BlockFromGroup(force, isManualTest)
    if not inSoloShuffle and not isManualTest then return end
    if SSBlockerDB and SSBlockerDB.enabled == false and not isManualTest then return end
    if not isManualTest and not force and GetBlockedCount() >= 5 then return end

    local now = GetTime()
    if not force and (now - lastGroupScan < 0.5) then return end
    lastGroupScan = now

    SafeCall(function()
        if IsInRaid() then
            local numGroup = GetNumGroupMembers()
            for i = 1, numGroup do
                local unit = "raid" .. i
                if UnitExists(unit) and not UnitIsUnit(unit, "player") then
                    local name = GetUnitName(unit, true)
                    local guid = UnitGUID(unit)
                    if not IsSecret(name) and name then
                        SafeCall(TryBlockPlayer, name, guid, isManualTest)
                        if not isManualTest and not force and GetBlockedCount() >= 5 then return end
                    end
                end
            end
        else
            local numGroup = GetNumSubgroupMembers()
            for i = 1, numGroup do
                local unit = "party" .. i
                if UnitExists(unit) then
                    local name = GetUnitName(unit, true)
                    local guid = UnitGUID(unit)
                    if not IsSecret(name) and name then
                        SafeCall(TryBlockPlayer, name, guid, isManualTest)
                        if not isManualTest and not force and GetBlockedCount() >= 5 then return end
                    end
                end
            end
        end

        -- Also try arena opponent units (arena1 ~ arena6)
        for i = 1, 6 do
            local unit = "arena" .. i
            if UnitExists(unit) then
                local name = GetUnitName(unit, true)
                local guid = UnitGUID(unit)
                if not IsSecret(name) and name then
                    SafeCall(TryBlockPlayer, name, guid, isManualTest)
                    if not isManualTest and not force and GetBlockedCount() >= 5 then return end
                end
            end
        end
    end)
end

-- Auto-scan when party size becomes 3 (match/round setup)
local prevPartyMembersCount = 0
local function CheckPartyThreeMembers()
    if not inSoloShuffle then return end
    if SSBlockerDB and SSBlockerDB.enabled == false then return end

    local currentCount = 0
    if IsInRaid() then
        currentCount = GetNumGroupMembers()
    else
        currentCount = GetNumSubgroupMembers() + 1
    end

    if currentCount == 3 and prevPartyMembersCount ~= 3 then
        Print("파티원 3명 구성 확인. 자동 차단 스캔을 즉시 실행합니다.")
        BlockFromGroup(true)
        C_Timer.After(0.5, function()
            if inSoloShuffle then BlockFromGroup(true) end
        end)
        C_Timer.After(1.5, function()
            if inSoloShuffle then BlockFromGroup(true) end
        end)
    end
    prevPartyMembersCount = currentCount
end

-- Block using scoreboard (fallback, works at match end)
local lastScoreScan = 0
local function BlockFromScoreboard(isManualTest)
    if not inSoloShuffle and not isManualTest then return end
    if SSBlockerDB and SSBlockerDB.enabled == false and not isManualTest then return end
    if not isManualTest and GetBlockedCount() >= 5 then return end

    local now = GetTime()
    if (now - lastScoreScan < 2.0) then return end
    lastScoreScan = now

    SafeCall(function()
        local numScores = GetNumScores()
        for i = 1, numScores do
            local scoreInfo = C_PvP.GetScoreInfo(i)
            if not IsSecret(scoreInfo) and scoreInfo then
                SafeCall(TryBlockPlayer, scoreInfo.name, scoreInfo.guid, isManualTest)
                if not isManualTest and GetBlockedCount() >= 5 then return end
            end
        end
    end)
end

-- Helper to check if currently inside Solo Shuffle
local function CheckSoloShuffle()
    if C_PvP and C_PvP.IsSoloShuffle and C_PvP.IsSoloShuffle() then
        return true
    end
    if C_PvP and C_PvP.IsRatedSoloShuffle and C_PvP.IsRatedSoloShuffle() then
        return true
    end
    return false
end

-- Update Solo Shuffle state and trigger start/stop actions
local function UpdateSoloShuffleState()
    local isSoloShuffle = CheckSoloShuffle()
    
    if isSoloShuffle and not inSoloShuffle then
        -- ENTERING Solo Shuffle
        inSoloShuffle = true
        prevPartyMembersCount = 0
        lastGroupScan = -math.huge
        lastScoreScan = -math.huge
        UpdateButtonVisibility()
        
        -- If we have a pending unblock timer or old blocks, clear them now to start fresh
        CancelUnblockTimer()
        -- A reload/reconnect inside the same match must retain its ignores.
        if not SSBlockerDB.wasInSoloShuffle then UnblockAll() end
        SSBlockerDB.wasInSoloShuffle = true
        SSBlockerDB.unblockTimestamp = nil
        
        Print("솔로 셔플 진입 확인. 플레이어 차단을 시작합니다.")
        
        UpdateGuildCache() -- Cache guild members to avoid blocking them
        if IsInGuild() then C_GuildInfo.GuildRoster() end
        if scanTicker then scanTicker:Cancel() end
        scanTicker = C_Timer.NewTicker(2, function()
            if inSoloShuffle and SSBlockerDB.enabled then
                BlockFromGroup(true)
                BlockFromScoreboard()
            end
        end)
        
        -- The ticker also covers late loads and later rounds.
        if SSBlockerDB and SSBlockerDB.enabled then
            BlockFromGroup(true)
        end
        
    elseif not isSoloShuffle and inSoloShuffle then
        -- LEAVING Solo Shuffle
        inSoloShuffle = false
        SSBlockerDB.wasInSoloShuffle = false
        if scanTicker then scanTicker:Cancel(); scanTicker = nil end
        UpdateButtonVisibility()
        local delayMinutes = SSBlockerDB and SSBlockerDB.unblockDelay or 5
        local targetTimestamp = time() + (delayMinutes * 60)
        if SSBlockerDB then
            SSBlockerDB.unblockTimestamp = targetTimestamp
        end
        Print("솔로 셔플 종료. " .. delayMinutes .. "분 뒤 차단 목록이 초기화됩니다.")
        
        if unblockTimer then unblockTimer:Cancel() end
        unblockTimer = C_Timer.NewTimer(delayMinutes * 60, UnblockAll)
    end
end

local function OnEvent(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == addonName then
            SSBlockerDB = SSBlockerDB or { unblockDelay = 5 }
            SSBlockerDB.blockedDict = SSBlockerDB.blockedDict or {}
            SSBlockerDB.blockedQueue = SSBlockerDB.blockedQueue or {}
            SSBlockerDB.unblockDelay = math.max(1, math.min(60, tonumber(SSBlockerDB.unblockDelay) or 5))
            -- Migrate old unqualified keys without conflating other realms.
            local migrated, queue = {}, {}
            local function MigrateName(name)
                local fullName = FullName(name)
                if fullName and not migrated[fullName:lower()] then
                    migrated[fullName:lower()] = fullName
                    table.insert(queue, fullName)
                end
            end
            for _, name in ipairs(SSBlockerDB.blockedQueue) do
                if SSBlockerDB.blockedDict[name] then MigrateName(name) end
            end
            for name in pairs(SSBlockerDB.blockedDict) do MigrateName(name) end
            wipe(SSBlockerDB.blockedDict)
            for _, name in ipairs(queue) do SSBlockerDB.blockedDict[name] = true end
            SSBlockerDB.blockedQueue = queue
            if SSBlockerDB.enabled == nil then SSBlockerDB.enabled = true end
            
            if toggleButton then
                if SSBlockerDB.buttonPoint then
                    toggleButton:ClearAllPoints()
                    toggleButton:SetPoint(SSBlockerDB.buttonPoint, UIParent, SSBlockerDB.buttonPoint, SSBlockerDB.buttonX, SSBlockerDB.buttonY)
                else
                    toggleButton:SetPoint("TOP", UIParent, "TOP", 0, -100)
                end
                UpdateButtonState()
            end
        end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "UPDATE_BATTLEFIELD_STATUS" or event == "ZONE_CHANGED_NEW_AREA" or event == "PVP_MATCH_ACTIVE" or event == "PVP_MATCH_COMPLETE" then
        UpdateSoloShuffleState()
        
        if not CheckSoloShuffle() and not inSoloShuffle and event == "PLAYER_ENTERING_WORLD" then
            SSBlockerDB.wasInSoloShuffle = false
            local dict = GetBlockedDict()
            if next(dict) ~= nil then
                local targetTimestamp = SSBlockerDB and SSBlockerDB.unblockTimestamp or 0
                local now = time()
                local remaining = targetTimestamp - now
                if targetTimestamp == 0 or remaining <= 0 then
                    Print("접속 전 대기 시간이 지났습니다. 차단된 임시 플레이어를 즉시 해제합니다.")
                    CancelUnblockTimer()
                    unblockTimer = C_Timer.NewTimer(2.0, function()
                        if not inSoloShuffle then UnblockAll() end
                    end)
                else
                    local remainingMin = math.ceil(remaining / 60)
                    Print("접속 전 해제되지 않은 임시 차단 플레이어가 있습니다. 약 " .. remainingMin .. "분 뒤 해제됩니다.")
                    if unblockTimer then unblockTimer:Cancel() end
                    unblockTimer = C_Timer.NewTimer(remaining, UnblockAll)
                end
            end
        end

        if inSoloShuffle then
            CheckPartyThreeMembers()
        end
        
    elseif event == "GROUP_ROSTER_UPDATE" or event == "ARENA_OPPONENT_UPDATE" or event == "ARENA_PREP_OPPONENT_SPECIALIZATIONS" then
        if not inSoloShuffle then
            UpdateSoloShuffleState()
        end
        if inSoloShuffle then
            CheckPartyThreeMembers()
            if GetBlockedCount() < 5 then
                BlockFromGroup()
            end
        end
    elseif event == "UPDATE_BATTLEFIELD_SCORE" then
        if not inSoloShuffle then
            UpdateSoloShuffleState()
        end
        if inSoloShuffle and GetBlockedCount() < 5 then
            BlockFromScoreboard()
        end
    elseif event == "GUILD_ROSTER_UPDATE" or event == "PLAYER_GUILD_UPDATE" then
        UpdateGuildCache()
        if event == "PLAYER_GUILD_UPDATE" and IsInGuild() then C_GuildInfo.GuildRoster() end
        if inSoloShuffle then BlockFromGroup(true) end
    elseif event == "CHAT_MSG_INSTANCE_CHAT" or event == "CHAT_MSG_INSTANCE_CHAT_LEADER" or event == "CHAT_MSG_PARTY" or event == "CHAT_MSG_PARTY_LEADER" or event == "CHAT_MSG_SAY" then
        if not inSoloShuffle then
            UpdateSoloShuffleState()
        end
        if inSoloShuffle and SSBlockerDB and SSBlockerDB.enabled then
            local _, sender, _, _, _, _, _, _, _, _, _, guid = ...
            if not IsSecret(sender) and sender then
                SafeCall(TryBlockPlayer, sender, guid)
            end
        end
    elseif event == "PLAYER_LOGOUT" then
        local dict = GetBlockedDict()
        if next(dict) ~= nil and SSBlockerDB then
            if not SSBlockerDB.unblockTimestamp then
                local delayMinutes = SSBlockerDB.unblockDelay or 5
                SSBlockerDB.unblockTimestamp = time() + (delayMinutes * 60)
            end
        end
    end
end


toggleButton = CreateFrame("Button", "SSBlockerToggleButton", UIParent, "UIPanelButtonTemplate")
toggleButton:SetSize(120, 30)
toggleButton:SetMovable(true)
toggleButton:EnableMouse(true)
toggleButton:RegisterForDrag("LeftButton")
toggleButton:SetScript("OnDragStart", toggleButton.StartMoving)
toggleButton:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, relativeTo, relativePoint, xOfs, yOfs = self:GetPoint()
    if SSBlockerDB then
        SSBlockerDB.buttonPoint = point
        SSBlockerDB.buttonX = xOfs
        SSBlockerDB.buttonY = yOfs
    end
end)
toggleButton:SetScript("OnClick", function()
    if not SSBlockerDB then return end
    SSBlockerDB.enabled = not SSBlockerDB.enabled
    UpdateButtonState()
    if SSBlockerDB.enabled then
        Print("자동 차단이 활성화되었습니다.")
        BlockFromGroup(true)
    else
        Print("자동 차단이 비활성화되었습니다. (기존 차단 해제)")
        UnblockAll()
    end
end)
toggleButton:Hide()

-- Settings UI
optionsPanel = CreateFrame("Frame", "SSBlockerOptionsPanel")
optionsPanel.name = "Solo Shuffle Blocker"

local title = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("Solo Shuffle Blocker 설정")

local delaySlider = CreateFrame("Slider", "SSBlockerDelaySlider", optionsPanel, "OptionsSliderTemplate")
delaySlider:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -30)
delaySlider:SetMinMaxValues(1, 60)
delaySlider:SetValueStep(1)
delaySlider:SetObeyStepOnDrag(true)
_G[delaySlider:GetName().."Low"]:SetText("1분")
_G[delaySlider:GetName().."High"]:SetText("60분")
_G[delaySlider:GetName().."Text"]:SetText("차단 해제 대기 시간 (분)")

delaySlider:SetScript("OnValueChanged", function(self, value)
    local roundedValue = math.floor(value + 0.5)
    SSBlockerDB.unblockDelay = roundedValue
    _G[self:GetName().."Text"]:SetText("차단 해제 대기 시간: " .. roundedValue .. "분")
end)

local testModeCheck = CreateFrame("CheckButton", "SSBlockerTestModeCheck", optionsPanel, "ChatConfigCheckButtonTemplate")
testModeCheck:SetPoint("TOPLEFT", delaySlider, "BOTTOMLEFT", 0, -10)
_G[testModeCheck:GetName().."Text"]:SetText("버튼 위치 테스트 모드 (버튼 강제 표시)")
testModeCheck:SetScript("OnClick", function(self)
    isTestMode = self:GetChecked()
    UpdateButtonVisibility()
end)

local unblockBtn = CreateFrame("Button", "SSBlockerUnblockBtn", optionsPanel, "UIPanelButtonTemplate")
unblockBtn:SetSize(120, 25)
unblockBtn:SetPoint("TOPLEFT", testModeCheck, "BOTTOMLEFT", 0, -20)
unblockBtn:SetText("전체 차단 해제")
unblockBtn:SetScript("OnClick", function()
    UnblockAll()
    if UpdateBlockListDisplay then UpdateBlockListDisplay() end
end)

local listTitle = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
listTitle:SetPoint("TOPLEFT", unblockBtn, "BOTTOMLEFT", 0, -20)
listTitle:SetText("현재 차단된 플레이어 목록:")

local blockListText = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
blockListText:SetPoint("TOPLEFT", listTitle, "BOTTOMLEFT", 0, -10)
blockListText:SetJustifyH("LEFT")
blockListText:SetJustifyV("TOP")
blockListText:SetWidth(400)
blockListText:SetHeight(300)

UpdateBlockListDisplay = function()
    local text = ""
    local count = 0
    local dict = GetBlockedDict()
    for name, _ in pairs(dict) do
        text = text .. name .. "\n"
        count = count + 1
    end
    if count == 0 then
        text = "없음"
    end
    blockListText:SetText(text)
end

optionsPanel:SetScript("OnShow", function()
    if SSBlockerDB then
        delaySlider:SetValue(SSBlockerDB.unblockDelay or 5)
    end
    if isTestMode then
        SSBlockerTestModeCheck:SetChecked(true)
    else
        SSBlockerTestModeCheck:SetChecked(false)
    end
    UpdateBlockListDisplay()
end)

optionsPanel:SetScript("OnHide", function()
    if isTestMode then
        isTestMode = false
        SSBlockerTestModeCheck:SetChecked(false)
        UpdateButtonVisibility()
    end
end)

local category = Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterCanvasLayoutCategory(optionsPanel, optionsPanel.name)
if category then
    Settings.RegisterAddOnCategory(category)
else
    InterfaceOptions_AddCategory(optionsPanel)
end

-- Slash command handler
SLASH_SSBLOCKER1 = "/ssb"
SlashCmdList["SSBLOCKER"] = function(msg)
    local cmd = msg and msg:lower():match("^%s*(%S+)")
    if cmd == "test" then
        UpdateGuildCache()
        if IsInGuild() then C_GuildInfo.GuildRoster() end
        Print("테스트: 현재 그룹 및 아레나 대상을 기반으로 차단을 시도합니다 (솔로셔플 여부 무관).")
        BlockFromGroup(true, true)
        if not inSoloShuffle and next(GetBlockedDict()) then
            CancelUnblockTimer()
            SSBlockerDB.unblockTimestamp = time() + SSBlockerDB.unblockDelay * 60
            unblockTimer = C_Timer.NewTimer(SSBlockerDB.unblockDelay * 60, UnblockAll)
        end
    elseif cmd == "status" then
        local isSS1 = C_PvP and C_PvP.IsSoloShuffle and C_PvP.IsSoloShuffle()
        local isSS2 = C_PvP and C_PvP.IsRatedSoloShuffle and C_PvP.IsRatedSoloShuffle()
        local inInst, instType = IsInInstance()
        Print("=== SSB 상태 진단 ===")
        Print("솔로셔플 인식: " .. tostring(inSoloShuffle))
        Print("API IsSoloShuffle: " .. tostring(isSS1) .. " / IsRatedSoloShuffle: " .. tostring(isSS2))
        Print("인스턴스 상태: " .. tostring(inInst) .. " (" .. tostring(instType) .. ")")
        Print("차단 수: " .. GetBlockedCount() .. "/5")
        Print("전체 차단자(DB): " .. (C_FriendList.GetNumIgnores and C_FriendList.GetNumIgnores() or "알 수 없음"))
        Print("디버그 모드: " .. (SSBlockerDB and SSBlockerDB.debug and "ON" or "OFF"))
    elseif cmd == "debug" then
        SSBlockerDB.debug = not SSBlockerDB.debug
        Print("디버그 모드가 " .. (SSBlockerDB.debug and "활성화" or "비활성화") .. "되었습니다.")
    elseif cmd == "unblock" then
        UnblockAll()
        if UpdateBlockListDisplay then UpdateBlockListDisplay() end
        if not next(GetBlockedDict()) then Print("모든 임시 차단을 해제했습니다.") end
    else
        if category and Settings and Settings.OpenToCategory then
            Settings.OpenToCategory(category:GetID())
        else
            InterfaceOptionsFrame_OpenToCategory(optionsPanel)
            InterfaceOptionsFrame_OpenToCategory(optionsPanel)
        end
    end
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("UPDATE_BATTLEFIELD_STATUS")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("PVP_MATCH_ACTIVE")
frame:RegisterEvent("PVP_MATCH_COMPLETE")
frame:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("ARENA_OPPONENT_UPDATE")
frame:RegisterEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_GUILD_UPDATE")
frame:RegisterEvent("CHAT_MSG_INSTANCE_CHAT")
frame:RegisterEvent("CHAT_MSG_INSTANCE_CHAT_LEADER")
frame:RegisterEvent("CHAT_MSG_PARTY")
frame:RegisterEvent("CHAT_MSG_PARTY_LEADER")
frame:RegisterEvent("CHAT_MSG_SAY")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", OnEvent)
