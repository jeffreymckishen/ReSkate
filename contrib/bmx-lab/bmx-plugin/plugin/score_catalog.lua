-- Authored scoring metadata over the existing selection and motion records.
-- Difficulties are local defaults, not measured Skate or BMX Streets values.
local selections = require("./catalog")
local motions = require("./motions")
local Catalog = {}
Catalog.categories = table.freeze({ air=true, variation=true, bar=true, frame=true,
    rotation=true, flip=true, manual=true, grind=true, stall=true })
local difficulties = {
    grand_slam=5, twix=5, helicopter=5, bri_flip=5, willy_flip=5,
    mc_griddle=4, kick_whip=4, superman=3, christ_air=4, bar_hug=2, nothing=4,
    tuck_no=2, table=1, invert=2, turndown=2, suicide=3, euro=2, lookback=2,
    cannon_ball=4, tire_grab=2, seat_grab=1, bus_driver=3, barspin=2,
    toboggan=2, one_hander=1, xup=1, tuck_up=1, no_foot_can=3, tailwhip=3,
    whopper=4, crankflip=2, can=2, moto=1, nac=2, griz_air=3, one_footer=1, candy_bar=3,
}
local entries = {}
for id = 0, 77 do
    local display = selections.name(id)
    if display then
        local motion = motions.find(id)
        assert(motion and difficulties[motion.family], "score catalog needs authored metadata")
        local pose = motion.motion == "pose"
        local category
        if pose or motion.family == "crankflip" then
            category = "variation"
        elseif motion.tail_turns ~= 0 or motion.bike_pitch ~= 0 or motion.bike_roll ~= 0 then
            category = "frame"
        elseif motion.bar_turns ~= 0 then
            category = "bar"
        else
            error("score catalog needs an explicit motion category")
        end
        display = string.gsub(string.gsub(display, " Left$", ""), " Right$", "")
        if display == "Whip" then display = "Tailwhip" end
        if display == "Xup" then display = "X-Up" end
        entries[id] = table.freeze({ key=motion.family, display=display, category=category,
            difficulty=difficulties[motion.family], pose=pose })
    end
end
table.freeze(entries)
function Catalog.get(id)
    if type(id) ~= "number" or id ~= id or id < 0 or id > 77 or id % 1 ~= 0 then return nil end
    return entries[id]
end
return table.freeze(Catalog)
