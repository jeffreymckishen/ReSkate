-- D6a's fixed first-ride stages. Source substitutions belong only in reviewed
-- private trials; no runtime setting selects a stage or supplies authored caps.
local Forces=require("./forces")
local M=require("./force_math")
local STAGE = "zero_force"
local AUTHORED_CAPS = nil
-- DEC-5 supplies force and measured-speed magnitudes here. The spawn-origin
-- envelope stays with Core/Spawn; this wrapper invents no anchor or authority.
-- Both nonzero stages refuse while that decision remains unavailable.
local Stage={}
local Controller={} Controller.__index=Controller
local states=setmetatable({},{__mode="k"})
local function state_of(self)
    local state=states[self]
    assert(state,"unknown force stage controller")
    return state
end
local function finite_tree(value,depth,budget)
    local kind=type(value)
    if kind=="number" then return M.finite(value) end
    if kind=="nil" or kind=="boolean" or kind=="string" then return true end
    if kind~="table" or getmetatable(value)~=nil or depth>=12 then return false end
    for key,item in pairs(value) do
        budget.n+=1
        if budget.n>2048 or not (type(key)=="string" or type(key)=="number" and M.finite(key))
            or not finite_tree(item,depth+1,budget) then return false end
    end
    return true
end
local function plain_finite(value) return finite_tree(value,0,{n=0}) end
local function token() return table.freeze({}) end
local function invalid(issue,diagnostic)
    return {valid=false,issue=issue,grounded=false,force={0,0,0},torque={0,0,0},
        linear_impulse={0,0,0},angular_impulse={0,0,0},hop_impulse={0,0,0},
        hop_applied=false,hop_event_id=0,wheels={},diagnostic=diagnostic},token()
end
local function diagnostic_copy(model)
    local out=M.copy(model)
    out.diagnostic_only=true;out.force_applied=false
    return out
end
local function caps_valid(tuning)
    if type(AUTHORED_CAPS)~="table" or getmetatable(AUTHORED_CAPS)~=nil then return false end
    local count=0
    for name in pairs(AUTHORED_CAPS) do
        count+=1
        if name~="force" and name~="speed" then return false end
    end
    return count==2 and M.finite(AUTHORED_CAPS.force) and AUTHORED_CAPS.force>0
        and AUTHORED_CAPS.force<=tuning.force_limit and M.finite(AUTHORED_CAPS.speed) and AUTHORED_CAPS.speed>0
end
function Stage.new(...)
    assert(select("#",...)==0,"force stage accepts no runtime configuration")
    assert(STAGE=="zero_force" or STAGE=="support" or STAGE=="pedal","invalid force stage")
    local kernel=Forces.new()
    -- Every D6a stage suppresses hop intent before force preview. This fixed
    -- policy is not a native hop outcome or a runtime stage selector.
    local self=setmetatable({hop_policy="suppress",
        tuning=table.freeze({gravity=table.freeze(M.copy(kernel.tuning.gravity))})},Controller)
    states[self]={kernel=kernel}
    return table.freeze(self)
end
function Controller:reset()
    local state=state_of(self)
    state.pending=nil;state.kernel:reset()
end
function Controller:invalidate_continuity()
    local state=state_of(self)
    state.pending=nil
    state.kernel:invalidate_continuity()
end
function Controller:preview(h,body,wheels,samples,controls)
    local state=state_of(self)
    -- Only the latest valid preview can be adopted. Discarding a preview never
    -- advances force history; no raw kernel candidate leaves this module.
    state.pending=nil
    if not M.finite(h) or math.abs(h-Forces.native_seconds)>1e-8 then return invalid("unsupported_step") end
    if not plain_finite(body) or not M.valid_body(body) or type(wheels)~="table" or not plain_finite(wheels)
        or not M.valid_wheel(wheels[1]) or not M.valid_wheel(wheels[2]) or type(samples)~="table"
        or not plain_finite(samples) then return invalid("invalid_sample") end
    if controls~=nil and (type(controls)~="table" or getmetatable(controls)~=nil) then return invalid("invalid_controls") end
    if STAGE~="zero_force" and not caps_valid(state.kernel.tuning) then return invalid("authored_caps_unavailable") end
    if STAGE~="zero_force" and M.length(body.linear_velocity)>AUTHORED_CAPS.speed then return invalid("authored_speed_limit") end
    -- The raw pad and Mapping's action record stay unchanged. All force
    -- channels are neutral except the finite, bounded pedal in that one stage.
    local selected=Forces.controls()
    if STAGE=="pedal" then
        local pedal=controls and controls.pedal
        if pedal==nil then pedal=0 end
        if not M.finite(pedal) or pedal<0 or pedal>1 then return invalid("invalid_pedal") end
        selected.pedal=pedal
    end
    local preview=table.pack(pcall(state.kernel.preview,state.kernel,h,body,wheels,samples,selected))
    local model,candidate=preview[2],preview[3]
    if not preview[1] or preview.n~=3 or type(model)~="table" or type(candidate)~="table"
        or not plain_finite(model) then return invalid("kernel_unavailable") end
    if model.valid~=true then return invalid(model.issue or "kernel_invalid",diagnostic_copy(model)) end
    if not M.vec(model.force) or not M.vec(model.torque) or not M.vec(model.linear_impulse)
        or not M.vec(model.angular_impulse) or not M.vec(model.hop_impulse) or type(model.wheels)~="table"
        or not M.valid_wheel(model.wheels[1]) or not M.valid_wheel(model.wheels[2]) then return invalid("invalid_kernel_output") end
    for i=1,2 do
        if model.wheels[i].radius~=wheels[i].radius or model.wheels[i].inertia~=wheels[i].inertia then return invalid("invalid_kernel_wheels") end
    end
    -- The underlying kernel scales contacts to its own safety budgets. This
    -- nonzero stage rejects it. Zero keeps it hypothetical and still submits zero.
    if STAGE~="zero_force" and model.contact_scale~=1 then return invalid("kernel_clamped",diagnostic_copy(model)) end
    if model.hop_applied~=false or model.hop_event_id~=0 or M.length(model.hop_impulse)~=0 then return invalid("unexpected_hop") end
    if M.length(model.force)>state.kernel.tuning.force_limit or M.length(model.torque)>state.kernel.tuning.torque_limit then
        return invalid("kernel_output_limit",diagnostic_copy(model))
    end
    if STAGE~="zero_force" and M.length(model.force)>AUTHORED_CAPS.force then return invalid("authored_force_limit",diagnostic_copy(model)) end
    local result
    if STAGE=="zero_force" then
        -- Diagnostics describe a hypothetical neutral-kernel step. The actual
        -- zero command keeps wheel state and kernel history exactly unchanged.
        result={valid=true,issue="none",grounded=model.grounded,force={0,0,0},torque={0,0,0},
            linear_impulse={0,0,0},angular_impulse={0,0,0},hop_impulse={0,0,0},
            hop_applied=false,hop_event_id=0,wheels=M.copy(wheels),contact_scale=1,
            diagnostic=diagnostic_copy(model)}
    else result=M.copy(model) end
    local accepted=token()
    state.pending={token=accepted,kernel=candidate}
    return result,accepted
end
function Controller:_adopt(candidate)
    local state=state_of(self)
    local pending=state.pending
    assert(pending and pending.token==candidate,"force stage candidate is foreign, stale or already adopted")
    state.pending=nil
    if STAGE~="zero_force" then state.kernel:_adopt(pending.kernel) end
    -- Ride calls this once for exact SDK acceptance. Receipt ACKs never adopt,
    -- replay or reset predictions, and the token contains no editable history.
end
return table.freeze(Stage)
