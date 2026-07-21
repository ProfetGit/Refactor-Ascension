--------------------------------------------------------------------------
-- Refactor: seamless bag upgrade. Right-clicking a bag while all 4 bag
-- slots are full normally just errors ("no free bag slot"). When the flag
-- is on we instead: find the equipped bag with the fewest slots, relocate
-- its contents into free slots elsewhere, equip the new bag in its place,
-- and park the now-empty old bag in the slot that was freed up.
--
-- Every step that touches an item slot (PickupContainerItem,
-- PickupInventoryItem) is a server round trip: the slots involved go
-- "locked" until the server confirms, and issuing the next pickup before
-- that resolves desyncs the cursor. So this runs as a single-item-at-a-time
-- queue driven by BAG_UPDATE/ITEM_LOCK_CHANGED, never more than one
-- in-flight swap.
--------------------------------------------------------------------------

do
    local bu = nil -- non-nil while a swap sequence is in flight
    local buFrame = CreateFrame("Frame")
    local BU_TIMEOUT = 8 -- seconds; a slot that never unlocks means the server rejected the move

    local function SlotLocked(bag, slot)
        return select(3, GetContainerItemInfo(bag, slot)) and true or false
    end

    local function SlotEmpty(bag, slot)
        return GetContainerItemLink(bag, slot) == nil
    end

    local function ItemFamily(link)
        return (link and GetItemFamily(link)) or 0
    end

    -- A destination slot in `bag` can take `itemFamily` if the bag is a
    -- plain bag (family 0, including the backpack) or the families overlap
    -- bitwise (soul bags, quivers, herb bags, etc).
    local function FamilyFits(bagFamily, itemFamily)
        return bagFamily == 0 or itemFamily == 0 or bit.band(bagFamily, itemFamily) ~= 0
    end

    local function StopBagUpgrade(errMsg)
        if errMsg then UIErrorsFrame:AddMessage(errMsg, 1, 0.1, 0.1) end
        bu = nil
        buFrame:UnregisterEvent("BAG_UPDATE")
        buFrame:UnregisterEvent("ITEM_LOCK_CHANGED")
        buFrame:SetScript("OnUpdate", nil)
    end

    local function StepBagUpgrade()
        if not bu then return end

        if bu.phase == "moving" then
            local mv = bu.moves[1]
            if not mv then
                bu.phase = "equip"
                return StepBagUpgrade()
            end
            if SlotEmpty(mv.fromBag, mv.fromSlot) then
                table.remove(bu.moves, 1) -- this move already landed
                return StepBagUpgrade()
            end
            if SlotLocked(mv.fromBag, mv.fromSlot) or SlotLocked(mv.toBag, mv.toSlot) then
                return -- still resolving the previous pickup, wait for the next event
            end
            PickupContainerItem(mv.fromBag, mv.fromSlot)
            PickupContainerItem(mv.toBag, mv.toSlot)
            return

        elseif bu.phase == "equip" then
            if GetInventoryItemLink("player", bu.targetInvSlot) ~= bu.oldBagLink then
                -- old bag link changed: the equip swap already landed
                bu.phase = "park"
                return StepBagUpgrade()
            end
            if CursorHasItem() then return end
            if SlotLocked(bu.newBag, bu.newSlot) then return end
            PickupContainerItem(bu.newBag, bu.newSlot) -- new bag onto cursor
            -- Bag-slot equips need the dedicated PutItemInBag, not the
            -- generic PickupInventoryItem swap Blizzard uses for gear slots
            -- (PickupInventoryItem left the old bag stuck on the cursor
            -- instead of swapping it back — it isn't the right API for bag
            -- slots specifically, only for stock equipment slots).
            PutItemInBag(bu.targetInvSlot) -- equips it; old (now-empty) bag replaces cursor
            return

        elseif bu.phase == "park" then
            if not CursorHasItem() then
                StopBagUpgrade() -- nothing left on cursor: the old bag already auto-stacked/placed
                return
            end
            if SlotLocked(0, bu.parkSlot) or not SlotEmpty(0, bu.parkSlot) then
                return
            end
            PickupContainerItem(0, bu.parkSlot)
            StopBagUpgrade()
        end
    end

    buFrame:SetScript("OnEvent", StepBagUpgrade)

    -- Fallback watchdog: if nothing resolves within BU_TIMEOUT, the server
    -- rejected a move (e.g. bag went missing mid-sequence). Bail instead of
    -- hanging silently; whatever already moved stays where it landed.
    local buElapsed = 0
    local function BuWatchdog(_, elapsed)
        buElapsed = buElapsed + elapsed
        if buElapsed > BU_TIMEOUT then
            buElapsed = 0
            StopBagUpgrade("Refactor: bag upgrade timed out, aborting.")
        end
    end

    local function StartBagUpgrade(state)
        bu = state
        buElapsed = 0
        buFrame:RegisterEvent("BAG_UPDATE")
        buFrame:RegisterEvent("ITEM_LOCK_CHANGED")
        buFrame:SetScript("OnUpdate", BuWatchdog)
        StepBagUpgrade()
    end

    -- Called from a hooksecurefunc after the real UseContainerItem already
    -- ran (see below) — the boolean return is only used internally, for the
    -- early-return guards below to short-circuit each other.
    local function TryBagUpgrade(bag, slot)
        if not Qol("seamlessBagUpgrade") then return false end
        if bu then return false end -- a sequence is already running
        -- Smart equip (RefactorCompare) may be mid-swap on its own
        -- PickupContainerItem sequence; two concurrent shuffles desync
        -- the cursor. Each side checks the other before arming.
        local cs = RefactorCompareShared
        if cs and cs.SmartEquipActive and cs.SmartEquipActive() then
            return false
        end
        if InCombatLockdown() then return false end
        if BankFrame and BankFrame:IsShown() then return false end -- right-click there means bank deposit/equip
        if MerchantFrame and MerchantFrame:IsShown() then return false end -- right-click there means sell to vendor

        local link = GetContainerItemLink(bag, slot)
        if not link then return false end
        local _, _, _, _, _, itemType, _, _, equipLoc = GetItemInfo(link)
        if itemType ~= "Container" or equipLoc ~= "INVTYPE_BAG" then return false end

        -- Only step in when Blizzard's own equip would fail (no free bag slot).
        for bagID = 1, NUM_BAG_SLOTS do
            if GetContainerNumSlots(bagID) == 0 then return false end
        end

        local newItemID = tonumber(link:match("item:(%d+)"))
        for bagID = 1, NUM_BAG_SLOTS do
            local invSlot = ContainerIDToInventoryID(bagID)
            if GetInventoryItemID("player", invSlot) == newItemID then
                UIErrorsFrame:AddMessage("You already have that bag equipped.", 1, 0.1, 0.1)
                return true
            end
        end

        -- Equipped bag with the fewest slots is the one being replaced.
        local targetBag, targetSlots
        for bagID = 1, NUM_BAG_SLOTS do
            local n = GetContainerNumSlots(bagID)
            if not targetSlots or n < targetSlots then
                targetBag, targetSlots = bagID, n
            end
        end
        if not targetBag then return false end

        -- Plan moves for every item in targetBag, dry-run first so a
        -- shortfall aborts before anything actually moves.
        local freeSlots = {} -- {bag, slot, family} for every empty slot outside targetBag
        for bagID = 0, NUM_BAG_SLOTS do
            if bagID ~= targetBag then
                local bagFamily = 0
                if bagID > 0 then
                    bagFamily = ItemFamily(GetInventoryItemLink("player", ContainerIDToInventoryID(bagID)))
                end
                for s = 1, GetContainerNumSlots(bagID) do
                    if SlotEmpty(bagID, s) then
                        table.insert(freeSlots, { bag = bagID, slot = s, family = bagFamily })
                    end
                end
            end
        end

        -- A bag can only be unequipped once it is completely empty, so the
        -- new bag itself must be moved out too if it's sitting inside the
        -- one being replaced — track where it lands so the equip step below
        -- picks it up from its new home instead of its original slot.
        local newBag, newSlot = bag, slot
        local moves, usedFree = {}, {}
        local ok = true
        for s = 1, targetSlots do
            local itemLink = GetContainerItemLink(targetBag, s)
            if itemLink then
                local family = ItemFamily(itemLink)
                local dest
                for i, free in ipairs(freeSlots) do
                    if not usedFree[i] and FamilyFits(free.family, family) then
                        dest, usedFree[i] = free, true
                        break
                    end
                end
                if not dest then ok = false break end
                table.insert(moves, { fromBag = targetBag, fromSlot = s, toBag = dest.bag, toSlot = dest.slot })
                if targetBag == bag and s == slot then
                    newBag, newSlot = dest.bag, dest.slot
                end
            end
        end

        -- Reserve one more free slot to park the old bag once it's emptied.
        local parkSlot
        if ok then
            for i, free in ipairs(freeSlots) do
                if not usedFree[i] and free.bag == 0 then
                    parkSlot, usedFree[i] = free.slot, true
                    break
                end
            end
            if not parkSlot then ok = false end
        end

        if not ok then
            UIErrorsFrame:AddMessage("Not enough free bag space to swap in that bag.", 1, 0.1, 0.1)
            return true
        end

        StartBagUpgrade({
            phase = "moving",
            moves = moves,
            targetBag = targetBag,
            targetInvSlot = ContainerIDToInventoryID(targetBag),
            oldBagLink = GetInventoryItemLink("player", ContainerIDToInventoryID(targetBag)),
            newBag = newBag,
            newSlot = newSlot,
            parkSlot = parkSlot,
        })
        return true
    end

    -- Smart equip (RefactorCompare) checks this before arming its own
    -- item shuffle — see the matching guard in TryBagUpgrade above.
    RefactorQoL.BagShuffleActive = function() return bu ~= nil end

    -- Reacting via hooksecurefunc (not replacing the global) keeps every
    -- other UseContainerItem call — eating food, opening lockboxes, using
    -- trinkets from bags — untainted. Replacing the global directly used to
    -- put an addon-defined function in the call path for ALL of those too,
    -- and Blizzard flags that as taint even for calls TryBagUpgrade itself
    -- ignores. The tradeoff: when Blizzard's own equip attempt can't work
    -- (no free bag slot), its failure message shows for an instant before
    -- this hook's shuffle-and-retry takes over, instead of being preempted.
    hooksecurefunc("UseContainerItem", function(bag, slot)
        TryBagUpgrade(bag, slot)
    end)
end
