-- RefactorMap.lua
-- World map scroll-to-zoom/click-drag-pan and class-colored party/raid map
-- icons, ported directly from the working Magnify-WotLK addon into Refactor.

-- Safe reference to IsAddOnLoaded without global scope mutation
local orig_IsAddOnLoaded = IsAddOnLoaded

local function InitRefactorMap()
    if not (WorldMapFrame and WorldMapDetailFrame
        and WorldMapButton and WORLDMAP_SETTINGS and WorldMapBlobFrame
        and WorldMapPOIFrame and WorldMapPlayer and WorldMapPing
        and WorldMapScreenAnchor) then
        return
    end

    if not WorldMapScrollFrame then
        WorldMapScrollFrame = CreateFrame("ScrollFrame", "WorldMapScrollFrame", WorldMapFrame, "FauxScrollFrameTemplate")
        WorldMapScrollFrame:SetSize(1002, 668)
        WorldMapScrollFrame:SetPoint("TOPLEFT", WorldMapPositioningGuide or WorldMapFrame, "TOPLEFT")
    end

    local MIN_ZOOM = 1.0
    local MAX_ZOOM = 4.0
    local ZOOM_STEP = 0.1

    local MINIMODE_MIN_ZOOM, MINIMODE_MAX_ZOOM = 1.0, 3.0
    local MINIMODE_ZOOM_STEP = 0.1

    local WORLDMAP_POI_MIN_X, WORLDMAP_POI_MIN_Y = 12, -12
    local poiMaxX, poiMaxY

    local PLAYER_ARROW_SIZE = 36

    -- Group dot frames and party unit tokens, resolved once at load. These
    -- frames are created by Blizzard_WorldMap (already loaded — InitRefactorMap
    -- bails otherwise) and never replaced, so every hot path below indexes
    -- these arrays instead of rebuilding _G["WorldMapRaid"..i]. The per-frame
    -- position loop alone was 40 string builds + global lookups per frame,
    -- ~2400 a second with the map open.
    local partyFrames, raidFrames = {}, {}
    local partyUnits, raidUnits = {}, {}
    for i = 1, MAX_PARTY_MEMBERS do
        partyFrames[i] = _G["WorldMapParty" .. i]
        partyUnits[i] = "party" .. i
    end
    for i = 1, MAX_RAID_MEMBERS do
        raidFrames[i] = _G["WorldMapRaid" .. i]
        raidUnits[i] = "raid" .. i
    end

    local function Qol(key)
        return RefactorQoL and RefactorQoL.Get(key)
    end

    --------------------------------------------------------------------
    -- Player + cursor coordinates
    --------------------------------------------------------------------

    local coordsFrame = CreateFrame("Frame", nil, WorldMapFrame)
    coordsFrame:SetFrameLevel((WORLDMAP_POI_FRAMELEVEL or 10) + 20)
    -- Anchored to the map VIEWPORT, not WorldMapFrame. WorldMapFrame is the
    -- whole shell — in fullscreen mode its bottom is under the quest
    -- log/detail panel, so BOTTOMLEFT/BOTTOMRIGHT of it put the readouts on
    -- top of the quest text and the Show Quest Objectives checkbox.
    -- WorldMapScrollFrame is the visible map rectangle in every mode
    -- (fullscreen, mini, and the fullMapWindow tweak), so this follows mode
    -- switches with no re-anchoring.
    local playerCoords = coordsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    playerCoords:SetPoint("BOTTOMLEFT", WorldMapScrollFrame, "BOTTOMLEFT", 20, 10)
    local cursorCoords = coordsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cursorCoords:SetPoint("BOTTOMRIGHT", WorldMapScrollFrame, "BOTTOMRIGHT", -20, 10)

    local function CursorMapPosition()
        local left, top = WorldMapDetailFrame:GetLeft(), WorldMapDetailFrame:GetTop()
        if not left then return end
        local scale = WorldMapDetailFrame:GetEffectiveScale()
        local x, y = GetCursorPosition()
        local cx = (x / scale - left) / WorldMapDetailFrame:GetWidth()
        local cy = (top - y / scale) / WorldMapDetailFrame:GetHeight()
        if cx < 0 or cx > 1 or cy < 0 or cy > 1 then return end
        return cx, cy
    end

    local coordsAccum = 0
    coordsFrame:SetScript("OnUpdate", function(_, elapsed)
        coordsAccum = coordsAccum + (elapsed or 0)
        if coordsAccum < 0.1 then return end
        coordsAccum = 0
        if not Qol("mapCoords") then
            if playerCoords:GetText() then
                playerCoords:SetText("")
                cursorCoords:SetText("")
            end
            return
        end
        local px, py = GetPlayerMapPosition("player")
        if px == 0 and py == 0 then
            playerCoords:SetText("")
        else
            playerCoords:SetFormattedText("Player: %.1f, %.1f", px * 100, py * 100)
        end
        local cx, cy = CursorMapPosition()
        if cx then
            cursorCoords:SetFormattedText("Cursor: %.1f, %.1f", cx * 100, cy * 100)
        else
            cursorCoords:SetText("")
        end
    end)

    --------------------------------------------------------------------
    -- Map move fade
    --------------------------------------------------------------------

    local FADE_ALPHA = 0.4
    local FADE_SPEED = 6

    local fadeBaseline
    local fadeFrame = CreateFrame("Frame", nil, WorldMapFrame)
    fadeFrame:SetScript("OnUpdate", function(_, elapsed)
        if not fadeBaseline and not Qol("mapMoveFade") then return end
        local moving = GetUnitSpeed and (GetUnitSpeed("player") or 0) > 0
        local wantFade = moving and Qol("mapMoveFade")
            and not WorldMapScrollFrame:IsMouseOver()

        local target
        if wantFade then
            if not fadeBaseline then fadeBaseline = WorldMapFrame:GetAlpha() end
            target = min(FADE_ALPHA, fadeBaseline)
        elseif fadeBaseline then
            target = fadeBaseline
        else
            return
        end

        local cur = WorldMapFrame:GetAlpha()
        if abs(cur - target) < 0.015 then
            WorldMapFrame:SetAlpha(target)
            if not wantFade then fadeBaseline = nil end
        else
            WorldMapFrame:SetAlpha(cur + (target - cur) * min(1, elapsed * FADE_SPEED))
        end
    end)
    WorldMapFrame:HookScript("OnHide", function()
        if fadeBaseline then
            WorldMapFrame:SetAlpha(fadeBaseline)
            fadeBaseline = nil
        end
    end)

    --------------------------------------------------------------------
    -- Leatrix Maps stand-down check
    --------------------------------------------------------------------

    if orig_IsAddOnLoaded and orig_IsAddOnLoaded("Leatrix_Maps") then
        return
    end

    --------------------------------------------------------------------
    -- Map Icon Parent Sync Helper
    --------------------------------------------------------------------

    -- Name-based classification of WorldMapFrame's children, cached per
    -- frame. A frame's name is immutable, but SyncMapIconParents ran up to
    -- eight string matches against it every 0.3s for the whole session, for
    -- every child. The cache is weak-keyed so frames an addon discards are
    -- not pinned in memory.
    --
    -- The FIELD checks at the call sites (.data/.questId/.discovery/
    -- .itemLink/.itemId) are deliberately NOT cached: pin addons attach
    -- those after the frame is created, so they must stay live.
    --
    -- Plain-text find (the `true` argument) rather than pattern matching —
    -- none of these needles contain magic characters, so the results are
    -- identical and the scan skips the pattern compiler.
    local NAME_CONTROL = { "Mapster", "Option", "DropDown", "Title", "Close", "Track", "Zoom", "Guide" }
    local NAME_PIN = { "Questie", "HBDPin", "HBDDot", "HandyNotes", "GatherMate", "TomTomPin", "LootCollector" }

    local nameClassCache = setmetatable({}, { __mode = "k" })

    local function ClassifyByName(child)
        local cached = nameClassCache[child]
        if cached then return cached end
        local name = child:GetName()
        local verdict = "other"
        if name then
            for i = 1, #NAME_CONTROL do
                if name:find(NAME_CONTROL[i], 1, true) then verdict = "control" break end
            end
            if verdict == "other" then
                for i = 1, #NAME_PIN do
                    if name:find(NAME_PIN[i], 1, true) then verdict = "pin" break end
                end
            end
        end
        nameClassCache[child] = verdict
        return verdict
    end

    -- Same idea for WorldMapButton's children, which only ever ask the one
    -- question. Was two GetName() calls plus a pattern match per child.
    local lootCollectorCache = setmetatable({}, { __mode = "k" })

    local function IsLootCollectorFrame(child)
        local cached = lootCollectorCache[child]
        if cached ~= nil then return cached end
        local name = child:GetName()
        local verdict = (name and name:find("LootCollector", 1, true)) and true or false
        lootCollectorCache[child] = verdict
        return verdict
    end

    local function SyncMapIconParents()
        if not WorldMapButton or not WorldMapFrame then return end
        local detailScale = WorldMapDetailFrame:GetScale() or 1

        -- The game's "Map Filter" button (WorldMapButtonFilters) lives inside
        -- the zoomed map hierarchy, so the zoom/pan engine scales and pans it
        -- off screen. LootCollector's filter button anchors to it and flies
        -- off with it. Reparent it to WorldMapFrame and pin it to the
        -- top-right corner of the map viewport so both stay put while zooming.
        local mapFilterButton = _G["WorldMapButtonFilters"]
        if mapFilterButton then
            if mapFilterButton:GetParent() ~= WorldMapFrame then
                mapFilterButton:SetParent(WorldMapFrame)
                mapFilterButton:ClearAllPoints()
                mapFilterButton:SetPoint("TOPRIGHT", WorldMapScrollFrame, "TOPRIGHT", -10, -2)
            end
            -- Sit above WorldMapButton (the full-map click catcher) or it
            -- swallows all hover/clicks.
            mapFilterButton:SetFrameStrata("FULLSCREEN_DIALOG")
            mapFilterButton:SetToplevel(true)
            if mapFilterButton:GetScale() ~= 1 then
                mapFilterButton:SetScale(1)
            end
        end

        -- LootCollector's map search bar is parented to WorldMapDetailFrame,
        -- so it scales/pans with the zoom engine. Reparent it to
        -- WorldMapFrame and pin it to the bottom of the map viewport.
        local mapSearchFrame = _G["LootCollectorMapSearchFrame"]
        if mapSearchFrame then
            if mapSearchFrame:GetParent() ~= WorldMapFrame then
                mapSearchFrame:SetParent(WorldMapFrame)
                mapSearchFrame:ClearAllPoints()
                mapSearchFrame:SetPoint("BOTTOM", WorldMapScrollFrame, "BOTTOM", 0, 6)
            end
            -- Sit above WorldMapButton (the full-map click catcher) or it
            -- swallows all hover/clicks.
            mapSearchFrame:SetFrameStrata("FULLSCREEN_DIALOG")
            mapSearchFrame:SetToplevel(true)
            if mapSearchFrame:GetScale() ~= 1 then
                mapSearchFrame:SetScale(1)
            end
        end

        local children = { WorldMapFrame:GetChildren() }
        for _, child in ipairs(children) do
            if child ~= WorldMapScrollFrame and child ~= WorldMapDetailFrame and child ~= WorldMapButton and child ~= WorldMapFrameAreaFrame and child ~= coordsFrame and child ~= fadeFrame and child ~= _G["LootCollectorMapSearchFrame"] then
                local verdict = ClassifyByName(child)
                if verdict == "control" then
                    -- UI control frame on WorldMapFrame: DO NOT REPARENT
                elseif verdict == "pin" or child.data or child.questId or child.discovery or child.itemLink or child.itemId then
                    child:SetParent(WorldMapButton)
                end
            end
        end

        local buttonChildren = { WorldMapButton:GetChildren() }
        for _, child in ipairs(buttonChildren) do
            if child ~= WorldMapPOIFrame and child ~= WorldMapBlobFrame and child ~= WorldMapPlayer and child ~= PlayerArrowFrame and child ~= PlayerArrowEffectFrame then
                if child:GetScale() ~= 1 then
                    child:SetScale(1)
                end
                if child.discovery or child.unlootedOutline or (child.texture and child.border) or IsLootCollectorFrame(child) then
                    local targetSize = 16 / detailScale
                    child:SetSize(targetSize, targetSize)
                    if child.border then child.border:SetSize(targetSize, targetSize) end
                    if child.unlootedOutline then child.unlootedOutline:SetSize(targetSize, targetSize) end
                    if child.texture then child.texture:SetSize(targetSize * 0.875, targetSize * 0.875) end
                end
            end
        end
    end

    --------------------------------------------------------------------
    -- Magnify Map Engine (ported from Magnify-WotLK Main.lua)
    --------------------------------------------------------------------

    local PreviousState = {
        panX = 0,
        panY = 0,
        scale = 1,
        zone = 0
    }

    local function updatePointRelativeTo(frame, newRelativeFrame)
        if not frame then return end
        local currentPoint, _currentRelativeFrame, currentRelativePoint, currentOffsetX, currentOffsetY = frame:GetPoint()
        frame:ClearAllPoints()
        frame:SetPoint(currentPoint, newRelativeFrame, currentRelativePoint, currentOffsetX, currentOffsetY)
    end

    local function GetElvUI()
        if ElvUI and ElvUI[1] then return ElvUI[1] end
        return nil
    end

    -- Mapster's addon object, resolved once per map open instead of per
    -- lookup. The old body ran two LibStub:GetLibrary calls plus a GetAddon
    -- on EVERY call — and the callers are the hottest paths in this file:
    -- the player-arrow block fires it once per frame (~180 library lookups
    -- a second with the map open) and resizePOI fires it twice per quest POI.
    -- Only the addon handle is cached; mapster.db.profile is re-read each
    -- call because AceDB swaps that table wholesale on a profile switch, and
    -- a cached reference there would serve the old profile's values.
    local mapsterAddon, mapsterResolved = nil, false

    local function ResolveMapster()
        mapsterResolved = true
        mapsterAddon = nil
        if not (LibStub and LibStub.GetLibrary) then return end
        local ace = LibStub:GetLibrary("AceAddon-3.0", true)
        if not ace then return end
        mapsterAddon = ace:GetAddon("Mapster", true)
    end

    -- Called from WorldMapFrame's OnShow: a Mapster that loaded (or unloaded)
    -- since the last open gets picked up on the next one.
    local function InvalidateMapsterCache()
        mapsterResolved = false
    end

    local function GetMapster(configName)
        if not mapsterResolved then ResolveMapster() end
        local mapster = mapsterAddon
        if not mapster then return nil, nil end
        -- Matches the original contract exactly: a Mapster without a live
        -- profile table reports as absent, so callers never poke its fields.
        local profile = mapster.db and mapster.db.profile
        if not profile then return nil, nil end
        return mapster, profile[configName]
    end

    -- Hoisted out of resizePOI, which reassigned this field per POI button
    -- per quest update — a fresh closure allocated every time for a function
    -- that never varies.
    local MAPSTER_POI_NOOP = function() end

    local function SetPOIMaxBounds()
        local mapSize = WORLDMAP_SETTINGS.size or 1
        local detailHeight = WorldMapDetailFrame:GetHeight() or 1000
        local detailWidth = WorldMapDetailFrame:GetWidth() or 1000
        poiMaxY = detailHeight * -mapSize + 12
        poiMaxX = detailWidth * mapSize + 12
    end

    local function resizePOI(poiButton)
        if not poiButton then return end
        local _, _, _, x, y = poiButton:GetPoint()
        local mapster, mapsterPoiScale = GetMapster("poiScale")
        local _, mapsterQuestObjectives = GetMapster("questObjectives")
        if mapster then
            mapster.WorldMapFrame_DisplayQuestPOI = MAPSTER_POI_NOOP
        end

        local effectivePoiScale = (mapsterPoiScale or 1)
        local posX, posY

        if mapsterQuestObjectives and mapsterQuestObjectives == 1 then
            local questId = poiButton.questId
            if questId then
                local _, normalizedX, normalizedY = QuestPOIGetIconInfo(questId)
                if normalizedX and normalizedY then
                    posX = normalizedX * WorldMapDetailFrame:GetWidth() * WORLDMAP_SETTINGS.size
                    posY = -normalizedY * WorldMapDetailFrame:GetHeight() * WORLDMAP_SETTINGS.size
                end
            end
            if not posX and x ~= nil and y ~= nil then
                posX = x
                posY = y
            end
        elseif x ~= nil and y ~= nil then
            posX = x
            posY = y
        end

        if posX and posY then
            local s = WORLDMAP_SETTINGS.size / WorldMapDetailFrame:GetEffectiveScale() * effectivePoiScale
            posX = posX / s
            posY = posY / s
            poiButton:SetScale(s)
            poiButton:SetPoint("CENTER", poiButton:GetParent(), "TOPLEFT", posX, posY)

            if poiMaxX == nil or poiMaxY == nil then SetPOIMaxBounds() end

            if posY > WORLDMAP_POI_MIN_Y then
                posY = WORLDMAP_POI_MIN_Y
            elseif poiMaxY and posY < poiMaxY then
                posY = poiMaxY
            end
            if posX < WORLDMAP_POI_MIN_X then
                posX = WORLDMAP_POI_MIN_X
            elseif poiMaxX and posX > poiMaxX then
                posX = poiMaxX
            end
        end
    end

    local function PersistMapScrollAndPan()
        PreviousState.panX = WorldMapScrollFrame:GetHorizontalScroll()
        PreviousState.panY = WorldMapScrollFrame:GetVerticalScroll()
        PreviousState.scale = WorldMapDetailFrame:GetScale()
        PreviousState.zone = GetCurrentMapZone()
    end

    -- DrawQuestBlob re-tessellates the selected quest's area polygon, and it
    -- is called twice per redraw. The pan handler runs once per frame while
    -- the mouse is held, so an unthrottled pan was ~120 tessellations a
    -- second — by far the heaviest thing on the map's hot path.
    --
    -- Position state (PersistMapScrollAndPan) stays per-frame: it is four
    -- cheap getters and the restore-on-reopen path needs it exact. Only the
    -- blob redraw is rate-limited, and a flush on mouse-up guarantees the
    -- final resting position is always drawn. Discrete callers (mousewheel
    -- zoom, click-to-zoom-out) keep redrawing immediately — they fire at
    -- most once per input, so throttling them would only add latency.
    local BLOB_REDRAW_INTERVAL = 1 / 16
    local lastBlobRedraw, blobPending = 0, false

    local function RedrawQuestBlob()
        if InCombatLockdown() then return end
        if not WORLDMAP_SETTINGS.selectedQuest then return end
        WorldMapBlobFrame:DrawQuestBlob(WORLDMAP_SETTINGS.selectedQuestId, false)
        WorldMapBlobFrame:DrawQuestBlob(WORLDMAP_SETTINGS.selectedQuestId, true)
    end

    local function AfterScrollOrPan()
        PersistMapScrollAndPan()
        lastBlobRedraw = GetTime()
        blobPending = false
        RedrawQuestBlob()
    end

    -- Per-frame pan step: persist always, redraw at most every 1/16s.
    local function AfterPanStep()
        PersistMapScrollAndPan()
        local now = GetTime()
        if now - lastBlobRedraw < BLOB_REDRAW_INTERVAL then
            blobPending = true
            return
        end
        lastBlobRedraw = now
        blobPending = false
        RedrawQuestBlob()
    end

    -- Mouse-up: draw the blob at the final pan position if the last step was
    -- throttled out, so releasing the drag never leaves it a frame behind.
    local function FlushPendingBlob()
        if not blobPending then return end
        blobPending = false
        lastBlobRedraw = GetTime()
        RedrawQuestBlob()
    end

    -- The 100 POI button names, built once. ResizeQuestPOIs runs on every
    -- WorldMapFrame_UpdateQuests pass and used to rebuild all 100 of these
    -- strings (two concatenations each) per pass, most of them only to look
    -- up a slot Blizzard hasn't populated. The names never change, so the
    -- concatenation is pure waste; _G is still the lookup source because the
    -- QuestPOI system creates these buttons lazily, well after this file runs.
    local POI_BUTTON_NAMES = {}
    do
        local QUEST_POI_MAX_TYPES = 4
        local POI_TYPE_MAX_BUTTONS = 25
        for i = 1, QUEST_POI_MAX_TYPES do
            for j = 1, POI_TYPE_MAX_BUTTONS do
                POI_BUTTON_NAMES[#POI_BUTTON_NAMES + 1] =
                    "poiWorldMapPOIFrame" .. i .. "_" .. j
            end
        end
    end

    local function ResizeQuestPOIs()
        if poiMaxX == nil or poiMaxY == nil then SetPOIMaxBounds() end

        for n = 1, #POI_BUTTON_NAMES do
            local button = _G[POI_BUTTON_NAMES[n]]
            if button then resizePOI(button) end
        end

        if QUEST_POI_SWAP_BUTTONS then
            resizePOI(QUEST_POI_SWAP_BUTTONS["WorldMapPOIFrame"])
        end
    end

    local function RedrawSelectedQuest()
        if WORLDMAP_SETTINGS.selectedQuestId then
            WorldMapFrame_SelectQuestById(WORLDMAP_SETTINGS.selectedQuestId)
        else
            WorldMapFrame_SelectQuestFrame(_G["WorldMapQuestFrame1"])
        end
    end

    local function SetDetailFrameScale(num)
        WorldMapDetailFrame:SetScale(num)
        SetPOIMaxBounds()

        WorldMapPOIFrame:SetScale(1 / WORLDMAP_SETTINGS.size)
        WorldMapBlobFrame:SetScale(num)

        WorldMapPlayer:SetScale(1 / WorldMapDetailFrame:GetScale())
        WorldMapDeathRelease:SetScale(1 / WorldMapDetailFrame:GetScale())
        if PlayerArrowFrame then PlayerArrowFrame:SetScale(1 / WorldMapDetailFrame:GetScale()) end
        if PlayerArrowEffectFrame then PlayerArrowEffectFrame:SetScale(1 / WorldMapDetailFrame:GetScale()) end
        WorldMapCorpse:SetScale(1 / WorldMapDetailFrame:GetScale())

        local numFlags = GetNumBattlefieldFlagPositions()
        for i = 1, numFlags do
            local flagFrameName = "WorldMapFlag" .. i
            if _G[flagFrameName] then _G[flagFrameName]:SetScale(1 / WorldMapDetailFrame:GetScale()) end
        end

        -- Cached frame lists; the old form also looked each name up twice
        -- (once to test, once to scale).
        local invScale = 1 / WorldMapDetailFrame:GetScale()
        for i = 1, #partyFrames do
            local f = partyFrames[i]
            if f then f:SetScale(invScale) end
        end

        for i = 1, #raidFrames do
            local f = raidFrames[i]
            if f then f:SetScale(invScale) end
        end

        for i = 1, #MAP_VEHICLES do
            if MAP_VEHICLES[i] then MAP_VEHICLES[i]:SetScale(1 / WorldMapDetailFrame:GetScale()) end
        end

        WorldMapFrame_OnEvent(WorldMapFrame, "DISPLAY_SIZE_CHANGED")
        if WorldMapFrame_UpdateQuests() > 0 then
            RedrawSelectedQuest()
        end
    end

    local function ElvUI_SetupWorldMapFrame()
        local elv = GetElvUI()
        if not elv then return end
        local worldMap = elv:GetModule("WorldMap")
        if not worldMap then return end

        if worldMap.coordsHolder and worldMap.coordsHolder.playerCoords then
            updatePointRelativeTo(worldMap.coordsHolder.playerCoords, WorldMapScrollFrame)
        end

        if WorldMapDetailFrame.backdrop then
            WorldMapDetailFrame.backdrop:Hide()
            if WorldMapFrame.backdrop then
                local _, worldMapRelativeFrame = WorldMapFrame.backdrop:GetPoint()
                if worldMapRelativeFrame == WorldMapDetailFrame then
                    updatePointRelativeTo(WorldMapFrame.backdrop, WorldMapScrollFrame)
                end
            end
        end

        if WorldMapFrame.backdrop then
            WorldMapFrame.backdrop:ClearAllPoints()
            if WorldMapZoneMinimapDropDown:IsVisible() then
                WorldMapFrame.backdrop:SetPoint("TOPLEFT", WorldMapZoneMinimapDropDown, "TOPLEFT", -20, 40)
            else
                WorldMapFrame.backdrop:SetPoint("TOPLEFT", WorldMapTitleButton, "TOPLEFT", 0, 0)
            end
            WorldMapFrame.backdrop:SetPoint("BOTTOM", WorldMapQuestShowObjectives, "BOTTOM", 0, 0)
            WorldMapFrame.backdrop:SetPoint("RIGHT", WorldMapFrameCloseButton, "RIGHT", 0, 0)
        end
    end

    local setupDeferred
    local function SetupWorldMapFrame()
        if InCombatLockdown() then
            setupDeferred = true
            return
        end
        setupDeferred = nil

        WorldMapFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        if WorldMapTooltip then
            WorldMapTooltip:SetFrameStrata("TOOLTIP")
            WorldMapTooltip:SetFrameLevel(2000)
        end
        if WorldMapCompareTooltip1 then
            WorldMapCompareTooltip1:SetFrameStrata("TOOLTIP")
            WorldMapCompareTooltip1:SetFrameLevel(2000)
        end
        if WorldMapCompareTooltip2 then
            WorldMapCompareTooltip2:SetFrameStrata("TOOLTIP")
            WorldMapCompareTooltip2:SetFrameLevel(2000)
        end

        local scrollBar = _G["WorldMapScrollFrameScrollBar"]
        if scrollBar then scrollBar:Hide() end
        WorldMapScrollFrame.panning = false
        WorldMapScrollFrame.moved = false

        if WORLDMAP_SETTINGS.size == WORLDMAP_QUESTLIST_SIZE then
            WorldMapScrollFrame:SetPoint("TOPLEFT", WorldMapPositioningGuide, "TOP", -726, -99)
            WorldMapTrackQuest:SetPoint("BOTTOMLEFT", WorldMapPositioningGuide, "BOTTOMLEFT", 8, 4)
        elseif WORLDMAP_SETTINGS.size == WORLDMAP_WINDOWED_SIZE then
            WorldMapTrackQuest:SetPoint("BOTTOMLEFT", WorldMapPositioningGuide, "BOTTOMLEFT", 16, -9)

            WorldMapFrame:SetPoint("TOPLEFT", WorldMapScreenAnchor, 0, 0)
            WorldMapFrame:SetScale(WorldMapScreenAnchor.preferredMinimodeScale)
            WorldMapFrame:SetMovable(true)
            WorldMapTitleButton:Show()
            WorldMapTitleButton:ClearAllPoints()
            WorldMapFrameTitle:Show()
            WorldMapFrameTitle:ClearAllPoints()
            WorldMapFrameTitle:SetPoint("CENTER", WorldMapTitleButton, "CENTER", 32, 0)

            if WORLDMAP_SETTINGS.advanced then
                WorldMapScrollFrame:SetPoint("TOPLEFT", 19, -42)
                WorldMapTitleButton:SetPoint("TOPLEFT", WorldMapFrame, "TOPLEFT", 13, 0)
            else
                WorldMapScrollFrame:SetPoint("TOPLEFT", 37, -66)
                WorldMapTitleButton:SetPoint("TOPLEFT", WorldMapFrame, "TOPLEFT", 13, -14)
            end
        else
            WorldMapScrollFrame:SetPoint("TOPLEFT", WorldMapPositioningGuide or WorldMapFrame, "TOPLEFT", 11, -70.5)
            WorldMapTrackQuest:SetPoint("BOTTOMLEFT", WorldMapPositioningGuide or WorldMapFrame, "BOTTOMLEFT", 16, -9)
        end

        WorldMapScrollFrame:SetScale(WORLDMAP_SETTINGS.size)

        SetDetailFrameScale(1)
        WorldMapDetailFrame:SetAllPoints(WorldMapScrollFrame)
        WorldMapScrollFrame:SetHorizontalScroll(0)
        WorldMapScrollFrame:SetVerticalScroll(0)

        if GetCurrentMapZone() == PreviousState.zone and PreviousState.scale and PreviousState.scale > 1 then
            SetDetailFrameScale(PreviousState.scale)
            WorldMapScrollFrame:SetHorizontalScroll(PreviousState.panX)
            WorldMapScrollFrame:SetVerticalScroll(PreviousState.panY)
        end

        WorldMapButton:SetScale(1)
        WorldMapButton:SetAllPoints(WorldMapDetailFrame)
        WorldMapButton:SetParent(WorldMapDetailFrame)

        if not InCombatLockdown() then
            if WorldMapPOIFrame:GetParent() ~= WorldMapDetailFrame then WorldMapPOIFrame:SetParent(WorldMapDetailFrame) end
            if WorldMapBlobFrame:GetParent() ~= WorldMapDetailFrame then
                WorldMapBlobFrame:SetParent(WorldMapDetailFrame)
                WorldMapBlobFrame:ClearAllPoints()
                WorldMapBlobFrame:SetAllPoints(WorldMapDetailFrame)
            end
            if WorldMapPlayer:GetParent() ~= WorldMapDetailFrame then WorldMapPlayer:SetParent(WorldMapDetailFrame) end
            if PlayerArrowFrame and PlayerArrowFrame:GetParent() ~= WorldMapDetailFrame then
                PlayerArrowFrame:SetParent(WorldMapDetailFrame)
            end
            if PlayerArrowEffectFrame and PlayerArrowEffectFrame:GetParent() ~= WorldMapDetailFrame then
                PlayerArrowEffectFrame:SetParent(WorldMapDetailFrame)
            end

            for i = 1, #partyFrames do
                local partyFrame = partyFrames[i]
                if partyFrame and partyFrame:GetParent() ~= WorldMapDetailFrame then
                    partyFrame:SetParent(WorldMapDetailFrame)
                end
            end
            for i = 1, #raidFrames do
                local raidFrame = raidFrames[i]
                if raidFrame and raidFrame:GetParent() ~= WorldMapDetailFrame then
                    raidFrame:SetParent(WorldMapDetailFrame)
                end
            end

            SyncMapIconParents()
        end

        updatePointRelativeTo(WorldMapQuestScrollFrame, WorldMapScrollFrame)
        updatePointRelativeTo(WorldMapQuestDetailScrollFrame, WorldMapScrollFrame)

        if GetElvUI() then ElvUI_SetupWorldMapFrame() end
    end

    local function WorldMapScrollFrame_OnPan(cursorX, cursorY)
        local dX = WorldMapScrollFrame.cursorX - cursorX
        local dY = cursorY - WorldMapScrollFrame.cursorY
        local effScale = WorldMapButton:GetEffectiveScale()
        if effScale and effScale > 0 then
            dX = dX / effScale
            dY = dY / effScale
        end
        if abs(dX) >= 1 or abs(dY) >= 1 then
            WorldMapScrollFrame.moved = true

            local x = max(0, dX + WorldMapScrollFrame.x)
            x = min(x, WorldMapScrollFrame.maxX or x)
            WorldMapScrollFrame:SetHorizontalScroll(x)

            local y = max(0, dY + WorldMapScrollFrame.y)
            y = min(y, WorldMapScrollFrame.maxY or y)
            WorldMapScrollFrame:SetVerticalScroll(y)
            AfterPanStep() -- rate-limited blob redraw; flushed on mouse-up
        end
    end

    -- This runs per shown group member on a 20 Hz clock while the map is
    -- open, so cache the class color per unit token and only touch the
    -- textures when the shown state actually changes. Without both halves
    -- a 40-man raid cost ~800 UnitClass calls and ~2400 redundant
    -- Show/Hide/SetVertexColor calls a second, every one of them redrawing
    -- a dot to the colour it already was.
    --
    -- FAILURES ARE NOT CACHED: UnitClass returns nil until the server has
    -- sent that member's class (right after login or joining), and caching
    -- the miss pinned every dot white until the next roster change.
    -- Ascension's client extends RAID_CLASS_COLORS with the CoA class
    -- tokens; CUSTOM_CLASS_COLORS is checked as a fallback for clients or
    -- addons that supply it instead.
    local classColorCache = {}
    local rosterWatcher = CreateFrame("Frame")
    rosterWatcher:RegisterEvent("PARTY_MEMBERS_CHANGED")
    rosterWatcher:RegisterEvent("RAID_ROSTER_UPDATE")
    rosterWatcher:SetScript("OnEvent", function()
        for k in pairs(classColorCache) do classColorCache[k] = nil end
    end)

    local function ColorWorldMapPartyMemberFrame(partyMemberFrame, unit)
        local classColor = unit and classColorCache[unit]
        if classColor == nil and unit then
            local token = select(2, UnitClass(unit))
            local color = token and (RAID_CLASS_COLORS[token]
                or (_G.CUSTOM_CLASS_COLORS and _G.CUSTOM_CLASS_COLORS[token]))
            if color then
                classColorCache[unit] = color
                classColor = color
            end
        end
        -- Dirty check: the colour object doubles as the state key, so a dot
        -- that is already showing this class's colour costs one comparison.
        local wantColor = (classColor and Qol("mapClassIcons")) and classColor or nil
        if partyMemberFrame.refactorShownColor == wantColor then return end
        partyMemberFrame.refactorShownColor = wantColor
        if wantColor then
            if partyMemberFrame.colorIcon then
                partyMemberFrame.colorIcon:Show()
                partyMemberFrame.colorIcon:SetVertexColor(wantColor.r, wantColor.g, wantColor.b, 1)
            end
            if partyMemberFrame.icon then partyMemberFrame.icon:Hide() end
        else
            if partyMemberFrame.colorIcon then partyMemberFrame.colorIcon:Hide() end
            if partyMemberFrame.icon then partyMemberFrame.icon:Show() end
        end
    end

    local mapUpdateAccum = 0
    local mapIconSyncAccum = 0
    local mapUnitTooltipShown = false
    local mapUnitTooltipAnchor = nil
    local function WorldMapButton_OnUpdate(self, elapsed)
        -- Geometry is read once and shared by the player-arrow and group-dot
        -- blocks below; both used to fetch the identical three values
        -- separately in the same call.
        local detailWidth = WorldMapDetailFrame:GetWidth()
        local detailHeight = WorldMapDetailFrame:GetHeight()
        local scale = WorldMapDetailFrame:GetScale()

        -- Group dot positions run FIRST and unconditionally — they are not
        -- gated on mapZoom/mapClassIcons. The stock WorldMapButton OnUpdate
        -- (still called as the original handler) re-points every
        -- WorldMapParty*/WorldMapRaid* frame every frame using math that
        -- assumes WorldMapDetailFrame scale 1 — but SetDetailFrameScale gives
        -- those frames SetScale(1/detailScale), so under zoom stock's offsets
        -- land off by scale² and the dot flies off the map. Correcting on a
        -- 20 Hz clock meant stock won two frames out of three: that was the
        -- reported flicker + "icons outside the map when zoomed in". The
        -- correction must overwrite stock in the same frame stock wrote.
        --
        -- This block used to sit BELOW the mapZoom/mapClassIcons early return,
        -- which silently contradicted the "never gated" rule above it: with
        -- both flags off the dots were left at stock's wrong position. The
        -- zoom engine is installed regardless of the flags, so the correction
        -- has to be too.
        --
        -- Not gated on WorldMapScrollFrame.zoomedIn either: that flag is only
        -- assigned in the mousewheel/mouseup handlers, so a zoom restored by
        -- SetupWorldMapFrame (PreviousState.scale) leaves it false and the
        -- dots stay pinned at stock's wrong point. At scale 1 this math is
        -- identical to stock's, so running unconditionally costs nothing.
        local isRaid = GetNumRaidMembers() > 0
        local frames = isRaid and raidFrames or partyFrames
        local units = isRaid and raidUnits or partyUnits

        -- Name-on-hover tooltip for the dots: stock's own WorldMapUnit_OnEnter
        -- never fires here because reparenting every full-map frame onto
        -- WorldMapDetailFrame as flat siblings (SetupWorldMapFrame, above)
        -- collapses the sibling group the dots' frame level was computed
        -- relative to, so something else in that group now wins native mouse
        -- focus over them. Rather than chase that focus-priority fight (this
        -- file is exactly the kind of frame-level/z-order code past commits
        -- have silently broken), IsMouseOver() is a pure bounding-box test
        -- unaffected by focus-stealing, so it's checked directly in the same
        -- per-frame pass that already repositions every dot. Reuses the
        -- stock WorldMapTooltip object (its strata/level is already forced
        -- above the windowed map by this file, above) and only closes a
        -- tooltip this code itself opened, so it never fights anything else
        -- that might legitimately own WorldMapTooltip.
        local hoveredNames = nil
        for i = 1, #frames do
            local icon = frames[i]
            if icon and icon:IsShown() then
                local unit = (isRaid and icon.unit) or units[i]
                if unit and UnitExists(unit) then
                    local x, y = GetPlayerMapPosition(unit)
                    if x and y and x > 0 and y > 0 then
                        icon:ClearAllPoints()
                        icon:SetPoint("CENTER", WorldMapDetailFrame, "TOPLEFT", x * detailWidth * scale, -y * detailHeight * scale)
                    end
                end
                if icon:IsMouseOver() then
                    local label = icon.name or (icon.unit and UnitName(icon.unit))
                    if label then
                        hoveredNames = hoveredNames and (hoveredNames .. "\n" .. label) or label
                        mapUnitTooltipAnchor = icon
                    end
                end
            end
        end

        if hoveredNames then
            local cx = mapUnitTooltipAnchor:GetCenter()
            local px = WorldMapDetailFrame:GetCenter()
            WorldMapTooltip:SetOwner(mapUnitTooltipAnchor, (cx and px and cx > px) and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
            WorldMapTooltip:SetText(hoveredNames)
            WorldMapTooltip:Show()
            mapUnitTooltipShown = true
        elseif mapUnitTooltipShown then
            WorldMapTooltip:Hide()
            mapUnitTooltipShown = false
        end

        if not Qol("mapZoom") and not Qol("mapClassIcons") then return end

        if WorldMapScrollFrame.panning then
            WorldMapScrollFrame_OnPan(GetCursorPosition())
        end

        -- Pin-addon child list only churns when another addon adds/removes a
        -- pin frame, not on player movement, so it gets its own slower clock
        -- independent of the position-update cadence below.
        mapIconSyncAccum = mapIconSyncAccum + (elapsed or 0)
        if mapIconSyncAccum >= 0.3 then
            mapIconSyncAccum = 0
            SyncMapIconParents()
        end

        -- Player arrow stays per-frame and must NOT be throttled: the stock
        -- WorldMapButton OnUpdate (still called as the original handler
        -- above) re-Show()s PlayerArrowFrame every frame, so suppressing it
        -- on a slower clock makes the arrow flicker. Rotation is per-frame
        -- for the same reason smoothness demands it. The block is a handful
        -- of C calls; the real cost this function had was the scans below.
        local playerX, playerY = GetPlayerMapPosition("player")
        if not (playerX == 0 and playerY == 0) then
            local _, mapsterArrowScale = GetMapster("arrowScale")
            if WorldMapPlayer.Icon then
                WorldMapPlayer.Icon:SetRotation(PlayerArrowFrame:GetFacing())
                WorldMapPlayer.Icon:SetSize(PLAYER_ARROW_SIZE * (mapsterArrowScale or 1), PLAYER_ARROW_SIZE * (mapsterArrowScale or 1))
            end
            WorldMapPlayer:ClearAllPoints()
            WorldMapPlayer:SetPoint("CENTER", WorldMapDetailFrame, "TOPLEFT", playerX * detailWidth * scale, -playerY * detailHeight * scale)

            if PlayerArrowFrame then PlayerArrowFrame:Hide() end
            if PlayerArrowEffectFrame then PlayerArrowEffectFrame:Hide() end
            if WorldMapPlayer.Player then WorldMapPlayer.Player:Hide() end
            if WorldMapPlayer.texture then WorldMapPlayer.texture:Hide() end
        end

        -- Class coloring is idempotent and fights nothing per-frame, so it
        -- keeps the slower clock — this is the expensive O(40) half.
        mapUpdateAccum = mapUpdateAccum + (elapsed or 0)
        if mapUpdateAccum < 0.05 then return end
        mapUpdateAccum = 0

        if Qol("mapClassIcons") then
            if isRaid then
                for i = 1, #raidFrames do
                    local f = raidFrames[i]
                    if f and f:IsVisible() and f.unit then ColorWorldMapPartyMemberFrame(f, f.unit) end
                end
            else
                for i = 1, #partyFrames do
                    local f = partyFrames[i]
                    if f and f:IsVisible() then ColorWorldMapPartyMemberFrame(f, partyUnits[i]) end
                end
            end
        end
    end

    local function WorldMapScrollFrame_OnMouseWheel(self, delta)
        if not Qol("mapZoom") then return end
        if InCombatLockdown() then return end

        if IsControlKeyDown() and WORLDMAP_SETTINGS.size == WORLDMAP_WINDOWED_SIZE then
            local oldScale = WorldMapFrame:GetScale()
            local newScale = oldScale + delta * MINIMODE_ZOOM_STEP
            newScale = max(MINIMODE_MIN_ZOOM, newScale)
            newScale = min(MINIMODE_MAX_ZOOM, newScale)

            WorldMapFrame:SetScale(newScale)
            WorldMapScreenAnchor.preferredMinimodeScale = newScale
            return
        end

        local oldScrollH = WorldMapScrollFrame:GetHorizontalScroll()
        local oldScrollV = WorldMapScrollFrame:GetVerticalScroll()

        local cursorX, cursorY = GetCursorPosition()
        cursorX = cursorX / WorldMapScrollFrame:GetEffectiveScale()
        cursorY = cursorY / WorldMapScrollFrame:GetEffectiveScale()

        local frameX = cursorX - WorldMapScrollFrame:GetLeft()
        local frameY = WorldMapScrollFrame:GetTop() - cursorY

        local oldScale = WorldMapDetailFrame:GetScale()
        local newScale = oldScale * (1.0 + delta * ZOOM_STEP)
        newScale = max(MIN_ZOOM, newScale)
        newScale = min(MAX_ZOOM, newScale)

        SetDetailFrameScale(newScale)

        WorldMapScrollFrame.maxX = ((WorldMapDetailFrame:GetWidth() * newScale) - WorldMapScrollFrame:GetWidth()) / newScale
        WorldMapScrollFrame.maxY = ((WorldMapDetailFrame:GetHeight() * newScale) - WorldMapScrollFrame:GetHeight()) / newScale
        WorldMapScrollFrame.zoomedIn = WorldMapDetailFrame:GetScale() > MIN_ZOOM

        local centerX = oldScrollH + frameX / oldScale
        local centerY = oldScrollV + frameY / oldScale
        local newScrollH = centerX - frameX / newScale
        local newScrollV = centerY - frameY / newScale

        newScrollH = min(newScrollH, WorldMapScrollFrame.maxX)
        newScrollH = max(0, newScrollH)
        newScrollV = min(newScrollV, WorldMapScrollFrame.maxY)
        newScrollV = max(0, newScrollV)

        WorldMapScrollFrame:SetHorizontalScroll(newScrollH)
        WorldMapScrollFrame:SetVerticalScroll(newScrollV)
        AfterScrollOrPan()
    end

    local function WorldMapButton_OnMouseDown(self, button)
        if not Qol("mapZoom") then return end
        if button == 'LeftButton' and WorldMapScrollFrame.zoomedIn then
            WorldMapScrollFrame.panning = true
            local x, y = GetCursorPosition()
            WorldMapScrollFrame.cursorX = x
            WorldMapScrollFrame.cursorY = y
            WorldMapScrollFrame.x = WorldMapScrollFrame:GetHorizontalScroll()
            WorldMapScrollFrame.y = WorldMapScrollFrame:GetVerticalScroll()
            WorldMapScrollFrame.moved = false
        end
    end

    local function WorldMapButton_OnMouseUp(self, button)
        WorldMapScrollFrame.panning = false

        if not WorldMapScrollFrame.moved then
            WorldMapButton_OnClick(WorldMapButton, button)

            if Qol("mapZoom") and WorldMapScrollFrame.zoomedIn and not InCombatLockdown() then
                SetDetailFrameScale(MIN_ZOOM)
                WorldMapScrollFrame:SetHorizontalScroll(0)
                WorldMapScrollFrame:SetVerticalScroll(0)
                AfterScrollOrPan()
                WorldMapScrollFrame.zoomedIn = false
            end
        else
            -- Drag ended: the last pan step may have been inside the blob
            -- throttle window, so draw once more at the resting position.
            FlushPendingBlob()
        end

        WorldMapScrollFrame.moved = false
    end

    local function CreateClassColorIcon(partyMemberFrame)
        if partyMemberFrame then
            partyMemberFrame.colorIcon = partyMemberFrame:CreateTexture(nil, "ARTWORK")
            partyMemberFrame.colorIcon:SetAllPoints(partyMemberFrame)
            partyMemberFrame.colorIcon:SetTexture("Interface\\AddOns\\Refactor\\textures\\WorldMapPlayer")
            if partyMemberFrame.icon then partyMemberFrame.icon:Hide() end
        end
    end

    -- Initial setup
    WorldMapScrollFrame:SetScrollChild(WorldMapDetailFrame)
    WorldMapScrollFrame:SetScript("OnMouseWheel", WorldMapScrollFrame_OnMouseWheel)
    WorldMapButton:SetScript("OnMouseDown", WorldMapButton_OnMouseDown)
    WorldMapButton:SetScript("OnMouseUp", WorldMapButton_OnMouseUp)
    WorldMapDetailFrame:SetParent(WorldMapScrollFrame)

    WorldMapFrameAreaFrame:SetParent(WorldMapFrame)
    WorldMapFrameAreaFrame:SetFrameLevel(WORLDMAP_POI_FRAMELEVEL or 10)
    WorldMapFrameAreaFrame:SetPoint("TOP", WorldMapScrollFrame, "TOP", 0, -10)

    WorldMapPing:Hide()
    WorldMapPing:SetScript("OnShow", WorldMapPing.Hide)
    WorldMapPing:SetModelScale(0)

    WorldMapPlayer.Icon = WorldMapPlayer:CreateTexture(nil, "ARTWORK")
    WorldMapPlayer.Icon:SetSize(PLAYER_ARROW_SIZE, PLAYER_ARROW_SIZE)
    WorldMapPlayer.Icon:SetPoint("CENTER", 0, 0)
    WorldMapPlayer.Icon:SetTexture("Interface\\AddOns\\Refactor\\textures\\WorldMapArrow")

    if WorldMapPlayer.Player then WorldMapPlayer.Player:Hide() end
    if WorldMapPlayer.texture then WorldMapPlayer.texture:Hide() end

    if PlayerArrowFrame then
        PlayerArrowFrame:Hide()
        PlayerArrowFrame:SetScript("OnShow", PlayerArrowFrame.Hide)
    end
    if PlayerArrowEffectFrame then
        PlayerArrowEffectFrame:Hide()
        PlayerArrowEffectFrame:SetScript("OnShow", PlayerArrowEffectFrame.Hide)
    end

    hooksecurefunc("WorldMapFrame_SetFullMapView", SetupWorldMapFrame)
    hooksecurefunc("WorldMapFrame_SetQuestMapView", SetupWorldMapFrame)
    hooksecurefunc("WorldMap_ToggleSizeDown", SetupWorldMapFrame)
    hooksecurefunc("WorldMap_ToggleSizeUp", SetupWorldMapFrame)
    hooksecurefunc("WorldMapFrame_UpdateQuests", ResizeQuestPOIs)

    hooksecurefunc("WorldMapQuestShowObjectives_AdjustPosition", function()
        if WORLDMAP_SETTINGS.size == WORLDMAP_WINDOWED_SIZE then
            WorldMapQuestShowObjectives:SetPoint("BOTTOMRIGHT", WorldMapPositioningGuide or WorldMapFrame, "BOTTOMRIGHT", -30 - WorldMapQuestShowObjectivesText:GetWidth(), -9)
        else
            WorldMapQuestShowObjectives:SetPoint("BOTTOMRIGHT", WorldMapPositioningGuide or WorldMapFrame, "BOTTOMRIGHT", -15 - WorldMapQuestShowObjectivesText:GetWidth(), 4)
        end
    end)

    WorldMapScreenAnchor:StartMoving()
    WorldMapScreenAnchor:SetPoint("TOPLEFT", 10, -118)
    WorldMapScreenAnchor:StopMovingOrSizing()

    WorldMapScreenAnchor.preferredMinimodeScale = 1 + (0.4 * WorldMapFrame:GetHeight() / WorldFrame:GetHeight())

    WorldMapTitleButton:SetScript("OnDragStart", function()
        WorldMapScreenAnchor:ClearAllPoints()
        WorldMapFrame:ClearAllPoints()
        WorldMapFrame:StartMoving()
    end)

    WorldMapTitleButton:SetScript("OnDragStop", function()
        WorldMapFrame:StopMovingOrSizing()
        WorldMapScreenAnchor:StartMoving()
        WorldMapScreenAnchor:SetPoint("TOPLEFT", WorldMapFrame)
        WorldMapScreenAnchor:StopMovingOrSizing()
    end)

    local original_WorldMapButton_OnUpdate = WorldMapButton:GetScript("OnUpdate")
    WorldMapButton:SetScript("OnUpdate", function(self, elapsed)
        if original_WorldMapButton_OnUpdate then original_WorldMapButton_OnUpdate(self, elapsed) end
        WorldMapButton_OnUpdate(self, elapsed)
    end)

    local original_WorldMapFrame_OnShow = WorldMapFrame:GetScript("OnShow")
    WorldMapFrame:SetScript("OnShow", function(self)
        if original_WorldMapFrame_OnShow then original_WorldMapFrame_OnShow(self) end
        -- Map open is the re-check boundary for the Mapster handle: it can
        -- only appear or disappear between opens, never mid-frame.
        InvalidateMapsterCache()
        SetupWorldMapFrame()
    end)

    -- Walks the cached frame lists instead of rebuilding 80 global names.
    -- (The old loop also ran WorldMapParty1..40 against a list that only
    -- goes to MAX_PARTY_MEMBERS, so 36 of its 40 party lookups were nil.)
    for i = 1, #partyFrames do CreateClassColorIcon(partyFrames[i]) end
    for i = 1, #raidFrames do CreateClassColorIcon(raidFrames[i]) end

    local combatWatcher = CreateFrame("Frame")
    combatWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
    combatWatcher:SetScript("OnEvent", function()
        if setupDeferred then SetupWorldMapFrame() end
    end)
end

if orig_IsAddOnLoaded and orig_IsAddOnLoaded("Blizzard_WorldMap") or WorldMapFrame then
    InitRefactorMap()
else
    local loadFrame = CreateFrame("Frame")
    loadFrame:RegisterEvent("ADDON_LOADED")
    loadFrame:SetScript("OnEvent", function(self, event, addonName)
        if addonName == "Blizzard_WorldMap" or WorldMapFrame then
            self:UnregisterEvent("ADDON_LOADED")
            InitRefactorMap()
        end
    end)
end
