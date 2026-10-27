-- board_drop.lua against constructed fakes of reskate.board that hold to the rules of the SDK at 025470f5:
-- plugin_api_world.cpp board_bones, board_toss and board_clear (the permission, the argument checks and
-- their messages, the 4 a second rate toss shares, result()'s true or false and why) and
-- board_pose.cpp toss and clear (bones 2 to 15, 50 m/s and 50 rad/s, one owner at a time). Pure: no
-- reskate API, no game; a pass is no evidence of where the game draws the board.
local BD = require("./board_drop")

local cases, assertions = 0, 0
local function check(ok, message)
    assertions += 1
    if not ok then error(message or "check failed", 2) end
end
local function test(name, fn)
    cases += 1
    local ok, issue = pcall(fn)
    if not ok then error(name .. ": " .. tostring(issue), 0) end
end

local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function raise(text) error(text, 0) end
local function near(a, b, e) return finite(a) and finite(b) and math.abs(a - b) <= (e or 1e-6) end

------------------------------------------------------------------- a fake reskate.board
-- What the SDK does with each call, in its order, with its messages. config: owner (this plugin's id),
-- holder (another plugin that holds the board), permission (false: no "board"), refuse (a reason
-- toss answers with false), raise_toss, raise_clear, raise_bones (messages), answer (what toss returns
-- instead of true), bones (what bones() returns; default a drawn board), place_y and place_rotation (bone 1
-- of the default drawn board).
local BONE_TEXT = "invalid argument #1 to 'toss' (a board's bone is 2 to 15 (0 and 1 place the board))"
-- Made up: a board in the hand, its place (bone 1) a place in the world as board_pose.cpp takes it, 0.74 m
-- above a floor at 100 m unless place_y says otherwise, turned a quarter about the vertical (its up axis up).
local function drawn_board(place_y, place_rotation)
    local out = {}
    for i = 0, 15 do out[i] = {position = vector.create(0, 0, 0), rotation = {0, 0, 0, 1}, scale = vector.create(1, 1, 1)} end
    out[1] = {position = vector.create(10.21, place_y or 100.74, 19.95),
        rotation = place_rotation or {0, .7071067811865476, 0, .7071067811865476}, scale = vector.create(1, 1, 1)}
    out[2] = {position = vector.create(0, .081, .002), rotation = {.01, 0, 0, .99995}, scale = vector.create(1, 1, 1)}
    return out
end
local function new_fake(config)
    config = config or {}
    local f = {log = {}, clock = 0, second = -1000, count = 0, holder = config.holder, owner = config.owner or "bmx",
        pieces = 0}
    local function need(what)
        if config.permission == false then raise(what .. ' needs the "board" permission in reskate-plugin.json') end
    end
    local function vector_at(v, what)
        if type(v) ~= "vector" then raise("invalid argument #-1 to 'toss' (vector expected, got " .. typeof(v) .. ")") end
        for _, x in {v.x, v.y, v.z} do
            if not finite(x) or math.abs(x) > 1e5 then raise(what .. " must be a finite position within 100 km") end
        end
        return {v.x, v.y, v.z}
    end
    local board = {}
    function board.bones(...)
        table.insert(f.log, {kind = "bones", n = select("#", ...)})
        need("reskate.board.bones")
        if config.raise_bones then raise(config.raise_bones) end
        if config.bones ~= nil then
            if config.bones == false then return nil end
            return config.bones
        end
        return drawn_board(config.place_y, config.place_rotation)
    end
    function board.toss(...)
        local entry = {kind = "toss", n = select("#", ...)}
        table.insert(f.log, entry)
        local bones, options = ...
        need("reskate.board.toss")
        if type(bones) ~= "table" then raise("invalid argument #1 to 'toss' (table expected, got " .. typeof(bones) .. ")") end
        if #bones > 16 then raise("invalid argument #1 to 'toss' (a board has 16 bones)") end
        local list = {}
        for i = 1, #bones do
            local b = bones[i]
            if type(b) ~= "number" then raise("invalid argument #-1 to 'toss' (number expected, got " .. typeof(b) .. ")") end
            if not (b >= 2 and b <= 15) or b ~= math.floor(b) then raise(BONE_TEXT) end
            table.insert(list, b)
        end
        if type(options) ~= "table" then raise("invalid argument #2 to 'toss' (table expected, got " .. typeof(options) .. ")") end
        local velocity = vector_at(options.velocity, "the piece's velocity")
        local spin = options.spin == nil and {0, 0, 0} or vector_at(options.spin, "the piece's spin")
        if type(options.ground) ~= "number" then raise("invalid argument #-1 to 'toss' (number expected, got " .. typeof(options.ground) .. ")") end
        entry.bones, entry.velocity, entry.spin, entry.ground = list, velocity, spin, options.ground
        if config.raise_toss then raise(config.raise_toss) end
        -- The rate toss shares with skater.control and the other controls: 4 a second.
        if f.clock - f.second >= 1000 then f.second, f.count = f.clock, 0 end
        f.count += 1
        if f.count > 4 then entry.refused = "asked more than 4 times in a second";return false, entry.refused end
        if config.refuse then entry.refused = config.refuse;return false, config.refuse end
        -- board_pose.cpp toss.
        if #list == 0 then entry.refused = "a piece is bones 2 to 15";return false, entry.refused end
        local function len(v) return math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3]) end
        if len(velocity) > 50 or len(spin) > 50 or not finite(options.ground) then
            entry.refused = "a piece leaves at most 50 m/s, turning at most 50 rad/s";return false, entry.refused
        end
        if f.holder and f.holder ~= f.owner then entry.refused = f.holder .. " holds the board";return false, entry.refused end
        f.holder = f.owner
        f.pieces += 1
        if config.answer ~= nil then return config.answer end
        return true
    end
    function board.clear(...)
        local n = select("#", ...)
        table.insert(f.log, {kind = "clear", n = n})
        need("reskate.board.clear")
        if config.raise_clear then raise(config.raise_clear) end
        if f.holder == f.owner then f.holder, f.pieces = nil, 0 end
    end
    f.board = board
    f.api = {board = board}
    return f
