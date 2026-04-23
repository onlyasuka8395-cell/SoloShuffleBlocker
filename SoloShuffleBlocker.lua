local addonName, addon = ...
local frame = CreateFrame("Frame")
SSBlockerDB = SSBlockerDB or { unblockDelay = 5, enabled = true }
local unblockTimer = nil
local inSoloShuffle = false
local isTestMode = false
local optionsPanel
local UpdateBlockListDisplay
local toggleButton

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

-- Helper to safely get the number of scoreboard entries
local function GetNumScores()
    if GetNumBattlefieldScores then
        return GetNumBattlefieldScores()
    elseif C_PvP and C_PvP.GetActiveMatchScoreboard then
        local sb = C_PvP.GetActiveMatchScoreboard()
        return sb and #sb or 0
    else
        local count = 0
        while C_PvP and C_PvP.GetScoreInfo(count + 1) do
            count = count + 1
        end
        return count
    end
end

-- Helper to print messages
local function Print(msg)
    print("|cFF00FF00[SSBlocker]|r " .. msg)
end

local function UnblockOldest(count)
    local queue = GetBlockedQueue()
    local dict = GetBlockedDict()
    local unblocked = 0
    while unblocked < count and #queue > 0 do
        local oldestName = table.remove(queue, 1)
        if dict[oldestName] then
            C_FriendList.DelIgnore(oldestName)
            dict[oldestName] = nil
            unblocked = unblocked + 1
        end
    end
    if unblocked > 0 then
        Print("차단 목록 여유 공간 확보를 위해 오래된 임시 차단 " .. unblocked .. "명을 사전 자동 해제했습니다.")
    end
end

-- Function to unblock players tracked by this addon
local function UnblockAll()
    local count = 0
    local dict = GetBlockedDict()
    for name, _ in pairs(dict) do
        C_FriendList.DelIgnore(name)
        count = count + 1
    end
    if SSBlockerDB then
        wipe(SSBlockerDB.blockedDict)
        wipe(SSBlockerDB.blockedQueue)
    end
    unblockTimer = nil
    if count > 0 then
        Print(count .. "명의 플레이어를 차단 해제했습니다.")
    end
end

-- Helper to check if a unit (by GUID) is in the player's guild
local guildMemberGuids = {}

local function UpdateGuildCache()
    wipe(guildMemberGuids)
    if not IsInGuild() then return end
    
    -- Request latest roster (async, but we do our best)
    C_GuildInfo.GuildRoster()
    
    local numMembers = GetNumGuildMembers()
    for i = 1, numMembers do
        local name, _, _, _, _, _, _, _, online, _, _, _, _, _, _, _, guid = GetGuildRosterInfo(i)
        if guid then
            guildMemberGuids[guid] = true
        end
    end
end

local function IsSameGuild(targetGuid)
    if not targetGuid then return false end
    return guildMemberGuids[targetGuid]
end

-- Function to block players in the current match
local function BlockCurrentPlayers()
    if not inSoloShuffle then return end
    if SSBlockerDB and SSBlockerDB.enabled == false then return end

    -- 서버에 점수판 데이터 갱신 요청
    if RequestBattlefieldScoreData then
        RequestBattlefieldScoreData()
    end

    local myName, myRealm = UnitName("player")
    if not myRealm then myRealm = GetRealmName() end
    local myFullName = myName .. "-" .. myRealm
    
    local function TryBlock(name, guid)
        -- 이름이 없거나 '알 수 없음'인 경우 무시
        if not name or name == "" or name == UNKNOWN or name == UNKNOWNOBJECT or name == "Unknown" or name == "알 수 없음" then 
            return 
        end
        
        if name ~= myName and name ~= myFullName then
            -- 길드원 여부 확인
            local isGuild = IsSameGuild(guid)
            
            if not isGuild then
                -- 이미 차단된 사용자인지 확인
                if not C_FriendList.IsIgnored(name) then
                    local success = C_FriendList.AddIgnore(name)
                    
                    if not success and #GetBlockedQueue() > 0 then
                        local numIgnores = C_FriendList.GetNumIgnores and C_FriendList.GetNumIgnores() or 0
                        if numIgnores >= 40 then
                            UnblockOldest(6)
                            success = C_FriendList.AddIgnore(name)
                        end
                    end

                    if success then
                        local dict = GetBlockedDict()
                        local queue = GetBlockedQueue()
                        if not dict[name] then
                            dict[name] = true
                            table.insert(queue, name)
                        end
                        -- Print(name .. " 차단됨 (임시).")
                    end
                end
            end
        end
    end

    -- 1. 점수판 정보를 통해 차단 시도
    local numScores = GetNumScores()
    for i = 1, numScores do
        local scoreInfo = C_PvP.GetScoreInfo(i)
        if scoreInfo and scoreInfo.name then
            TryBlock(scoreInfo.name, scoreInfo.guid)
        end
    end

    -- 2. 폴백: arena1~6 유닛 정보를 통해 차단 시도 (점수판 로드가 늦을 경우 대비)
    for i = 1, 6 do
        local unit = "arena" .. i
        if UnitExists(unit) then
            local name, realm = UnitName(unit)
            if name and name ~= "" then
                local fullName = name
                if realm and realm ~= "" then
                    fullName = name .. "-" .. realm
                end
                TryBlock(fullName, UnitGUID(unit))
            end
        end
    end
