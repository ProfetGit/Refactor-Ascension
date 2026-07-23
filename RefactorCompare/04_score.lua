local C = RefactorCompareInternal
local Print = C.Print
local ActiveProfile = C.ActiveProfile
local SecondaryProfile = C.SecondaryProfile
local ScanItem = C.ScanItem
local SLOTS_FOR_INVTYPE = C.SLOTS_FOR_INVTYPE
local WEAPON_INVTYPES = C.WEAPON_INVTYPES
local OFFHAND_DPS_FACTOR = C.OFFHAND_DPS_FACTOR
local ARMOR_FILTERED_INVTYPES = C.ARMOR_FILTERED_INVTYPES
local ArmorTypes = C.ArmorTypes
local STAT_NAME_KEYS = C.STAT_NAME_KEYS
local equippedCache = C.equippedCache
local verdictCache = C.verdictCache

--------------------------------------------------------------------------
-- Scoring
--------------------------------------------------------------------------

-- Links already known not to be equippable gear. Unlike a verdict, this
-- answer can never change: it comes from GetItemInfo's equipLoc, a property
-- of the BASE item, so it is independent of weights, profiles, level and
-- Ascension's instance scaling. Bags are mostly reagents, consumables and
-- quest items, and without this every ContainerFrame_Update paid a cache-key
-- concatenation plus a GetItemInfo call for each of them — on a 100+ slot
-- Bagnon wall, on every BAG_UPDATE burst.
--
-- Declared here, above its first use: a `local` declared further down the
-- file would leave these reads resolving to a nil global instead.
--
-- Deliberately NOT a substitute for the nil-result rule in CompareItem: nil
-- there still means "no verdict yet, keep retrying". This records only the
-- permanent "not gear at all" answer, and never the "not cached yet" one.
-- Capped like the "h:" scan cache: a long session vendoring and looting can
-- meet a lot of distinct junk links, and this table would otherwise only
-- ever grow. Past the cap it is dropped wholesale and refills on demand —
-- the entries are pure derived data, so losing them costs one GetItemInfo.
local notGear = {}
local notGearCount, NOT_GEAR_CAP = 0, 1000
C.notGear = notGear

local function MarkNotGear(link)
    if notGear[link] then return end
    notGearCount = notGearCount + 1
    if notGearCount > NOT_GEAR_CAP then
        for k in pairs(notGear) do notGear[k] = nil end
        notGearCount = 1
    end
    notGear[link] = true
end
C.MarkNotGear = MarkNotGear

-- Returns score plus the info needed to compare, or nil if the item isn't
-- in the client cache yet / isn't equippable gear. bag+slot or invSlot
-- select the real item instance (see ScanItem).
-- profile defaults to the active profile; the secondary-verdict path passes
-- its own so one tooltip scan feeds both weighted sums.
local function ScoreItem(link, bag, slot, invSlot, src, profile)
    local name, _, quality, _, reqLevel, itemType, itemSubType, _, equipLoc =
        GetItemInfo(link)
    -- No name = the client hasn't cached this item yet. That is a RETRY, not
    -- a verdict, and must never be recorded as non-gear.
    if not name then return nil end
    if not equipLoc or not SLOTS_FOR_INVTYPE[equipLoc] then
        MarkNotGear(link)
        return nil
    end

    profile = profile or ActiveProfile()
    local weights = profile.weights
    local customWeights = profile.customWeights
    local score = 0

    local scan = ScanItem(link, bag, slot, invSlot, src)
    if scan.failed then return nil end -- no data: no verdict, never a guess
    local hitAmount = 0 -- raw hit rating on the item, for the hit-cap correction
    for statName, amount in pairs(scan.stats) do
        local key = STAT_NAME_KEYS[statName]
        local w
        if key then
            w = weights[key] or 0
            if key == "HIT" then hitAmount = hitAmount + amount end
        else
            w = customWeights[statName]
            if w == nil then w = weights.UNKNOWN or 0 end
        end
        score = score + amount * w
    end

    -- Empty sockets score at the SOCKET weight (0 by default): Pawn-style
    -- credit for the gem you could put there, opt-in because the green
    -- arrow promises actual stats, not potential ones.
    if scan.emptySockets then
        score = score + scan.emptySockets * (weights.SOCKET or 0)
    end

    -- Weapons: DPS is the dominant term, weighted separately from stats.
    -- Kept as its own component too, so the 2H-vs-dual-wield comparison
    -- can discount the offhand's share (see OFFHAND_DPS_FACTOR).
    local dpsScore
    if WEAPON_INVTYPES[equipLoc] and scan.dps then
        dpsScore = scan.dps * (weights.DPS or 0)
        score = score + dpsScore
    end

    if RefactorCompareDB and RefactorCompareDB.debug then
        Print("score [" .. (name or link) .. "] = " .. string.format("%.2f", score))
    end

    return {
        score = score,
        dpsScore = dpsScore, -- weapon-DPS share of score (nil for non-weapons)
        hit = hitAmount, -- raw hit rating on the item (hit-cap correction)
        quality = quality,
        reqLevel = reqLevel,
        itemType = itemType,
        itemSubType = itemSubType,
        equipLoc = equipLoc,
        unusable = scan.unusable,
        unusableReason = scan.unusableReason,
        levelLocked = scan.levelLocked,
        -- Scored from a bare link = base item, not the scaled copy in
        -- hand. Ascension scaling makes that an estimate at best.
        approx = not scan.instance,
    }
