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
local INSPECT_DEBOUNCE = 0.3; -- Prevent server throttling
local pendingInspect = nil;

-- Helper to safely check if a GUID is not a "secret" string
local function IsSafeGUID(guid)
    if type(guid) ~= "string" then return false end
    
    -- "Player-" 로 시작하는 정상적인 GUID 포맷을 가지고 있는지 확인.
    -- Secret String은 보통 string API(sub, match)를 통과하지 못해 에러를 던지거나 매칭되지 않습니다.
    local success, isPlayer = pcall(function()
        return string.sub(guid, 1, 7) == "Player-"
    end)

    return success and isPlayer
end

-- Create event handler frame
local eventFrame = CreateFrame("frame");
eventFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT");
eventFrame:RegisterEvent("INSPECT_READY");
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED"); -- Fires when entering combat
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED");  -- Fires when leaving combat

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if (event == "UPDATE_MOUSEOVER_UNIT") then
        HandleMouseover();
    elseif (event == "INSPECT_READY") then
        HandleInspectReady(...);
    elseif (event == "PLAYER_REGEN_DISABLED") then
        -- Unsubscribe from mouseover events to save CPU cycles during combat
        self:UnregisterEvent("UPDATE_MOUSEOVER_UNIT");
    elseif (event == "PLAYER_REGEN_ENABLED") then
        -- Resubscribe when combat ends
        self:RegisterEvent("UPDATE_MOUSEOVER_UNIT");
    end
end);

-- ============================================================================
-- Core Inspect Logic (Debounced & Cached)
-- ============================================================================
function HandleMouseover()
    -- InCombatLockdown check is no longer needed here as the event itself is unregistered
    if not UnitIsPlayer("mouseover") then return end 
    if not CanInspect("mouseover") then return end

    local guid = UnitGUID("mouseover");
    if not IsSafeGUID(guid) then return end

    local now = GetTime();
    -- Check if we have valid cache
    if playerCache[guid] and (now - playerCache[guid].timestamp < CACHE_TTL) then
        return; -- Valid cache exists, no need to inspect
    end

    if pendingInspect == guid then
        return; -- Already waiting for this specific character's data
    end

    -- Debounce logic
    if (now - lastInspectTime) > INSPECT_DEBOUNCE then
        lastInspectTime = now;
        pendingInspect = guid;
        NotifyInspect("mouseover");
    end
end

-- Resolving specific unit by GUID for robust parsing
local function GetUnitByGUID(guid)
    if type(guid) ~= "string" then return nil end

    local function checkUnitMatch(unit)
        local uGuid
        -- UnitGUID 호출 자체도 pcall로 보호합니다
        local ok1 = pcall(function() uGuid = UnitGUID(unit) end)
        if not ok1 or not uGuid then return false end

        -- 두 값을 비교하는 연산 자체(==)를 pcall 내부에서 처리합니다
        local ok2, isMatch = pcall(function()
            return uGuid == guid
        end)
        
        return (ok2 and isMatch)
    end

    -- 1순위: 마우스 오버, 타겟, 포커스, 본인 검사
    if checkUnitMatch("mouseover") then return "mouseover" end
    if checkUnitMatch("target") then return "target" end
    if checkUnitMatch("focus") then return "focus" end
    if checkUnitMatch("player") then return "player" end

    -- 2순위: 위에서 대상을 놓쳤고 공격대/파티에 속해 있다면 그룹 프레임에서 대상을 탐색
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

-- Helper to force tooltip redraw when async data arrives
local function RefreshTooltipIfMatching(guid)
    if GameTooltip:IsVisible() then
        local ok, unit = pcall(function()
            local _, u = GameTooltip:GetUnit()
            return u
        end)

        if ok and unit then
            -- UnitGUID 및 비교 로직을 안전망(pcall) 내부에서 실행
            pcall(function()
                if UnitGUID(unit) == guid then
                    GameTooltip:SetUnit(unit) -- Forces TooltipDataProcessor to run again
                end
            end)
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

    -- Exception handling for Mythic+
    local mPlusRating = "0";
    local mPlusData = C_PlayerInfo.GetPlayerMythicPlusRatingSummary(unit);
    if mPlusData and mPlusData.currentSeasonScore then
        mPlusRating = tostring(mPlusData.currentSeasonScore);
    end

    -- Create/Update Cache
    playerCache[guid] = {
        timestamp = GetTime(),
        iLvl = iLvl,
        mPlusRating = mPlusRating,
        weapiLvl = "" -- Will be updated asynchronously
    };

    ClearInspectPlayer(); -- Release the server inspect lock
    RefreshTooltipIfMatching(guid);

    -- Async Weapon parsing
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
-- Modern Tooltip Handling (WoW 10.0+ TooltipDataProcessor)
-- ============================================================================
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, data)
    if tooltip ~= GameTooltip then return end
    if not data or not data.guid then return end

    local guid = data.guid
    if type(guid) ~= "string" then return end

    -- 테이블 인덱싱 접근 자체를 pcall 내부에서 실행
    local ok, cached = pcall(function()
        return playerCache[guid]
    end)

    -- ok가 false라는 것은 guid가 secret 값이라 table 인덱싱이 막혔다는 뜻입니다
    if not ok or not cached then return end
    
    if cached.iLvl and cached.iLvl > 0 then
        tooltip:AddLine(" ") -- Add a blank line for readability

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