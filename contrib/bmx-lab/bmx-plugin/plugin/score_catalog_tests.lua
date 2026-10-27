-- Pure catalog contracts; these assert authored metadata, not game likeness.
local Catalog = require("./score_catalog")
local Selections = require("./catalog")
local Motions = require("./motions")
local Tests = {}
function Tests.run()
    local cases, assertions = 0, 0
    local function check(ok, message) assertions += 1; assert(ok, message) end
    local function case(body) cases += 1; body() end
    case(function()
        local total, families = 0, {}
        for id = 0, 77 do
            local selected, row = Selections.name(id), Catalog.get(id)
            check((selected ~= nil) == (row ~= nil), "scoring preserves selection identity " .. id)
            if row then
                total += 1
                local motion = Motions.find(id)
                check(row.key == motion.family and row.pose == (motion.motion == "pose"),
                    "metadata retains motion family and pose meaning " .. id)
                check(Catalog.categories[row.category] == true and row.difficulty >= 1
                    and row.difficulty <= 5 and row.difficulty % 1 == 0, "closed authored metadata " .. id)
                check(not string.find(row.display, " Left$") and not string.find(row.display, " Right$"),
                    "display is direction neutral " .. id)
                local earlier = families[row.key]
                if earlier then
                    check(earlier.display == row.display and earlier.category == row.category
                        and earlier.difficulty == row.difficulty and earlier.pose == row.pose,
                        "directions share all scoring metadata " .. id)
                end
                families[row.key] = row
            end
        end
        check(total == 58, "all 58 populated selections are scored")
    end)
    case(function()
        for _, id in ipairs({30,40,60,64,70,74,255,-1,78,1.5,math.huge,-math.huge}) do
            check(Catalog.get(id) == nil, "holes, sentinel and invalid numbers stay unavailable")
        end
        check(Catalog.get(0/0) == nil and Catalog.get(nil) == nil and Catalog.get("34") == nil
            and Catalog.get(false) == nil and Catalog.get({}) == nil, "invalid ID types do not index the catalog")
        check(Selections.valid(255) and Catalog.get(255) == nil, "none remains a selection sentinel, never a score part")
    end)
    case(function()
        local expected = { [34]={"barspin","Barspin","bar",2,false},
            [52]={"tailwhip","Tailwhip","frame",3,false}, [37]={"xup","X-Up","variation",1,true},
            [54]={"crankflip","Crankflip","variation",2,false}, [33]={"bus_driver","Bus Driver","bar",3,false},
            [1]={"twix","Twix","frame",5,false}, [0]={"grand_slam","Grand Slam","frame",5,false},
            [21]={"table","Table","variation",1,true} }
        for id, values in pairs(expected) do
            local row = Catalog.get(id)
            check(row.key == values[1] and row.display == values[2] and row.category == values[3]
                and row.difficulty == values[4] and row.pose == values[5], "explicit family policy " .. id)
        end
        check(Selections.name(52) == "Whip Right" and Selections.name(37) == "Xup Left",
            "display aliases never rewrite selection names")
        check(Motions.find(21).bike_roll ~= 0 and Catalog.get(21).category == "variation",
            "pose presentation rotation is not a frame catch")
    end)
    case(function()
        local expected = {air=true,variation=true,bar=true,frame=true,rotation=true,flip=true,
            manual=true,grind=true,stall=true}
        local total = 0
        for category, enabled in pairs(Catalog.categories) do
            total += 1
            check(expected[category] == true and enabled == true, "category lookup is closed")
        end
        check(total == 9, "all nine categories are available")
        local row = Catalog.get(34)
        check(table.isfrozen(Catalog) and table.isfrozen(Catalog.categories) and table.isfrozen(row),
            "metadata and public lookup are immutable")
        check(not pcall(function() row.difficulty = 5 end), "callers cannot corrupt shared difficulty")
        check(not pcall(function() Catalog.categories.unknown = true end), "callers cannot extend categories")
        check(Catalog.get(34).difficulty == 2, "refused mutation preserves later reads")
    end)
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)
