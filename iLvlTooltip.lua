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
-- Secret Value Detection (Comparison Operator Exclusion)
-- ============================================================================
local function IsSafeString(str)
    if type(str) ~= "string" then return false end
    
    -- To identify restricted strings without triggering UI errors,
    -- use the C built-in function rawset with pcall instead of the [] operator.
    local dummyTable = {}
    local ok = pcall(rawset, dummyTable, str, true)
    return ok
end

local function IsSafeGUID(guid)
    if not IsSafeString(guid) then return false end
    
    -- Using the == operator on restricted values can cause issues.
    -- We verify pattern matches via string.match instead.
    local ok, matchPattern = pcall(string.match, guid, "^Player%-")
    
    -- Return true if matchPattern is truthy, false otherwise (==, ~= must be avoided)
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
    -- elseif (event == "PLAYER_REGEN_DISABLED") then
    --    self:UnregisterEvent("UPDATE_MOUSEOVER_UNIT");
    -- elseif (event == "PLAYER_REGEN_ENABLED") then
    --    self:RegisterEvent("UPDATE_MOUSEOVER_UNIT");
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
    -- Verify the input value is safe
    if not IsSafeGUID(safeGuid) then return nil end

    local function checkUnitMatch(unit)
        local ok, uGuid = pcall(function() return UnitGUID(unit) end)
        -- Must ensure the returned uGuid is safe before using equality (==) comparisons
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

        -- The unit value from the tooltip might be a secret, so check if it's safe before passing to UnitGUID()
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
                -- guid is guaranteed safe above, so it can be used for indexing and updating
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
    
    -- ★ This is the point where the most errors occurred (2876 times).
    -- It must be strictly proven that it is not a Secret before being used as an index.
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