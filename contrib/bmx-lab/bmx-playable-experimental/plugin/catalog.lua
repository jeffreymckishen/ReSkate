-- Selection identity ported from Engine/Game/BMX/bmx_trick_catalog.h.
-- These are our named selection records, not extracted animation data.
-- Motion timings, release masks, animation and physical execution are not
-- implemented by this selection-only module.
local catalog = { none = 255 }

local names = {
    [0] = "Grand Slam Left", [1] = "Twix Right", [2] = "Helicopter Right",
    [3] = "Bri Flip Left", [4] = "Willy Flip", [5] = "Mc Griddle Left",
    [6] = "Kick Whip Left", [7] = "Superman",
    [10] = "Grand Slam Right", [11] = "Christ Air", [12] = "Kick Whip Right",
    [13] = "Mc Griddle Right", [14] = "Bar Hug", [15] = "Bri Flip Right",
    [16] = "Helicopter Left", [17] = "Nothing",
    [20] = "Tuck No", [21] = "Table", [22] = "Invert", [23] = "Turndown",
    [24] = "Suicide", [25] = "Euro", [26] = "Lookback", [27] = "Cannon Ball",
    [31] = "Tire Grab Left", [32] = "Seat Grab Left", [33] = "Bus Driver Left",
    [34] = "Barspin Left", [35] = "Toboggan Left", [36] = "One Hander Left",
    [37] = "Xup Left",
    [41] = "Xup Right", [42] = "One Hander Right", [43] = "Toboggan Right",
    [44] = "Barspin Right", [45] = "Bus Driver Right", [46] = "Seat Grab Right",
    [47] = "Tire Grab Right",
    [50] = "Tuck Up", [51] = "No Foot Can Right", [52] = "Whip Right",
    [53] = "Whopper Right", [54] = "Crankflip", [55] = "Whopper Left",
    [56] = "Whip Left", [57] = "No Foot Can Left",
    [61] = "Can Left", [62] = "Moto Left", [63] = "Nac Left",
    [65] = "Griz Air Left", [66] = "One Footer Left", [67] = "Candy Bar Left",
    [71] = "Candy Bar Right", [72] = "One Footer Right", [73] = "Griz Air Right",
    [75] = "Nac Right", [76] = "Moto Right", [77] = "Can Right",
}

function catalog.name(id)
    return names[id]
end

function catalog.valid(id)
    return id == catalog.none or names[id] ~= nil
end

function catalog.select(set, slot)
    if type(set) ~= "number" or type(slot) ~= "number"
        or set % 1 ~= 0 or slot % 1 ~= 0 or set < 0 or set >= 8 or slot < 0 or slot >= 8 then
        return catalog.none
    end
    local id = set * 10 + slot
    return names[id] ~= nil and id or catalog.none
end

function catalog.legacy_rotation(id)
    return id == 34 or id == 44 or id == 52 or id == 56
end

return catalog
