-- Prepare coordinates without taking the camera. Only Apply requests a view.
local eye = {0, 0, 0}
local target = {0, 0, 1}
local fov, distance, height = 55, 1.5, 1.0
local prepared, requested = false, false
local invalid_edit = false
local message = "Get the current view or prepare a player view before Apply."
local last_view = nil

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function position(value)
    return value and finite(value.x) and finite(value.y) and finite(value.z)
        and math.abs(value.x) <= 100000 and math.abs(value.y) <= 100000 and math.abs(value.z) <= 100000
end

local function copy(value)
    return {value.x, value.y, value.z}
end

local function reason(prefix, value)
    message = prefix .. string.sub(tostring(value or "unavailable"), 1, 160)
end

local function valid_pose()
    if invalid_edit then return false, "Correct the refused edit and press Apply again." end
    if not prepared then return false, "Get or prepare a view first." end
    for _, point in ipairs({eye, target}) do
        for _, value in ipairs(point) do
            if not finite(value) or math.abs(value) > 100000 then
                return false, "Coordinates must be finite and within 100 km."
            end
        end
    end
    if not finite(fov) or fov < 40 or fov > 120 then return false, "FOV must be 40 to 120 degrees." end
    local squared = 0
    for axis = 1, 3 do squared = squared + (eye[axis] - target[axis]) ^ 2 end
    if not finite(squared) or squared <= 0.0001 then return false, "Eye and target must be more than 1 cm apart." end
    return true
end

local function get_view()
    local ok, view = pcall(reskate.camera.get)
    if not ok then reason("Get failed: ", view); return end
    if not view or not position(view.position) or not position(view.forward) or not finite(view.fov) then
        message = "No finite current camera view is available."
        return
    end
    local forward = view.forward
    local length = math.sqrt(forward.x ^ 2 + forward.y ^ 2 + forward.z ^ 2)
    if not finite(length) or length <= 0.0001 then message = "Current camera direction is unavailable."; return end
    eye = copy(view.position)
    target = {eye[1] + forward.x * distance / length, eye[2] + forward.y * distance / length,
        eye[3] + forward.z * distance / length}
    fov = math.max(40, math.min(120, view.fov))
    last_view = view
    prepared = true
    message = "Current view copied. Editing fields does not move the camera."
end

local function preset(side)
    local ok, player = pcall(reskate.skater.get)
    if not ok then reason("Player read failed: ", player); return end
    if not player or not position(player.position) or not finite(player.heading) then
        message = "No finite local player position and heading are available."
        return
    end
    if not finite(distance) or distance < 0.3 or distance > 10 or not finite(height) or height < 0 or height > 3 then
        message = "Preset distance must be 0.3 to 10 m; height must be 0 to 3 m."
        return
    end
    local sine, cosine = math.sin(player.heading), math.cos(player.heading)
    local x, z = sine, cosine
    if side == "Left" then x, z = -cosine, sine end
    if side == "Right" then x, z = cosine, -sine end
    target = {player.position.x, player.position.y + height, player.position.z}
    eye = {target[1] + x * distance, target[2], target[3] + z * distance}
    prepared = true
    message = side .. " player view prepared from a fresh position. Press Apply to use it."
end

local function apply()
    local valid, why = valid_pose()
    if not valid then reason("Apply refused: ", why); return end
    local ok, accepted, detail = pcall(reskate.camera.look, vector.create(eye[1], eye[2], eye[3]),
        vector.create(target[1], target[2], target[3]), fov)
    if not ok then reason("Apply failed: ", accepted); return end
    if not accepted then reason("Apply refused: ", detail); return end
    requested = true
    message = "View requested. Camera status below confirms when it is held."
end

local function release()
    local ok, why = pcall(reskate.camera.release)
    if not ok then reason("Release failed: ", why); return end
    requested = false
    message = "Release requested. Get the current view to inspect the restored camera."
end

local function vector_text(value)
    return string.format("%.4f, %.4f, %.4f", value.x, value.y, value.z)
end

local function edit(ui, id, label, value, minimum, maximum, format)
    local changed = ui:slider(id, label, value, minimum, maximum, format)
    if not finite(changed) or changed < minimum or changed > maximum then
        invalid_edit = true
        message = "Edit refused: " .. label .. " must be a finite number in its shown range."
        return value
    end
    return changed
end

reskate.menu.page("Camera Inspector", function(ui)
    invalid_edit = false
    ui:note("Apply alone takes the camera. Exit Freecam, Noclip or Spectate first.")
    if ui:button("get", "Get current view") then get_view() end
    ui:card("PLAYER VIEW", "Prepare only; the player is never moved or held.")
    distance = edit(ui, "distance", "Distance (m)", distance, 0.3, 10, "%.2f")
    height = edit(ui, "height", "Target height above player (m)", height, 0, 3, "%.2f")
    if ui:button("left", "Prepare Left") then preset("Left") end
    if ui:button("right", "Prepare Right") then preset("Right") end
    if ui:button("front", "Prepare Front") then preset("Front") end
    ui:card("EXACT VIEW", "Ctrl-click a coordinate slider to type a number.")
    for axis, name in ipairs({"X", "Y", "Z"}) do
        eye[axis] = edit(ui, "eye-" .. name, "Eye " .. name, eye[axis], -100000, 100000, "%.4f")
    end
    for axis, name in ipairs({"X", "Y", "Z"}) do
        target[axis] = edit(ui, "target-" .. name, "Target " .. name, target[axis], -100000, 100000, "%.4f")
    end
    fov = edit(ui, "fov", "Vertical FOV", fov, 40, 120, "%.1f")
    if ui:button("apply", "Apply view", true) then apply() end
    if ui:button("release", "Release camera") then release() end
    ui:info("Last action", message)
    if requested then
        local ok, held, why = pcall(reskate.camera.held)
        ui:info("Camera", ok and (held and "Held by this plugin" or string.sub(tostring(why or "Waiting"), 1, 180))
            or "Camera status is unavailable")
    else ui:info("Camera", "No view requested by this panel") end
    if last_view then
        ui:card("LAST READBACK", "From Get current view; not a renderer completion measurement.")
        ui:info("Position", vector_text(last_view.position))
        ui:info("Forward", vector_text(last_view.forward))
        ui:info("Vertical FOV", string.format("%.2f degrees", last_view.fov))
        ui:info("Free camera", tostring(last_view.free == true))
    end
end)

reskate.on("unload", release)
