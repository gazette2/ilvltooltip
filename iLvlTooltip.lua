-- ****************************************************************************************************
-- Refactored by gazette2 - Minimal Tooltip Only Version
-- Removed: Settings UI, Character Pane Overlays, Slash Commands, Legacy Prefixes
-- Kept: GUID Caching, TooltipDataProcessor, Inspect Debounce
-- ****************************************************************************************************

local addon = ...;

-- Caching System
local playerCache = {};
local CACHE_TTL = 300; -- Cache Time To Live: 300 seconds (5 minutes)
local lastInspectTime = 0;
local INSPECT_DEBOUNCE = 0.2; -- Prevent server throttling (Lowered to 0.2s for better group responsiveness)
local pendingInspect = nil;

-- ============================================================================
-- Secret Value Detection (비교 연산자 완벽 배제 버전)
-- ============================================================================
local function IsSafeString(str)
    if type(str) ~= "string" then return false end
    
    -- 비밀 문자열을 식별하기 위해, [] 연산자 대신 C 내장 함수인 rawset을 사용합니다.
    -- rawset은 UI 에러 로그를 강제로 남기지 않으므로 pcall을 통해 조용히 걸러낼 수 있습니다.
    local dummyTable = {}
    local ok = pcall(rawset, dummyTable, str, true)
    return ok
end

local function IsSafeGUID(guid)
    if not IsSafeString(guid) then return false end
    
    -- == 연산자를 절대 쓰면 안되므로, string.match를 통해 패턴 일치 여부만 확인합니다.
    local ok, matchPattern = pcall(string.match, guid, "^Player%-")
    
    -- matchPattern이 존재(truthy)하면 true, 아니면 false 반환 (==, ~= 금지)
    return ok and (matchPattern and true or false)
end

-- ============================================================================
-- Events
-- ============================================================================
local eventFrame = CreateFrame("frame");
eventFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT");
eventFrame:RegisterEvent("INSPECT_READY");
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED");
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED");

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if (event == "UPDATE_MOUSEOVER_UNIT") then
        HandleMouseover();
    elseif (event == "INSPECT_READY") then
        HandleInspectReady(...);
    elseif (event == "PLAYER_REGEN_DISABLED") then
        self:UnregisterEvent("UPDATE_MOUSEOVER_UNIT");
    elseif (event == "PLAYER_REGEN_ENABLED") then
        self:RegisterEvent("UPDATE_MOUSEOVER_UNIT");
    end
end);

-- ============================================================================
-- Core Inspect Logic
-- ============================================================================
function HandleMouseover()
    if not UnitIsPlayer("mouseover") then return end 
    if not CanInspect("mouseover") then return end

    local ok, guid = pcall(function() return UnitGUID("mouseover") end)
    if not ok or not IsSafeGUID(guid) then return end

    local now = GetTime();
    if playerCache[guid] and (now - playerCache[guid].timestamp < CACHE_TTL) then
        return;
    end

    if pendingInspect == guid then return; end

    if (now - lastInspectTime) > INSPECT_DEBOUNCE then
        lastInspectTime = now;
        pendingInspect = guid;
        NotifyInspect("mouseover");
    end
end

-- Resolving specific unit by GUID for robust parsing
local function GetUnitByGUID(safeGuid)
    -- 들어온 값이 안전한지 확인
    if not IsSafeGUID(safeGuid) then return nil end

    local function checkUnitMatch(unit)
        local ok, uGuid = pcall(function() return UnitGUID(unit) end)
        -- 반환된 uGuid 역시 비교(==)하기 전에 비밀 값인지 반드시 점검해야 함
        if not ok or not IsSafeGUID(uGuid) then return false end
        return uGuid == safeGuid
    end

    if checkUnitMatch("mouseover") then return "mouseover" end
    if checkUnitMatch("target") then return "target" end
    if checkUnitMatch("focus") then return "focus" end
    if checkUnitMatch("player") then return "player" end

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            if checkUnitMatch("raid"..i) then return "raid"..i end
        end
    elseif IsInGroup() then
        for i = 1, GetNumSubgroupMembers() do
            if checkUnitMatch("party"..i) then return "party"..i end
        end
    end

    return nil
