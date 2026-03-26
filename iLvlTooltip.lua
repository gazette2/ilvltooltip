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
local INSPECT_DEBOUNCE = 0.5; -- Prevent server throttling
local pendingInspect = nil;

-- Create event handler frame
local eventFrame = CreateFrame("frame");
eventFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT");
eventFrame:RegisterEvent("INSPECT_READY");

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if (event == "UPDATE_MOUSEOVER_UNIT") then
        HandleMouseover();
    elseif (event == "INSPECT_READY") then
        HandleInspectReady(...);
    end
end);

-- ============================================================================
-- Core Inspect Logic (Debounced & Cached)
-- ============================================================================
function HandleMouseover()
    if InCombatLockdown() then return end -- Do not fire inspects in combat
    if not UnitIsPlayer("mouseover") then return end 
    if not CanInspect("mouseover") then return end

    local guid = UnitGUID("mouseover");
    if not guid then return end

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
    if UnitGUID("mouseover") == guid then return "mouseover" end
    if UnitGUID("target") == guid then return "target" end
    if UnitGUID("focus") == guid then return "focus" end
    return nil;
end

-- Helper to force tooltip redraw when async data arrives
local function RefreshTooltipIfMatching(guid)
    if GameTooltip:IsVisible() then
        local _, unit = GameTooltip:GetUnit();
        if unit and UnitGUID(unit) == guid then
            GameTooltip:SetUnit(unit); -- Forces TooltipDataProcessor to run again
        end
    end
end

function HandleInspectReady(guid)
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

    local name, unit = tooltip:GetUnit();
    if not unit or not UnitIsPlayer(unit) then return end 

    local guid = UnitGUID(unit);
    if not guid then return end

    local cached = playerCache[guid];
    if cached and cached.iLvl and cached.iLvl > 0 then
        tooltip:AddLine(" "); -- Add a blank line for readability

        local wepText = "";
        if cached.weapiLvl and cached.weapiLvl ~= "" then
            wepText = cached.weapiLvl;
        end
        tooltip:AddLine("iLvl: " .. cached.iLvl .. wepText);

        if cached.mPlusRating ~= "0" then
            tooltip:AddLine("M+ Score: " .. cached.mPlusRating);
        end
    end
end);