end

-- Score of what's equipped in a slot: a number, nil when the slot is
-- truly empty, or false when there IS an item but it can't be read
-- (tooltip scan failed). Callers must treat false as "unknown" and stay
-- silent — never as an empty slot begging to be filled. Second return is
-- the weapon-DPS share of the score (nil unless the slot holds a weapon),
-- for the offhand discount in the 2H comparison. Third return is the item's
-- raw hit rating (for the hit-cap correction in VerdictForProfile). profile
-- defaults to the active profile; the secondary verdict passes its own and
-- gets its own memo fields (score2/dpsScore2/hit2) so the two never poison
-- each other.
local function ScoreEquipped(slot, profile)
    local link = GetInventoryItemLink("player", slot)
    if not link then return nil end
    local secondary = profile ~= nil
    profile = profile or ActiveProfile()
    -- Memoized per generation: equipped gear only changes on events that
    -- bump the generation (equip, level, weight/profile edits), so one
    -- score serves every bag slot of a whole redraw — and every hover in
    -- between — instead of re-rendering the worn item's tooltip each time.
    local c = equippedCache[slot]
    local memoHit = c and c.gen == C.generation and c.link == link
    if memoHit then
        if not secondary and c.score then
            return c.score, c.dpsScore, c.hitAmt
        elseif secondary and c.score2 then
            return c.score2, c.dpsScore2, c.hitAmt2
        end
        -- This profile's half isn't memoized yet: fall through and score it.
    end
    local info = ScoreItem(link, nil, nil, slot, nil, profile)
    if not info then return false end -- unreadable: retry next call, never memoized
    if memoHit then
        if secondary then
            c.score2, c.dpsScore2, c.hitAmt2 = info.score, info.dpsScore, info.hit
        else
            c.score, c.dpsScore, c.hitAmt = info.score, info.dpsScore, info.hit
        end
    elseif secondary then
        equippedCache[slot] = { gen = C.generation, link = link,
            score2 = info.score, dpsScore2 = info.dpsScore, hitAmt2 = info.hit }
    else
        equippedCache[slot] = { gen = C.generation, link = link,
            score = info.score, dpsScore = info.dpsScore, hitAmt = info.hit }
    end
    return info.score, info.dpsScore, info.hit
end

local function MainHandIs2H()
    local link = GetInventoryItemLink("player", 16)
    if not link then return false end
    local equipLoc = select(9, GetItemInfo(link))
    return equipLoc == "INVTYPE_2HWEAPON"
end

-- Dual Wield is a learnable ability on Ascension; if the character
-- doesn't know it, a one-hander only competes for the main hand.
local function CanDualWield()
    return IsSpellKnown and IsSpellKnown(674) or false
end