end

local function RefreshTooltipIfMatching(safeGuid)
    if GameTooltip:IsVisible() then
        local ok, unit = pcall(function()
            local _, u = GameTooltip:GetUnit()
            return u
        end)

        -- 툴팁에서 가져온 unit 값 자체도 secret일 수 있으므로 UnitGUID()에 넣기 전에 안전한 문자열인지 확인
        if ok and IsSafeString(unit) then
            local ok2, uGuid = pcall(function() return UnitGUID(unit) end)
            if ok2 and IsSafeGUID(uGuid) and uGuid == safeGuid then
                GameTooltip:SetUnit(unit)
            end
        end
    end
end

function HandleInspectReady(guid)
    if not IsSafeGUID(guid) then return end

    if pendingInspect == guid then
        pendingInspect = nil;
    end

    local unit = GetUnitByGUID(guid);
    if not unit then 
        ClearInspectPlayer();
        return; 
    end

    local iLvl = C_PaperDollInfo.GetInspectItemLevel(unit);
    if not iLvl or iLvl <= 0 then 
        ClearInspectPlayer();
        return; 
    end

    local mPlusRating = "0";
    local mPlusData = C_PlayerInfo.GetPlayerMythicPlusRatingSummary(unit);
    if mPlusData and mPlusData.currentSeasonScore then
        mPlusRating = tostring(mPlusData.currentSeasonScore);
    end

    playerCache[guid] = {
        timestamp = GetTime(),
        iLvl = iLvl,
        mPlusRating = mPlusRating,
        weapiLvl = ""
    };

    ClearInspectPlayer();
    RefreshTooltipIfMatching(guid);

    local mhLink = GetInventoryItemLink(unit, GetInventorySlotInfo("MainHandSlot"));
    local ohLink = GetInventoryItemLink(unit, GetInventorySlotInfo("SecondaryHandSlot"));
    
    local weaps = { mh = nil, oh = nil };
    local expected = 0;
    local received = 0;

    local function TryCompleteWeapons()
        if received >= expected then
            local wStr = "";
            if weaps.mh then wStr = tostring(weaps.mh) end
            if weaps.oh then 
                wStr = wStr ~= "" and (wStr .. "/" .. tostring(weaps.oh)) or tostring(weaps.oh) 
            end
            if wStr ~= "" then
                -- guid는 위에서 안전성이 보장되었으므로 업데이트 (인덱싱 가능)
                if playerCache[guid] then
                    playerCache[guid].weapiLvl = " (" .. wStr .. ")";
                    RefreshTooltipIfMatching(guid);
                end
            end
        end
    end

    if mhLink then
        expected = expected + 1;
        local item = Item:CreateFromItemLink(mhLink);
        item:ContinueOnItemLoad(function()
            weaps.mh = item:GetCurrentItemLevel();
            received = received + 1;
            TryCompleteWeapons();
        end);
    end
    
    if ohLink then
        expected = expected + 1;
        local item = Item:CreateFromItemLink(ohLink);
        item:ContinueOnItemLoad(function()
            weaps.oh = item:GetCurrentItemLevel();
            received = received + 1;
            TryCompleteWeapons();
        end);
    end
end

-- ============================================================================
-- Modern Tooltip Handling
-- ============================================================================
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, data)
    if tooltip ~= GameTooltip then return end
    if not data or not data.guid then return end

    local guid = data.guid
    
    -- ★ 이 부분이 가장 많이 에러가 났던(2876번) 지점입니다. 
    -- 인덱스로 쓰기 전 철저하게 Secret이 아님을 증명하고 넘어가야 합니다.
    if not IsSafeGUID(guid) then return end 

    local cached = playerCache[guid]
    
    if cached and cached.iLvl and cached.iLvl > 0 then
        tooltip:AddLine(" ")

        local wepText = ""
        if cached.weapiLvl and cached.weapiLvl ~= "" then
            wepText = cached.weapiLvl
        end
        tooltip:AddLine("iLvl: " .. cached.iLvl .. wepText)

        if cached.mPlusRating ~= "0" then
            tooltip:AddLine("M+ Score: " .. cached.mPlusRating)
        end
    end
end);