end
local function count(f, kind)
    local n = 0
    for _, e in f.log do if e.kind == kind then n += 1 end end
    return n
end
-- An API that records every key read and every call, and refuses writes.
local function trapped(f)
    local touched = {}
    local board = setmetatable({}, {__index = function(_, k)
        table.insert(touched, "board." .. tostring(k))
        return f.board[k]
    end, __newindex = function() error("the module wrote to reskate.board", 0) end})
    local real = {board = board, skater = {pose = function() error("skater.pose must not be reached", 0) end},
        time = {now = function() error("time.now must not be reached", 0) end}}
    local api = setmetatable({}, {__index = function(_, k)
        table.insert(touched, tostring(k))
        return real[k]
    end, __newindex = function() error("the module wrote to reskate", 0) end})
    return api, touched
end

------------------------------------------------------------------- the suite
local function run()
    test("the module is frozen, its constants inside the SDK's limits, and constructing calls nothing", function()
        check(table.isfrozen(BD), "the module table is frozen")
        check(not pcall(function() BD.LIFT_MPS = 9 end), "a constant cannot be changed")
        check(BD.DECK_MOUNT == 2, "bone 2, the deck's mount, carries the whole visible board")
        check(BD.GROUND_OFFSET_M == 0, "the ground offset starts at 0 until a trial calibrates it")
        check(near(BD.REST_LIFT_M, .004, 1e-12) and near(BD.UPSIDE_LIFT_M, .141, 1e-12),
            "the native Board Break's lifts: 4 mm on its wheels, 0.141 m on its grip")
        check(near(BD.LIFT_MPS, .6) and near(BD.SPIN_RADPS, 1.5), "about 0.6 m/s up and 1.5 rad/s about the vertical")
        check(BD.LIFT_MPS > 0 and BD.LIFT_MPS < 50 and BD.SPIN_RADPS > 0 and BD.SPIN_RADPS < 50, "inside 50 m/s and 50 rad/s")
        local f = new_fake()
        local api, touched = trapped(f)
        local d = BD.new(api)
        check(#touched == 0 and #f.log == 0, "constructing read nothing and called nothing")
        local st = d:status()
        check(st.state == "idle" and st.toss_calls == 0 and st.clear_calls == 0 and st.bones_calls == 0 and st.ground == nil
            and st.floor == nil and st.up_y == nil and st.upside == nil and st.place_above_floor == nil
            and st.calibration == nil, "a new Dropper is idle")
        check(#touched == 0, "status reads nothing of the API")
    end)

    test("exact toss arguments: bone 2 alone, the lift and spin vectors, ground = floor + offset + rest lift", function()
        for _, floor in {100, 274.3612060546875, -12.5, 0} do
            -- Bone 1 in the hand 0.74 m above this floor, up axis up: it lands on its wheels.
            local f = new_fake({place_y = floor + .74})
            local d = BD.new(f.api)
            local r = d:drop(floor)
            check(r.ok == true and r.called == true and r.state == "dropped" and r.reason == nil, "accepted at " .. floor)
            check(#f.log == 2 and f.log[1].kind == "bones" and f.log[2].kind == "toss", "one bones read, then one toss")
            local t = f.log[2]
            check(t.n == 2, "toss gets exactly two arguments: " .. t.n)
            check(#t.bones == 1 and t.bones[1] == BD.DECK_MOUNT and t.bones[1] == 2, "the bone list is {2}")
            check(t.velocity[1] == 0 and near(t.velocity[2], BD.LIFT_MPS) and t.velocity[3] == 0, "velocity (0, lift, 0)")
            check(t.spin[1] == 0 and near(t.spin[2], BD.SPIN_RADPS) and t.spin[3] == 0, "spin (0, spin, 0)")
            local want = floor + BD.GROUND_OFFSET_M + BD.REST_LIFT_M
            check(near(t.ground, want, 1e-9), "ground is the floor plus the offset and the rest lift: " .. tostring(t.ground))
            check(t.refused == nil and f.pieces == 1 and f.holder == "bmx", "the SDK took the piece")
            local st = d:status()
            check(st.state == "dropped" and st.ground == t.ground and st.floor == floor and st.toss_calls == 1
                and st.toss_result == "accepted", "the status keeps the floor, the ground and the toss")
            check(st.upside == false and near(st.up_y, 1, 1e-9), "upright in the hand: no upside lift: " .. tostring(st.up_y))
            -- Positions are 32-bit vectors: 0.74 m within a float's step at these heights.
            check(near(st.place_above_floor, .74, 1e-4), "bone 1 was 0.74 m above the floor: " .. tostring(st.place_above_floor))
        end
    end)

    test("a board held upside down lands on its grip: the ground is raised by the upside lift", function()
        local half = math.rad(50) -- 100 degrees about X: the board nearly on its edge, its up axis a little down
        for _, case in {
            {rotation = {1, 0, 0, 0}, up = -1, upside = true},
            {rotation = {math.sin(half), 0, 0, math.cos(half)}, up = math.cos(math.rad(100)), upside = true},
            {rotation = {0, 0, math.sin(math.rad(40)), math.cos(math.rad(40))}, up = math.cos(math.rad(80)), upside = false},
            {rotation = {0, 0, 0, 2}, up = 1, upside = false}, -- not unit: normalised, as the SDK does
        } do
            local f = new_fake({place_rotation = case.rotation})
            local d = BD.new(f.api)
            check(d:drop(100).ok == true, "dropped")
            local st = d:status()
            check(st.upside == case.upside and near(st.up_y, case.up, 1e-9), "up y " .. tostring(st.up_y) .. " for " .. case.up)
            local want = 100 + BD.GROUND_OFFSET_M + BD.REST_LIFT_M + (case.upside and BD.UPSIDE_LIFT_M or 0)
            check(near(f.log[2].ground, want, 1e-9) and st.ground == f.log[2].ground, "ground " .. tostring(f.log[2].ground))
            check(near(BD.math.up_of(st.calibration), case.up, 1e-9), "BD.math.up_of reads the kept rotation")
        end
        -- Without bone 1's rotation the side is unknown: no upside lift, and the status says unknown.
        local g = new_fake({bones = {[1] = {position = vector.create(10, 100.8, 20)}}})
        local e = BD.new(g.api)
        check(e:drop(100).ok == true)
        local st = e:status()
        check(st.upside == nil and st.up_y == nil and near(g.log[2].ground, 100 + BD.GROUND_OFFSET_M + BD.REST_LIFT_M, 1e-9),
            "unknown side: floor + offset + rest lift")
        check(near(st.place_above_floor, .8, 1e-4), "bone 1's height is kept without its rotation")
        -- No bones at all: neither the side nor the height.
        local h = new_fake({bones = false})
        local k = BD.new(h.api)
        check(k:drop(100).ok == true and k:status().upside == nil and k:status().place_above_floor == nil, "nothing read")
        check(BD.math.up_of(nil) == nil and BD.math.up_of({place = {rotation = {0, 0, 0, 0}}}) == nil, "no usable rotation")
    end)

    test("the drop happens once", function()
        local f = new_fake()
        local d = BD.new(f.api)
        check(d:drop(100).ok == true)
        local again = d:drop(100)
        check(again.ok == false and again.called == false and again.reason == BD.ONCE and again.state == "dropped", tostring(again.reason))
        check(count(f, "toss") == 1 and count(f, "bones") == 1, "no second toss or bones read")
        check(d:status().state == "dropped" and d:status().reason == nil, "the first drop's state stands")
        local g = new_fake()
        local e = BD.new(g.api)
        check(e:drop(0 / 0).called == false)
        local later = e:drop(100)
        check(later.called == false and later.reason == BD.ONCE and #g.log == 0, "a refused drop is the one try too")
    end)

    test("a height that is not finite is refused with no call", function()
        -- Each height in its own table, so nil is a case too.
        for _, case in {{nil}, {0 / 0}, {math.huge}, {-math.huge}, {"100"}, {true}, {{100}}, {2e5}, {-1.5e5}} do
            local ground = case[1]
            local f = new_fake()
            local d = BD.new(f.api)
            local ok, r = pcall(d.drop, d, ground)
            check(ok, "drop never raises: " .. tostring(r))
            check(r.ok == false and r.called == false and r.state == "refused", "refused: " .. tostring(ground))
            check(string.find(r.reason, "no measured floor", 1, true) == 1, tostring(r.reason))
            check(#f.log == 0, "no SDK call, not even bones: " .. tostring(ground))
            local st = d:status()
            check(st.toss_calls == 0 and st.bones_calls == 0 and st.ground == nil, "nothing was read or sent")
            local back = d:restore()
            check(back.called == false and back.ok == true and #f.log == 0, "nothing to restore")
        end
    end)

    test("a refused toss keeps the board in the hand, and restore then calls nothing", function()
        for _, case in {{holder = "board-break", why = "board-break holds the board"}, {refuse = "asked more than 4 times in a second"}} do
            local f = new_fake({holder = case.holder, refuse = case.refuse})
            local d = BD.new(f.api)
            local r = d:drop(100)
            local why = case.why or case.refuse
            check(r.ok == false and r.called == true and r.state == "refused", "toss refused")
            check(r.reason == "board.toss refused: " .. why, tostring(r.reason))
            check(f.pieces == 0 and f.holder == case.holder, "the other holder keeps the board; no piece flies")
            local st = d:status()
            check(st.toss_result == "refused" and st.toss_calls == 1 and st.reason == r.reason, "the reason is kept")
            local back = d:restore()
            check(back.ok == true and back.called == false and back.state == "refused" and count(f, "clear") == 0,
                "nothing of ours to clear: no clear call")
            check(d:status().clear_calls == 0 and d:status().state == "refused", "restore changed nothing")
        end
        -- The rate the SDK keeps: a fifth control in one second refuses.
        local f = new_fake()
        for _ = 1, 4 do f.board.toss({3}, {velocity = vector.create(0, 0, 0), ground = 0}) end
        f.holder = nil
        local r = BD.new(f.api):drop(100)
        check(r.called == true and r.reason == "board.toss refused: asked more than 4 times in a second", tostring(r.reason))
    end)

    test("a raised toss leaves the state unknown, and restore still clears", function()
        for _, case in {{raise_toss = "the game is not ready"}, {permission = false}} do
            local f = new_fake(case)
            local d = BD.new(f.api)
            local ok, r = pcall(d.drop, d, 100)
            check(ok, "drop does not raise")
            check(r.ok == false and r.called == true and r.state == "unknown", "state unknown")
            check(string.find(r.reason, "board.toss raised: ", 1, true) == 1, tostring(r.reason))
            if case.permission == false then
                check(string.find(r.reason, '"board" permission', 1, true) ~= nil, "the permission message is kept: " .. r.reason)
                check(d:status().bones_result ~= "read" and d:status().calibration == nil, "bones() raised its permission too")
            end
            check(d:status().toss_result == "raised", "toss_result raised")
            local back = d:restore()
            check(back.called == true and count(f, "clear") == 1, "restore clears whatever may have flown")
            if case.permission == false then
                check(back.ok == false and back.state == "restore_unknown" and string.find(back.reason, "board.clear raised", 1, true) == 1,
                    "a clear without the permission raises: " .. tostring(back.reason))
            else
                check(back.ok == true and back.state == "restored", "restored")
                check(d:status().reason == r.reason and d:status().clear_result == "cleared", "the toss's reason stays")
            end
        end
        -- A toss that answers neither true nor false: unknown, and restore clears.
        local f = new_fake({answer = "yes"})
        local d = BD.new(f.api)
        local r = d:drop(100)
        check(r.state == "unknown" and r.called == true and d:status().toss_result == "malformed", tostring(r.reason))
        check(d:restore().called == true and count(f, "clear") == 1 and d:status().state == "restored")
        local g = new_fake({answer = nil})
        g.board.toss = function(...) table.insert(g.log, {kind = "toss"}) end -- answers nothing at all
        local e = BD.new(g.api)
        check(e:drop(100).state == "unknown" and e:restore().called == true, "an empty answer is unknown too")
    end)

    test("restore is idempotent", function()
        local f = new_fake()
        local d = BD.new(f.api)
        check(d:restore().called == false and #f.log == 0 and d:status().state == "idle", "before a drop it does nothing")
        check(d:drop(100).ok == true)
        local first = d:restore()
        check(first.ok == true and first.called == true and first.state == "restored", "restored")
        check(f.log[#f.log].kind == "clear" and f.log[#f.log].n == 0, "board.clear() with no bone: the whole hold")
        check(f.holder == nil and f.pieces == 0, "the SDK let go of the board")
        for _ = 1, 3 do
            local again = d:restore()
            check(again.ok == true and again.called == false and again.state == "restored", "again: nothing")
        end
        check(count(f, "clear") == 1 and d:status().clear_calls == 1 and d:status().clear_result == "cleared", "one clear")
        check(d:drop(100).called == false and count(f, "toss") == 1, "no drop after the restore either")
        -- A clear that raises: restore_unknown, once.
        local g = new_fake({raise_clear = "clear failed"})
        local e = BD.new(g.api)
        e:drop(100)
        local r = e:restore()
        check(r.ok == false and r.called == true and r.state == "restore_unknown" and r.reason == "board.clear raised: clear failed", tostring(r.reason))
        check(e:restore().called == false and count(g, "clear") == 1, "not again")
        -- A clear that went missing after the drop.
        local h = new_fake()
        local k = BD.new(h.api)
        k:drop(100)
        h.board.clear = nil
        local m = k:restore()
        check(m.called == false and m.state == "restore_unknown" and m.reason == "reskate.board.clear is missing", tostring(m.reason))
    end)

    test("a missing reskate.board or toss refuses with a reason and never raises", function()
        local raising = setmetatable({}, {__index = function() error("no such field", 0) end})
        local raising_board = {board = setmetatable({}, {__index = function() error("board is locked", 0) end})}
        for _, case in {{nil, "no reskate API was given"}, {5, "no reskate API was given"}, {{}, "reskate.board is missing"},
            {{board = 5}, "reskate.board is missing"}, {{board = {}}, "reskate.board.toss is missing"},
            {{board = {toss = 3, clear = function() end}}, "reskate.board.toss is missing"},
            {raising, "reading reskate.board raised: no such field"},
            {raising_board, "reading reskate.board.toss raised: board is locked"}} do
            local d = BD.new(case[1])
            local ok, r = pcall(d.drop, d, 100)
            check(ok, "drop did not raise: " .. tostring(r))
            check(r.ok == false and r.called == false and r.state == "refused" and r.reason == case[2],
                "refused with " .. case[2] .. ", got " .. tostring(r.reason))
            local fine, back = pcall(d.restore, d)
            check(fine and back.called == false, "restore did not raise and called nothing")
            local seen, st = pcall(d.status, d)
            check(seen and st.state == "refused" and st.reason == case[2] and st.toss_calls == 0, "status did not raise")
        end
        -- Methods called without their Dropper refuse, never raise.
        local d = BD.new(new_fake().api)
        for _, method in {"drop", "restore", "status"} do
            local ok, r = pcall(d[method], {}, 100)
            check(ok and type(r) == "table" and r.state == "refused", method .. " without its Dropper")
            ok, r = pcall(d[method], nil)
            check(ok and type(r) == "table", method .. " with nil")
        end
    end)

    test("bones() raising, empty, missing or malformed does not stop the drop", function()
        local cases_bones = {
            {config = {raise_bones = "not drawn yet"}, result = "raised: not drawn yet"},
            {config = {bones = false}, result = "none"},
            {config = {bones = {[1] = 3, [2] = "x"}}, result = "malformed"},
            {config = {bones = {[1] = {position = {1, 2, 3}, rotation = {0, 0, 0 / 0, 1}}}}, result = "malformed"},
        }
        for _, case in cases_bones do
            local f = new_fake(case.config)
            local d = BD.new(f.api)
            local r = d:drop(100)
            check(r.ok == true and r.called == true and r.state == "dropped", "dropped all the same: " .. case.result)
            local st = d:status()
            check(st.bones_result == case.result and st.calibration == nil and st.bones_calls == 1, tostring(st.bones_result))
            check(count(f, "toss") == 1 and f.log[1].kind == "bones" and f.log[2].kind == "toss", "bones first, then toss")
        end
        local f = new_fake()
        f.board.bones = nil
        local d = BD.new(f.api)
        check(d:drop(100).ok == true and d:status().bones_result == "missing" and d:status().bones_calls == 0, "board.bones is optional")
    end)

    test("the calibration keeps bones 1 and 2 as the board was drawn in the hand", function()
        local f = new_fake()
        local d = BD.new(f.api)
        d:drop(100)
        local st = d:status()
        local b = drawn_board()
        check(st.bones_result == "read" and type(st.calibration) == "table", "read")
        local place, mount = st.calibration.place, st.calibration.mount
        for i, axis in {"x", "y", "z"} do
            check(place.position[i] == b[1].position[axis] and mount.position[i] == b[2].position[axis], "position " .. axis)
        end
        for i = 1, 4 do check(place.rotation[i] == b[1].rotation[i] and mount.rotation[i] == b[2].rotation[i], "rotation " .. i) end
        check(f.log[1].kind == "bones" and f.log[1].n == 0, "bones() takes no argument")
        -- Each status is a fresh copy.
        st.calibration.place.position[2] = 99
        check(d:status().calibration.place.position[2] == b[1].position.y, "a status cannot change the next one")
        local only_place = BD.math.calibration_of({[1] = {position = vector.create(1, 2, 3)}})
        check(only_place.place.position[3] == 3 and only_place.place.rotation == nil and only_place.mount == nil, "one bone alone")
        check(BD.math.calibration_of(nil) == nil and BD.math.calibration_of({}) == nil, "nothing to keep")
    end)

    test("only board.bones, board.toss and board.clear are ever reached", function()
        local f = new_fake()
        local api, touched = trapped(f)
        local d = BD.new(api)
        d:drop(100)
        d:status()
        d:restore()
        d:restore()
        for _, key in touched do
            check(key == "board" or key == "board.bones" or key == "board.toss" or key == "board.clear", "read " .. key)
        end
        check(#f.log == 3 and f.log[1].kind == "bones" and f.log[2].kind == "toss" and f.log[3].kind == "clear",
            "bones, toss, clear: nothing else")
    end)

    return {cases = cases, assertions = assertions, native_calls = 0, game_evidence = false}
end

return {run = run}