-- A shield (or held-in-off-hand frill) is a deliberate role choice, not a
-- weapon competing for its slot: a one-hander scored against it nearly
-- always "wins" under weapon weights, painting a misleading upgrade arrow
-- on every 1H in the bag. While one is equipped, 1H weapons only compete
-- for the main hand.
local function OffhandIsShield()
    local link = GetInventoryItemLink("player", 17)
    if not link then return false end
    local equipLoc = select(9, GetItemInfo(link))
    return equipLoc == "INVTYPE_SHIELD" or equipLoc == "INVTYPE_HOLDABLE"
end

--------------------------------------------------------------------------
-- Hit cap
--------------------------------------------------------------------------
-- Hit rating past the cap is worthless; below it, valuable. The linear
-- score can't express that, so an opt-in per-profile "hit cap" mode re-scores
-- the HIT term as a marginal value: full weight up to the cap given the hit
-- you ALREADY wear, ~zero past it. Everything works in rating-space, matching
-- the game's own "7/22" (current rating / rating-for-cap) sheet display —
-- talent/racial flat-% hit is deliberately out of scope (v1 limitation).
local HITCAP_INDEX    = { melee = 6, ranged = 7, spell = 8 } -- CR_HIT_MELEE/RANGED/SPELL
local HITCAP_PCT       = { melee = 8, ranged = 8, spell = 17 } -- % vs a raid boss (PvE)
local HITCAP_PCT_PVP   = { melee = 5, ranged = 5, spell = 4 }  -- % vs a player (PvP)

local function HitCapMode(profile)
    local hc = profile and profile.hitCap
    local mode = hc and hc.mode
    if mode == "melee" or mode == "ranged" or mode == "spell" or mode == "custom" then return mode end
    return "off"
end

local function HitCapPvP(profile)
    local hc = profile and profile.hitCap
    return hc and hc.pvp or false
end

-- Combat-rating type (melee/ranged/spell) used to index HITCAP_INDEX/
-- HITCAP_PCT and to read the player's current rating. For "custom" mode
-- this is a separate per-profile choice (the player still needs to say
-- which combat table their typed rating targets); every other mode IS its
-- own type already.
local function HitCapType(profile)
    local mode = HitCapMode(profile)
    if mode == "custom" then
        local hc = profile and profile.hitCap
        local t = hc and hc.customType
        if t == "melee" or t == "ranged" or t == "spell" then return t end
        return "melee"
    end
    return mode
end

-- Rating needed for 1% hit of this type, read LIVE from the game so it tracks
-- Ascension's own scaling and the player's level (same source as the "7/22"
-- display). GetCombatRatingBonus is 0 when current rating is 0, so the ratio
-- is only derivable with some hit on; cache the last-good value per type and
-- fall back to it. Returns nil when never seen — caller then treats the item
-- as fully under-cap (a player with no hit is far under any cap anyway).
local function HitRatingPerPct(mode)
    local idx = HITCAP_INDEX[mode]
    if not idx or not GetCombatRating or not GetCombatRatingBonus then return nil end
    local rating = GetCombatRating(idx)
    local pct = GetCombatRatingBonus(idx)
    if rating and pct and pct > 0 then
        local ratio = rating / pct
        RefactorCompareDB.hitCapRatio = RefactorCompareDB.hitCapRatio or {}
        RefactorCompareDB.hitCapRatio[mode] = ratio
        return ratio
    end
    return RefactorCompareDB.hitCapRatio and RefactorCompareDB.hitCapRatio[mode] or nil
end

-- Cap rating for this profile's hit mode, or nil (mode off / ratio unknown).
-- Targets the PvE cap by default; with hitCap.pvp = true, targets the lower
-- PvP cap instead (the other cap is shown in the readout for reference).
local function HitCapRating(profile)
    local mode = HitCapMode(profile)
    if mode == "off" then return nil end
    if mode == "custom" then
        local hc = profile.hitCap
        local rating = hc and hc.customRating
        if not rating or rating <= 0 then return nil end
        return rating, HitCapType(profile)
    end
    local ratio = HitRatingPerPct(mode)
    if not ratio then return nil end
    local pctTable = HitCapPvP(profile) and HITCAP_PCT_PVP or HITCAP_PCT
    return pctTable[mode] * ratio, mode
end

-- Current total hit rating of the profile's mode (from all worn gear).
local function CurrentHitRating(mode)
    local idx = HITCAP_INDEX[mode]
    if not idx or not GetCombatRating then return 0 end
    return GetCombatRating(idx) or 0
