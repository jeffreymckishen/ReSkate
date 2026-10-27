-- The rider's skateboard while he rides the bike: he drops it as he mounts and has it back in his hand
-- when the ride ends. A rider posed onto the bike (mounted_pose.lua) is still, to the game, a skater on
-- foot in state 504, and 504 is the state in which the skater carries his board, so without this the
-- board is drawn in his hand all through the ride.
--
-- Dropper:drop tosses the visible board with reskate.board.toss: bone 2, the deck's mount, which the
-- deck, trucks and wheels hang on (board_pose.h), leaves as one piece from where the board is drawn that
-- frame, rises a little, falls under gravity, lands flat pointing the way it was, slides a little and
-- lies there (board_pose.cpp toss and fly). Dropper:restore ends it with reskate.board.clear, and the
-- board is drawn in his hand again. A drop rather than board.hide: a board that falls and lies where
-- he got on reads as put down, where a hidden one would vanish from his hand.
--
-- Only what this machine draws changes. The game still has the skater carrying the board, and toss is
-- local: other players are sent the board as the game holds it, in his hand (only board.hide with
-- others=true filters the sent pose). One plugin holds the local board at a time (board_pose.cpp take):
-- while another plugin holds it, toss refuses, the board stays in the hand, and the caller rides on.
-- The SDK clears what a plugin holds when it unloads or is stopped (plugin_game_runtime.cpp release),
-- so a board left lying by a crash comes back then.
--
-- The ground is not found here. A board in the hand does not tell where the floor is: a piece tossed
-- from there hung at hand height (contrib/board-break.md). The caller passes a measured floor height
-- (bike_spawn.lua's one floor ray, Runtime:floor_height()). The piece lands when its frame, the
-- board's place (bone 1), reaches ground + GROUND_OFFSET_M, so 0 assumes that place lies on the
-- wheels' contact plane when the board lies on the floor. That has not been seen in the game: drop
-- reads board.bones() once first and keeps bones 1 and 2, so a trial can calibrate it.
--
-- A pure module: nothing runs on require, constructing a Dropper calls nothing, and no method raises.
-- The only functions it reaches are board.bones, board.toss and board.clear, each through pcall, each
-- looked up afresh when used; every result and status is a fresh table.
local BD = {}
-- board_pose.h: 0 is the board's reference and 1 its place in the world (the skater's clips move it;
-- the SDK never writes either). 2 is the deck's mount, and the deck, trucks and wheels hang on it, so
-- tossing 2 alone drops the whole visible board.
BD.DECK_MOUNT = 2
-- A small start upward, so the board reads as let go rather than snapped down: it rises about 2 cm
-- (v^2 / 2g) before it falls. Well inside the SDK's 50 m/s (board_pose.cpp toss).
BD.LIFT_MPS = .6
-- A slow turn about the vertical while it falls: under 1 rad over a fall from hand height (about half a
-- second). It lands flat whatever way it then faces. Well inside the SDK's 50 rad/s.
BD.SPIN_RADPS = 1.5
-- Where the board's place (bone 1) ends up above the measured floor. 0 assumes bone 1 lies on the
-- wheels' contact plane when the board lies flat. Unproved: a trial that sees the board float d m
-- above the floor sets -d, one that sees it sunk d m sets +d (the recorded bones 1 and 2 help).
BD.GROUND_OFFSET_M = 0
-- Heights within 100 km, as every position the plugin API takes (plugin_api.cpp position_of).
BD.HEIGHT_LIMIT = 1e5
BD.ONCE = "the board is dropped at most once per Dropper; this one has already tried"

local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function short(v)
    local text = tostring(v)
    text = string.gsub(text, "%c", " ")
    return #text > 180 and string.sub(text, 1, 177) .. "..." or text
end
local function freeze(t)
    for _, v in t do if type(v) == "table" and not table.isfrozen(v) then freeze(v) end end
    return table.freeze(t)
end
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in v do out[k] = copy(x) end
    return out
