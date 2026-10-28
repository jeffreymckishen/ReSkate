-- D6a's fixed first-ride stages. Source substitutions belong only in reviewed
-- private trials; no runtime setting selects a stage or supplies authored caps.
local Forces=require("./forces")
local M=require("./force_math")
local STAGE = "hop_ride"
local AUTHORED_CAPS = {force=6000,speed=3,torque=2000,vertical_speed=6}
local hop_stage=STAGE=="hop" or STAGE=="hop_ride"
-- DEC-5 supplies force and measured-speed magnitudes here. The spawn-origin
-- envelope stays with Core/Spawn; this wrapper invents no anchor or authority.
-- Nonzero stages refuse while that decision remains unavailable.
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
        if budget.n>2048 or not (type(key)=="string" or type(key)=="number" and M.finite(key)) then return false end
        -- A scalar item gets finite_tree's own answer here, without a call per field.
        local inner=type(item)
        if inner=="number" then
            if not (item==item and math.abs(item)<math.huge) then return false end
        elseif inner=="table" then
            if not finite_tree(item,depth+1,budget) then return false end
        elseif inner~="boolean" and inner~="string" then return false end
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
        if name~="force" and name~="speed" and name~="torque" and not (hop_stage and name=="vertical_speed") then return false end
    end
    if AUTHORED_CAPS.torque~=nil and not (M.finite(AUTHORED_CAPS.torque) and AUTHORED_CAPS.torque>0
        and AUTHORED_CAPS.torque<=tuning.torque_limit) then return false end -- R1 declared change
    if hop_stage and not (M.finite(AUTHORED_CAPS.vertical_speed) and AUTHORED_CAPS.vertical_speed>0
        and AUTHORED_CAPS.vertical_speed<=50) then return false end
    return count==2+(AUTHORED_CAPS.torque~=nil and 1 or 0)+(hop_stage and 1 or 0) and M.finite(AUTHORED_CAPS.force) and AUTHORED_CAPS.force>0
        and AUTHORED_CAPS.force<=tuning.force_limit and M.finite(AUTHORED_CAPS.speed) and AUTHORED_CAPS.speed>0
end
local function speed_issue(body,tuning)
    if STAGE=="zero_force" then return nil end
    if not caps_valid(tuning) then return "authored_caps_unavailable" end
    if hop_stage then
        local up=M.unit(M.mul(tuning.gravity,-1))
        if not up then return "invalid_gravity" end
        local vertical=M.dot(body.linear_velocity,up)
        if M.length(M.sub(body.linear_velocity,M.mul(up,vertical)))>AUTHORED_CAPS.speed then return "authored_speed_limit" end
        if math.abs(vertical)>AUTHORED_CAPS.vertical_speed then return "authored_vertical_speed_limit" end
    elseif M.length(body.linear_velocity)>AUTHORED_CAPS.speed then return "authored_speed_limit" end
    return nil
end
function Stage.new(...)
    assert(select("#",...)==0,"force stage accepts no runtime configuration")
    assert(STAGE=="zero_force" or STAGE=="support" or STAGE=="pedal" or STAGE=="ride" or hop_stage,"invalid force stage")
    local kernel=Forces.new()
    -- Only authored hop stages retain hop intent. The longer current ray
    -- gives its landing law braking distance; it grants no contact or support.
    local tuning={gravity=table.freeze(M.copy(kernel.tuning.gravity))}
    if hop_stage then tuning.wheel_probe_extra=.75 end
    local self=setmetatable({hop_policy=hop_stage and "grounded_once" or "suppress",
        tuning=table.freeze(tuning)},Controller)
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
-- Measured admission is independent of the forecast: accepted braking cannot
-- erase a speed already observed beyond the authored envelope. This reads no
-- prediction history and does not create, consume or discard a candidate.
function Controller:admit_measured(body)
    local state=state_of(self)
    if not plain_finite(body) or not M.valid_body(body) then return false,"invalid_sample" end
    local issue=speed_issue(body,state.kernel.tuning)
    return issue==nil,issue or "none"
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
    local issue=speed_issue(body,state.kernel.tuning)
    if issue then return invalid(issue) end
    -- The raw pad and Mapping's action record stay unchanged. All force
    -- channels are neutral except each stage's finite, bounded authored inputs.
    local selected=Forces.controls()
    if STAGE=="pedal" or STAGE=="ride" or hop_stage then
        local pedal=controls and controls.pedal
        if pedal==nil then pedal=0 end
        if not M.finite(pedal) or pedal<0 or pedal>1 then return invalid("invalid_pedal") end
        selected.pedal=pedal
    end
    if STAGE=="ride" or STAGE=="hop_ride" then
        -- Both driving stages pass steer/brake. Only hop_ride also selects
        -- the hop policy below; manuals, air inputs and tricks remain neutral.
        local steer,brake=controls and controls.steer,controls and controls.brake
        if steer==nil then steer=0 end
        if brake==nil then brake=0 end
        if not M.finite(steer) or steer<-1 or steer>1 then return invalid("invalid_steer") end
        if not M.finite(brake) or brake<0 or brake>1 then return invalid("invalid_brake") end
        selected.steer,selected.brake=steer,brake
    end
    if hop_stage then
        local id=controls and controls.hop_event_id
        local strength=controls and controls.hop_strength
        if id==nil then id=0 end
        if strength==nil then strength=0 end
        if not M.finite(id) or id%1~=0 or id<0 or id>4294967295 or not M.finite(strength)
            or strength<0 or strength>1 or (id==0)~=(strength==0) then return invalid("invalid_hop") end
        selected.hop_event_id,selected.hop_strength=id,strength
        selected.contact_compliance_available=true
        selected.landing_contact_compliance_selected=true
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
    if hop_stage then
        if type(model.hop_applied)~="boolean" or (model.hop_applied and
            (model.hop_event_id~=selected.hop_event_id or model.hop_event_id==0 or M.length(model.hop_impulse)==0)) or
            (not model.hop_applied and (model.hop_event_id~=0 or M.length(model.hop_impulse)~=0)) then return invalid("unexpected_hop") end
    elseif model.hop_applied~=false or model.hop_event_id~=0 or M.length(model.hop_impulse)~=0 then return invalid("unexpected_hop") end
    if M.length(model.force)>state.kernel.tuning.force_limit or M.length(model.torque)>state.kernel.tuning.torque_limit then
        return invalid("kernel_output_limit",diagnostic_copy(model))
    end
    if STAGE~="zero_force" and M.length(model.force)>AUTHORED_CAPS.force then return invalid("authored_force_limit",diagnostic_copy(model)) end
    -- R1 declared change: torque refuses like force and speed (Ride adds no companion torque here).
    if STAGE~="zero_force" and AUTHORED_CAPS.torque~=nil and M.length(model.torque)>AUTHORED_CAPS.torque then
        return invalid("authored_torque_limit",diagnostic_copy(model))
    end
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