end

-- Cap-corrects a (new item, equipped item) score pair for one slot. Replaces
-- the flat linear hit term (wUnder * hit, already baked into both scores) with
-- the item's MARGINAL cap value given the hit worn on OTHER slots. wOver = 0:
-- hit past the cap is worth nothing. Returns the two corrected scores.
local function ApplyHitCap(profile, newScore, newHit, equippedScore, equippedHit)
    local cap, mode = HitCapRating(profile)
    if not cap then return newScore, equippedScore end
    local wUnder = (profile.weights and profile.weights.HIT) or 0
    if wUnder == 0 then return newScore, equippedScore end
    newHit = newHit or 0
    equippedHit = equippedHit or 0
    local hitOther = CurrentHitRating(mode) - equippedHit
    if hitOther < 0 then hitOther = 0 end
    local function capVal(h)
        if h <= cap then return wUnder * h end
        return wUnder * cap -- wOver = 0: nothing past the cap
    end
    local base = capVal(hitOther)
    newScore = newScore - wUnder * newHit + (capVal(hitOther + newHit) - base)
    equippedScore = equippedScore - wUnder * equippedHit + (capVal(hitOther + equippedHit) - base)
    return newScore, equippedScore
end

-- One profile's verdict for an already-scored item. Returns nil (nothing to
-- show — including any side we couldn't actually read) or a result table:
--   status  = "upgrade" | "downgrade" | "even" | "empty"
--   pct     = signed % difference (for upgrade/downgrade/even)
--   gain    = absolute score difference (new - equipped; the new item's own
--             score when the slot is empty or scores zero). Percentages are
--             not comparable across slots — a +50% ring can be worth less
--             than a +10% two-hander — so anything ranking DIFFERENT items
--             against each other (quest reward auto-pick) must use this.
--   context = optional extra text, e.g. "vs main + off hand"
-- profile nil = the active profile (ScoreEquipped's primary memo fields);
-- the secondary verdict passes its own profile. The slot logic below is
-- weight-independent — only the scores differ between profiles.
local function VerdictForProfile(info, profile)
    -- `_` is declared here on purpose: the 2H branch below discards
    -- ScoreEquipped's middle return into it, and without a local of that name
    -- in scope that assignment wrote to the GLOBAL _ on every comparison.
    local equippedScore, equippedHit, context, _
    -- profile may be nil (primary verdict = active profile); resolve it for
    -- the hit-cap correction, which needs the real weights/hitCap table.
    local capProfile = profile or ActiveProfile()
    -- New item's own cap-corrected score, for the empty/zero-baseline gains
    -- (quest auto-pick ranks by gain, so hit over cap must not inflate it).
    local function emptyNewScore()
        local ns = ApplyHitCap(capProfile, info.score, info.hit, 0, 0)
        return ns
    end

    if info.equipLoc == "INVTYPE_2HWEAPON" then
        -- A two-hander replaces everything you're holding: compare against
        -- main hand + off hand combined, the offhand's weapon DPS at the
        -- dual-wield penalty factor (shields/holdables have no DPS share
        -- and keep full value).
        local mh, _, mhHit = ScoreEquipped(16, profile)
        local oh, ohDps, ohHit = ScoreEquipped(17, profile)
        if mh == false or oh == false then return nil end
        if not mh and not oh then
            return { status = "empty", gain = emptyNewScore(),
                levelLocked = info.levelLocked, approx = info.approx }
        end
        equippedScore = (mh or 0) + (oh or 0)
        equippedHit = (mhHit or 0) + (ohHit or 0)
        if oh and ohDps then
            equippedScore = equippedScore - ohDps * (1 - OFFHAND_DPS_FACTOR)
        end
        if oh then context = "vs main + off hand" end
    elseif MainHandIs2H()
        and (info.equipLoc == "INVTYPE_WEAPON"
            or info.equipLoc == "INVTYPE_WEAPONMAINHAND"
            or info.equipLoc == "INVTYPE_WEAPONOFFHAND"
            or info.equipLoc == "INVTYPE_HOLDABLE"
            or info.equipLoc == "INVTYPE_SHIELD") then
        -- Anything held while a 2H is equipped means giving up the 2H, so
        -- that's what it has to beat.
        equippedScore, _, equippedHit = ScoreEquipped(16, profile)
        if equippedScore == false then return nil end
        context = "vs equipped 2H"
    else
        local slots = SLOTS_FOR_INVTYPE[info.equipLoc]
        if info.equipLoc == "INVTYPE_WEAPON"
            and (not CanDualWield() or OffhandIsShield()) then
            slots = { 16 }
        end
        -- Multi-slot gear (rings, trinkets, 1H weapons): compare against
        -- the weaker of the equipped items, since that's what you'd replace.
        local weakerSlot
        for _, slot in ipairs(slots) do
            local s, _, sHit = ScoreEquipped(slot, profile)
            if s == false then return nil end
            if not s then
                return { status = "empty", gain = emptyNewScore(),
                    levelLocked = info.levelLocked, approx = info.approx }
            end
            if not equippedScore or s < equippedScore then
                equippedScore, equippedHit, weakerSlot = s, sHit, slot
            end
        end
        -- When two slots competed, name the loser so the verdict says
        -- what it's actually beating (and what smart equip will replace).
        if weakerSlot and #slots > 1 then
            local elink = GetInventoryItemLink("player", weakerSlot)
            local name = elink and elink:match("%[(.-)%]")
            if name then context = "vs " .. name end
        end
    end

    if not equippedScore then
        return { status = "empty", gain = emptyNewScore(),
            levelLocked = info.levelLocked, approx = info.approx }
    end

    -- Both sides readable: re-score the HIT term against the cap before
    -- comparing (no-op when the profile's hit-cap mode is off). newScore is
    -- info.score with the cap correction; the linear info.score is untouched.
    local newScore
    newScore, equippedScore = ApplyHitCap(capProfile, info.score, info.hit,
        equippedScore, equippedHit)

    if equippedScore <= 0 then
        -- Equipped item scores zero or negative under these weights; a
        -- percentage against that is meaningless, treat as free upgrade
        -- if the new item scores anything at all. zeroBaseline marks this
        -- so renderers don't claim the slot is EMPTY (the "empty" status
        -- only earns the upgrade arrow here — the slot is occupied): sparse
        -- profiles (e.g. a healer secondary profile looking at a Strength
        -- belt) score worn gear at 0 all the time.
        if newScore > 0 then
            return { status = "empty", zeroBaseline = true, context = context,
                gain = newScore,
                levelLocked = info.levelLocked, approx = info.approx }
        end
        -- BOTH sides score nothing: not parity — this profile simply has no
        -- weights for anything on either item. zeroAll marks it so renderers
        -- say "No value" instead of a misleading "0%".
        return { status = "even", pct = 0, zeroAll = true, context = context,
            gain = 0,
            levelLocked = info.levelLocked, approx = info.approx }
    end

    local pct = (newScore - equippedScore) / equippedScore * 100
    -- Clamp absurd percentages (tiny denominators) so the display stays sane.
    if pct > 999 then pct = 999 elseif pct < -999 then pct = -999 end

    local status
    if pct > 0.5 then status = "upgrade"
    elseif pct < -0.5 then status = "downgrade"
    else status = "even" end

    return { status = status, pct = pct, context = context,
        gain = newScore - equippedScore,
        levelLocked = info.levelLocked, approx = info.approx }
end

-- Core comparison. Returns nil (nothing to show — including any side we
-- couldn't actually read) or the active profile's result table:
--   status  = "upgrade" | "downgrade" | "even" | "empty" | "unusable" | "wrongarmor"
--   pct     = signed % difference (for upgrade/downgrade/even)
--   context = optional extra text, e.g. "vs main + off hand"
--   approx  = true when scored from a bare link (base item, not the
--             scaled instance): display as estimate, never as bag arrow
--   secondary = the secondary profile's verdict table (same shape), when a
--             secondary profile is configured. Never attached for the
--             profile-independent statuses (unusable/wrongarmor); a side
--             that can't be read kills only the secondary verdict, never
--             the primary one.
-- (Wrapped by CompareItem below, which memoizes bag-slot results.)
local function CompareItemUncached(link, bag, slot, invSlot, src)
    local info = ScoreItem(link, bag, slot, invSlot, src)
    if not info then return nil end
    if info.quality < (RefactorCompareDB.minQuality or 0) then return nil end

    -- Level requirement is deliberately NOT checked via GetItemInfo():
    -- Ascension scales items, and GetItemInfo() reports the base item's
    -- required level, not the scaled one on your actual copy. The tooltip
    -- scan handles it instead — the client renders any requirement you
    -- don't meet (level, proficiency, class) in red.
    if info.unusable then
        return { status = "unusable", context = info.unusableReason }
    end

    if ARMOR_FILTERED_INVTYPES[info.equipLoc]
        and info.itemType == "Armor"
        and ArmorTypes()[info.itemSubType] == false then
        return { status = "wrongarmor", context = info.itemSubType }
    end

    local result = VerdictForProfile(info)
    if not result then return nil end

    -- Secondary (blue) verdict: same tooltip scan, second weighted sum —
    -- ScanItem is weight-independent and cached, so this costs one
    -- re-scoring, not one re-scan.
    local secondary = SecondaryProfile()
    if secondary then
        local info2 = ScoreItem(link, bag, slot, invSlot, src, secondary)
        if info2 then
            result.secondary = VerdictForProfile(info2, secondary)
        end
    end

    return result
end

-- Bag-slot lookups are the hot path: every open bag re-evaluates every
-- slot on each redraw (ContainerFrame_Update / Bagnon hooks), so those
-- results are memoized per location+link until the generation moves.
-- Other sources (equipped invSlot, quest/roll/loot src) stay live — they
-- carry their own retry semantics. nil results are never cached: nil can
-- mean "scan not ready yet" and must keep retrying until it resolves.
local function CompareItem(link, bag, slot, invSlot, src)
    -- Checked before the cache key is built: for a non-gear link this turns
    -- the whole call into one table lookup and no allocation.
    if notGear[link] then return nil end
    if bag ~= nil and slot ~= nil and invSlot == nil and src == nil then
        local key = bag .. ":" .. slot .. ":" .. link
        local hit = verdictCache[key]
        if hit and hit.gen == C.generation then return hit.result end
        local result = CompareItemUncached(link, bag, slot)
        -- Only cache fully-resolved results: with a secondary profile set,
        -- a missing .secondary half means its equipped side wasn't readable
        -- yet — caching that would pin the verdict half-drawn until the
        -- next generation bump instead of retrying like a nil result does.
        if result and (result.secondary or not SecondaryProfile()) then
            verdictCache[key] = { gen = C.generation, result = result }
        end
        return result
    end
    return CompareItemUncached(link, bag, slot, invSlot, src)
end

--------------------------------------------------------------------------
-- Smart equip
--
-- Right-clicking a ring/trinket/1H weapon into a full pair should replace
-- the WEAKER of the two equipped items under current weights, not the
-- engine's fixed pick (always the first slot). The click can't be
-- preempted: replacing the UseContainerItem global puts addon code in the
-- path of every bag click and Blizzard flags that as taint (see the
-- bag-upgrade hook in Refactor.lua for the war story), so this reacts
-- after the engine's own equip instead. The engine swaps the displaced
-- item into the clicked bag slot; once it lands there unlocked, it gets
-- equipped over the weaker slot — both better items stay equipped, the
-- weaker one ends up in the bag. Scores are snapshotted at click time
-- (both items still equipped — the swap is a server round trip) under the
-- usual trust rules: either side unreadable means hands off, and a failed
-- or blocked equip (level requirement, rings in combat) never settles, so
-- the watchdog just times the fix-up out.
--------------------------------------------------------------------------

local SMART_EQUIP_SLOTS = {
    INVTYPE_FINGER = { 11, 12 },
    INVTYPE_TRINKET = { 13, 14 },
    INVTYPE_WEAPON = { 16, 17 },
}

-- Exported via RefactorCompareShared: Refactor.lua's seamless bag upgrade
-- checks it before starting its own item shuffle (and vice versa, via
-- RefactorQoL.BagShuffleActive) — two concurrent PickupContainerItem
-- sequences desync the cursor.
local SmartEquipActive

do
    local seFrame = CreateFrame("Frame")
    local se -- pending fix-up, nil when idle
    local seElapsed = 0

    SmartEquipActive = function() return se ~= nil end

    local function StopSmartEquip()
        se = nil
        seFrame:UnregisterAllEvents()
        seFrame:SetScript("OnUpdate", nil)
    end

    seFrame:SetScript("OnEvent", function()
        if not se then return end
        -- Which slot did the engine put the new item in?
        local landed
        for i = 1, 2 do
            if GetInventoryItemLink("player", se.slots[i]) ~= se.links[i] then
                landed = i
                break
            end
        end
        if not landed then return end -- swap not visible yet
        if se.slots[landed] == se.weakerSlot then
            StopSmartEquip() -- engine already replaced the weaker one
            return
        end
        -- The displaced (stronger) item should be sitting in the clicked
        -- bag slot; wait until it's there and unlocked.
        if GetContainerItemLink(se.bag, se.slot) ~= se.links[landed] then return end
        local _, _, locked = GetContainerItemInfo(se.bag, se.slot)
        if locked then return end
        if CursorHasItem() then
            StopSmartEquip()
            return
        end
        local bag, slot, target = se.bag, se.slot, se.weakerSlot
        StopSmartEquip()
        PickupContainerItem(bag, slot)
        EquipCursorItem(target)
    end)

    local function SeWatchdog(_, elapsed)
        seElapsed = seElapsed + elapsed
        if seElapsed > 2 then StopSmartEquip() end
    end

    hooksecurefunc("UseContainerItem", function(bag, slot)
        if not RefactorCompareDB or not RefactorCompareDB.enabled or RefactorCompareDB.smartEquip == false then return end
        if se then return end -- a fix-up is already in flight
        -- Seamless bag upgrade (Refactor.lua) mid-shuffle: its queue is
        -- moving items through the same events; hands off until it's done.
        if RefactorQoL and RefactorQoL.BagShuffleActive
            and RefactorQoL.BagShuffleActive() then
            return
        end
        -- Right-click means sell/deposit/attach/trade while these are open.
        if (MerchantFrame and MerchantFrame:IsShown())
            or (BankFrame and BankFrame:IsShown())
            or (MailFrame and MailFrame:IsShown())
            or (TradeFrame and TradeFrame:IsShown())
            or (AuctionFrame and AuctionFrame:IsShown())
            or (GuildBankFrame and GuildBankFrame:IsShown()) then
            return
        end
        if CursorHasItem() then return end
        local link = GetContainerItemLink(bag, slot)
        if not link then return end
        local equipLoc = select(9, GetItemInfo(link))
        local slots = SMART_EQUIP_SLOTS[equipLoc]
        if not slots then return end
        if equipLoc == "INVTYPE_WEAPON"
            and (not CanDualWield() or MainHandIs2H() or OffhandIsShield()) then
            return -- only one candidate slot; the engine default is right
        end
        local linkA = GetInventoryItemLink("player", slots[1])
        local linkB = GetInventoryItemLink("player", slots[2])
        if not linkA or not linkB then return end -- empty slot: engine fills it
        local sa = ScoreEquipped(slots[1])
        local sb = ScoreEquipped(slots[2])
        if type(sa) ~= "number" or type(sb) ~= "number" then return end
        if sa == sb then return end -- either is fine, leave the engine to it
        se = {
            bag = bag, slot = slot, slots = slots,
            links = { linkA, linkB },
            weakerSlot = sa < sb and slots[1] or slots[2],
        }
        seElapsed = 0
        seFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
        seFrame:RegisterEvent("ITEM_LOCK_CHANGED")
        seFrame:RegisterEvent("BAG_UPDATE")
        seFrame:SetScript("OnUpdate", SeWatchdog)
    end)
end

C.HITCAP_PCT = HITCAP_PCT
C.HITCAP_PCT_PVP = HITCAP_PCT_PVP
C.HitCapMode = HitCapMode
C.HitCapPvP = HitCapPvP
C.HitCapType = HitCapType
C.HitRatingPerPct = HitRatingPerPct
C.HitCapRating = HitCapRating
C.CurrentHitRating = CurrentHitRating
C.CompareItem = CompareItem
C.SmartEquipActive = SmartEquipActive