end

-- A board bone as board.bones() gives it ({position = vector, rotation = {x, y, z, w}, ...}), kept as
-- plain numbers: {position = {x, y, z}, rotation = {x, y, z, w}}, either part nil when it is not
-- finite. nil when neither is.
local function bone_of(b)
    if type(b) ~= "table" then return nil end
    local p, r = b.position, b.rotation
    local position, rotation = nil, nil
    if type(p) == "vector" and finite(p.x) and finite(p.y) and finite(p.z) then position = {p.x, p.y, p.z} end
    if type(r) == "table" and finite(r[1]) and finite(r[2]) and finite(r[3]) and finite(r[4]) then
        rotation = {r[1], r[2], r[3], r[4]}
    end
    if not position and not rotation then return nil end
    return {position = position, rotation = rotation}
end
-- Bones 1 (the board's place) and 2 (the deck's mount), each in its parent's frame as last drawn.
local function calibration_of(bones)
    if type(bones) ~= "table" then return nil end
    local place, mount = bone_of(bones[1]), bone_of(bones[BD.DECK_MOUNT])
    if not place and not mount then return nil end
    return {place = place, mount = mount}
end

-- The board function `name` of api, or nil and why. Reading api is guarded too: a table whose lookup
-- raises is a missing function, not a raise.
local function board_function(api, name)
    if type(api) ~= "table" then return nil, "no reskate API was given" end
    local ok, board = pcall(function() return api.board end)
    if not ok then return nil, "reading reskate.board raised: " .. short(board) end
    if type(board) ~= "table" then return nil, "reskate.board is missing" end
    local found, fn = pcall(function() return board[name] end)
    if not found then return nil, "reading reskate.board." .. name .. " raised: " .. short(fn) end
    if type(fn) ~= "function" then return nil, "reskate.board." .. name .. " is missing" end
    return fn
end

------------------------------------------------------------------- the dropper
local Dropper = {}
Dropper.__index = Dropper

-- api is the reskate table, or any table with board.toss and board.clear (board.bones optional).
-- Constructing one calls nothing and reads nothing of it.
function BD.new(api)
    return setmetatable({api = api, state = "idle", reason = nil, ground = nil, tried = false, restore_tried = false,
        toss_calls = 0, clear_calls = 0, bones_calls = 0, toss_result = nil, clear_result = nil, bones_result = nil,
        calibration = nil}, Dropper)
end

local function mine(self) return type(self) == "table" and getmetatable(self) == Dropper end
function Dropper:_result(ok, called)
    return {ok = ok, called = called, state = self.state, reason = self.reason}
end
function Dropper:_refuse(why)
    self.state, self.reason = "refused", why
    return self:_result(false, false)
end

-- Reads bones 1 and 2 once, before the toss, while the board is still in the hand. Optional: a
-- missing, raising or empty board.bones never stops the drop.
function Dropper:_calibrate()
    local bones = board_function(self.api, "bones")
    if not bones then
        self.bones_result = "missing"
        return
    end
    self.bones_calls += 1
    local ok, value = pcall(bones)
    if not ok then
        self.bones_result = "raised: " .. short(value)
    elseif value == nil then
        self.bones_result = "none" -- no board drawn yet
    else
        local fine, kept = pcall(calibration_of, value)
        self.calibration = fine and kept or nil
        self.bones_result = self.calibration and "read" or "malformed"
    end
end