end

local function OnEvent(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == addonName then
            SSBlockerDB = SSBlockerDB or { unblockDelay = 5 }
            SSBlockerDB.blockedDict = SSBlockerDB.blockedDict or {}
            SSBlockerDB.blockedQueue = SSBlockerDB.blockedQueue or {}
            if SSBlockerDB.enabled == nil then SSBlockerDB.enabled = true end
            
            if SSBlockerDB.buttonPoint then
                toggleButton:ClearAllPoints()
                toggleButton:SetPoint(SSBlockerDB.buttonPoint, UIParent, SSBlockerDB.buttonPoint, SSBlockerDB.buttonX, SSBlockerDB.buttonY)
            else
                toggleButton:SetPoint("TOP", UIParent, "TOP", 0, -100)
            end
            UpdateButtonState()
        end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "UPDATE_BATTLEFIELD_STATUS" then
        local isSoloShuffle = (C_PvP.IsRatedSoloShuffle and C_PvP.IsRatedSoloShuffle()) or (C_PvP.IsSoloShuffle and C_PvP.IsSoloShuffle())
        
        if isSoloShuffle and not inSoloShuffle then
            -- ENTERING Solo Shuffle
            inSoloShuffle = true
            UpdateButtonVisibility()
            
            -- If we have a pending unblock timer or old blocks, clear them now to start fresh
            if unblockTimer then
                unblockTimer:Cancel()
                unblockTimer = nil
            end
            UnblockAll() -- Clear previous game's blocks immediately to free up space/reset
            
            Print("솔로 셔플 진입 확인. 플레이어 차단을 시작합니다.")
            
            UpdateGuildCache() -- Cache guild members to avoid blocking them
            
            -- 플레이어가 천천히 로드될 수 있으므로 여러 번 시도합니다.
            if SSBlockerDB and SSBlockerDB.enabled then
                BlockCurrentPlayers()
                C_Timer.After(2, BlockCurrentPlayers)
                C_Timer.After(5, BlockCurrentPlayers)
                C_Timer.After(10, BlockCurrentPlayers)
                C_Timer.After(15, BlockCurrentPlayers)
                C_Timer.After(30, BlockCurrentPlayers)
                C_Timer.After(60, BlockCurrentPlayers) -- 만약을 위한 마지막 확인
            end
            
        elseif not isSoloShuffle and inSoloShuffle then
            -- LEAVING Solo Shuffle
            inSoloShuffle = false
            UpdateButtonVisibility()
            local delayMinutes = SSBlockerDB and SSBlockerDB.unblockDelay or 5
            Print("솔로 셔플 종료. " .. delayMinutes .. "분 뒤 차단 목록이 초기화됩니다.")
            
            if unblockTimer then unblockTimer:Cancel() end
            unblockTimer = C_Timer.NewTimer(delayMinutes * 60, UnblockAll)
        elseif not isSoloShuffle and not inSoloShuffle and event == "PLAYER_ENTERING_WORLD" then
            local dict = GetBlockedDict()
            if next(dict) ~= nil then
                Print("접속 전 해제되지 않은 임시 차단 플레이어가 있습니다. " .. (SSBlockerDB and SSBlockerDB.unblockDelay or 5) .. "분 뒤 해제됩니다.")
                local delayMinutes = SSBlockerDB and SSBlockerDB.unblockDelay or 5
                if unblockTimer then unblockTimer:Cancel() end
                unblockTimer = C_Timer.NewTimer(delayMinutes * 60, UnblockAll)
            end
        end
        
    elseif event == "UPDATE_BATTLEFIELD_SCORE" then
        if inSoloShuffle then
            BlockCurrentPlayers()
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
        BlockCurrentPlayers()
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
    if msg == "test" then
        Print("테스트: 현재 차단 목록 수: " .. tostring(GetNumScores()))
        BlockCurrentPlayers()
    elseif msg == "unblock" then
        UnblockAll()
        if UpdateBlockListDisplay then UpdateBlockListDisplay() end
        Print("강제로 모든 임시 차단을 해제했습니다.")
    else
        if Settings and Settings.OpenToCategory then
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
frame:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
frame:SetScript("OnEvent", OnEvent)