-- Drops the board onto the floor at height ground_y (world metres, measured): one board.toss of the deck's
-- mount, at most once per Dropper. Returns {ok, called, state, reason}: ok only when toss accepted it;
-- called when board.toss was called. A height that is not finite, or a missing board.toss, refuses with
-- no call. A refusal from toss (false and why: another plugin holds the board, or its rate) leaves the
-- board in the hand with nothing to clear; a raise leaves the state unknown, since a raise after the
-- SDK took the piece cannot be told from one before.
function Dropper:drop(ground_y)
    if not mine(self) then return {ok = false, called = false, state = "refused", reason = "drop is a method: dropper:drop(ground_y)"} end
    if self.tried then return {ok = false, called = false, state = self.state, reason = BD.ONCE} end
    self.tried = true
    if not finite(ground_y) or math.abs(ground_y) > BD.HEIGHT_LIMIT then
        return self:_refuse("no measured floor: the ground is not a finite height within 100 km (" .. short(ground_y) .. ")")
    end
    local toss, missing = board_function(self.api, "toss")
    if not toss then return self:_refuse(missing) end
    local made, velocity, spin = pcall(function()
        return vector.create(0, BD.LIFT_MPS, 0), vector.create(0, BD.SPIN_RADPS, 0)
    end)
    if not made then return self:_refuse("the Luau vector library is unavailable: " .. short(velocity)) end
    self:_calibrate()
    local ground = ground_y + BD.GROUND_OFFSET_M
    self.ground = ground
    self.toss_calls += 1
    local r = table.pack(pcall(toss, {BD.DECK_MOUNT}, {velocity = velocity, spin = spin, ground = ground}))
    if not r[1] then
        self.state, self.reason, self.toss_result = "unknown", "board.toss raised: " .. short(r[2]), "raised"
        return self:_result(false, true)
    end
    -- plugin_api_world.cpp result(): true, or false and why.
    if r[2] == true then
        self.state, self.reason, self.toss_result = "dropped", nil, "accepted"
        return self:_result(true, true)
    end
    if r[2] == false then
        self.state, self.toss_result = "refused", "refused"
        self.reason = "board.toss refused: " .. (type(r[3]) == "string" and short(r[3]) or "no reason given")
        return self:_result(false, true)
    end
    -- Neither true nor false is not the toss this module knows; whether a piece flies is unknown.
    self.state, self.toss_result = "unknown", "malformed"
    self.reason = "board.toss answered " .. short(r[2]) .. ", not true or false"
    return self:_result(false, true)
end

-- Gives the board back: one board.clear(), only after a drop that toss accepted or that may have taken
-- effect (state dropped or unknown), and at most once. Without such a drop it calls nothing and changes
-- nothing. Returns {ok, called, state, reason}; state restored, or restore_unknown when clear raised or
-- was missing.
function Dropper:restore()
    if not mine(self) then return {ok = false, called = false, state = "refused", reason = "restore is a method: dropper:restore()"} end
    if self.restore_tried then return self:_result(self.state == "restored", false) end
    if self.state ~= "dropped" and self.state ~= "unknown" then return self:_result(true, false) end
    self.restore_tried = true
    local clear, missing = board_function(self.api, "clear")
    if not clear then
        self.state, self.clear_result, self.reason = "restore_unknown", "missing", missing
        return self:_result(false, false)
    end
    self.clear_calls += 1
    local ok, why = pcall(clear)
    if ok then
        -- A toss that raised keeps its reason; toss_result says what it was.
        self.state, self.clear_result = "restored", "cleared"
        return self:_result(true, true)
    end
    self.state, self.clear_result, self.reason = "restore_unknown", "raised", "board.clear raised: " .. short(why)
    return self:_result(false, true)
end

-- A fresh table: state (idle, dropped, refused, unknown, restored or restore_unknown), reason, ground
-- (the height passed to toss, or nil), the calls made, what toss, clear and bones answered, and the
-- calibration {place = bone 1, mount = bone 2} or nil.
function Dropper:status()
    if not mine(self) then return {state = "refused", reason = "status is a method: dropper:status()"} end
    return {state = self.state, reason = self.reason, ground = self.ground, toss_calls = self.toss_calls,
        clear_calls = self.clear_calls, bones_calls = self.bones_calls, toss_result = self.toss_result,
        clear_result = self.clear_result, bones_result = self.bones_result, calibration = copy(self.calibration)}
end

BD.math = freeze({calibration_of = calibration_of})
return table.freeze(BD)
