-- Pure bounded observation coordinator. Providers expose read operations only.
-- Last-evaluated joint copies never become an epoch, owner or write authority.
local S={}
local MAX, DEADLINE, READ_LIMIT = 9007199254740991,1500,32
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function copy(v)
    if type(v)~="table" then return v end
    local out={} for k,x in pairs(v) do out[k]=copy(x) end return out
end
local function vec(v)
    if type(v)~="table" then return false end
    for i=1,3 do if not finite(v[i]) or math.abs(v[i])>1000000 then return false end end
    return true
end
local function quat(q)
    if type(q)~="table" then return false end
    local n=0
    for i=1,4 do if not finite(q[i]) then return false end n+=q[i]*q[i] end
    return finite(n) and n>0 and math.abs(n-1)<=.02
end
local function distance(a,b)
    return math.sqrt((a[1]-b[1])^2+(a[2]-b[2])^2+(a[3]-b[3])^2)
end
local function angle(a,b)
    local dot,aa,bb=0,0,0
    for i=1,4 do dot+=a[i]*b[i];aa+=a[i]^2;bb+=b[i]^2 end
    return 2*math.acos(math.clamp(math.abs(dot)/math.sqrt(aa*bb),0,1))
end
local function heading_delta(a,b) return math.abs((a-b+math.pi)%(2*math.pi)-math.pi) end
local bools={"focused","gameplay","interface_open","native_menu_open","skater","watch_valid","ragdoll_known",
    "ragdoll","teleport_pending","airborne","telemetry_airborne"}
local scalars={"state","heading","telemetry_heading","speed","vertical_speed","telemetry_speed","telemetry_vertical"}
local function position(v)return {v[1],v[2],v[3]}end
local function rotation(v)return {v[1],v[2],v[3],v[4]}end
local function facts_copy(f)
    local out={}
    if type(f)~="table" then return out end
    if type(f.level)=="string"and #f.level>0 and #f.level<=200 then out.level=f.level end
    for _,key in ipairs(bools)do if type(f[key])=="boolean"then out[key]=f[key]end end
    for _,key in ipairs(scalars)do if finite(f[key])and math.abs(f[key])<=MAX then out[key]=f[key]end end
    for _,key in ipairs({"position","telemetry_position"})do if vec(f[key])then out[key]=position(f[key])end end
    return out
end
local function checked_facts(f)
    if type(f)~="table" or type(f.level)~="string" or #f.level==0 or #f.level>200 then return nil,"context_unknown" end
    for _,key in ipairs({"focused","gameplay","interface_open","native_menu_open","skater","watch_valid","ragdoll_known",
        "ragdoll","teleport_pending","airborne","telemetry_airborne"}) do
        if type(f[key])~="boolean" then return nil,"context_unknown" end
    end
    if not f.focused or not f.gameplay or f.native_menu_open then return nil,"focus_or_menu_lost" end
    if not f.skater or not f.watch_valid or f.state~=504 or not f.ragdoll_known or f.ragdoll or f.teleport_pending or
        f.airborne or f.telemetry_airborne then return nil,"upright_onfoot_unknown" end
    if not vec(f.position) or not vec(f.telemetry_position) then return nil,"position_unknown" end
    for _,key in ipairs({"heading","telemetry_heading","speed","vertical_speed","telemetry_speed","telemetry_vertical"}) do
        if not finite(f[key]) or math.abs(f[key])>1000000 then return nil,"movement_unknown" end
    end
    if math.abs(f.speed)>.05 or math.abs(f.vertical_speed)>.05 or math.abs(f.telemetry_speed)>.05 or
        math.abs(f.telemetry_vertical)>.05 then return nil,"movement_observed" end
    return facts_copy(f)
end
local function joint_row(raw,bone)
    if type(raw)~="table" then return nil,raw==nil and "joint_unavailable" or "joint_malformed" end
    if not vec(raw.position) then return nil,"joint_position_invalid" end
    if not quat(raw.rotation) then return nil,"joint_rotation_invalid" end
    if not finite(raw.scale) or raw.scale<=0 or raw.scale>10 then return nil,"joint_scale_invalid" end
    if raw.parent~=bone.parent then return nil,"joint_parent_mismatch" end
    return {requested_id=bone.id,source_name=bone.name,sdk_alias=bone.alias,parent=raw.parent,
        position=position(raw.position),rotation=rotation(raw.rotation),scale=raw.scale}
end
local function hand_row(raw,side,id)
    if type(raw)~="table" then return nil,raw==nil and "hand_unavailable" or "hand_malformed" end
    if not vec(raw.position) or not quat(raw.rotation) then return nil,"hand_transform_invalid" end
    return {side=side,requested_id=id,position=position(raw.position),rotation=rotation(raw.rotation)}
end
local Model={};Model.__index=Model
function S.new(readers,bones)
    assert(type(readers)=="table" and type(bones)=="table" and #bones==14,"fixed sampler dependencies required")
    for _,name in ipairs({"now","facts","joint","hand"}) do assert(type(readers[name])=="function","read provider missing") end
    local specs,seen={},{}
    for i,bone in ipairs(bones)do
        assert(type(bone)=="table"and finite(bone.id)and bone.id%1==0 and bone.id>=0 and bone.id<=394 and not seen[bone.id],"distinct bone IDs required")
        assert(finite(bone.parent)and bone.parent%1==0 and bone.parent>=0 and bone.parent<=394,"known parent ID required")
        assert(type(bone.name)=="string"and #bone.name>0 and #bone.name<=64,"bounded source bone name required")
        assert(bone.alias==nil or type(bone.alias)=="string"and #bone.alias<=32,"bounded SDK alias required")
        seen[bone.id]=true;specs[i]={id=bone.id,parent=bone.parent,name=bone.name,alias=bone.alias}
    end
    assert(specs[1].id==1 and specs[5].id==49 and specs[8].id==278,"fixed root and hand slots required")
    return setmetatable({api={now=readers.now,facts=readers.facts,joint=readers.joint,hand=readers.hand},bones=specs,
        phase="idle",used=false,reads=0,warm=1,index=1,settle=0},Model)
end
function Model:status()
    return {phase=self.phase,used=self.used,pose_reads=self.reads,limit=READ_LIMIT,issue=self.issue,
        joints=self.dto and #self.dto.joints or 0,complete=self.phase=="complete",native_authority=false}
end
function Model:result() return self.terminal and copy(self.dto) or nil end
function Model:finish(phase,why)
    if self.terminal then return end
    self.phase,self.issue,self.terminal=phase,why,true
    self.dto.phase,self.dto.issue,self.dto.pose_reads=phase,why,self.reads
    self.dto.end_ms=self.last_time
end
function Model:request()
    if self.used then return false end
    self.used=true;self.phase="warming"
    self.dto={schema=1,kind="stationary-anchor-observations-v1",phase="warming",joints={},hands={},
        warm_nil=0,facts_samples=0,coherent_pose=false,same_actor_known=false,same_session_known=false,
        native_authority=false,body_relative=false,world_basis="SDK last-evaluated world copies; no coherent epoch",
        root_alias_note="SDK root is joint1 with parent0; joint0 is not sampled",
        facts_scope="First/last validated facts; refused_facts retains only finite bounded observed fields",
        timestamp_scope="time.now milliseconds bracketing reads; end_ms is the last sampled clock, not event UTC",
        heading_units={heading="radians",telemetry_heading="degrees",drift_limit="radians"},
        limits={distinct_joint_ids=14,total_pose_reads=32,pose_reads_per_tick=2,deadline_ms=1500,
            max_reported_speed=.05,max_reported_vertical=.05,max_position_drift=.02,max_heading_drift=.02,
            max_root_drift=.01,max_root_angle=.02},stationary_observed=false}
    return true
end
function Model:cancel()
    if self.used and not self.terminal then self:finish("partial","cancelled") end
end
function Model:time()
    local ok,value=pcall(self.api.now)
    if not ok or not finite(value) or value<0 or value>MAX or self.last_time and value<self.last_time then
        self:finish("partial","clock_unknown");return nil
    end
    self.last_time=value
    if not self.start then self.start=value;self.dto.start_ms=value end
    if value-self.start>DEADLINE then self:finish("partial","deadline");return nil end
    return value
end
function Model:facts()
    local begin=self:time();if not begin then return nil end
    local ok,value=pcall(self.api.facts)
    local ended=self:time();if not ended or self.terminal then return nil end
    local f,why=checked_facts(ok and value or nil)
    if not f then
        self.dto.refused_facts=facts_copy(ok and value or nil)
        self.dto.refused_facts.read_begin_ms,self.dto.refused_facts.read_end_ms=begin,ended
        self:finish("partial",why);return nil
    end
    f.read_begin_ms,f.read_end_ms=begin,ended
    if self.first then
        if f.level~=self.first.level then self.dto.refused_facts=copy(f);self:finish("partial","context_changed");return nil end
        if distance(f.position,self.first.position)>.02 or distance(f.telemetry_position,self.first.telemetry_position)>.02 or
            heading_delta(f.heading,self.first.heading)>.02 or
            heading_delta(math.rad(f.telemetry_heading),math.rad(self.first.telemetry_heading))>.02 then
            self.dto.refused_facts=copy(f);self:finish("partial","movement_observed");return nil
        end
    else self.first=copy(f);self.dto.first_facts=copy(f) end
    self.dto.last_facts=copy(f);self.dto.facts_samples+=1
    return f
end
function Model:read(kind,bone,side)
    if self.reads>=READ_LIMIT then self:finish("partial","read_budget");return nil end
    local begin=self:time();if not begin then return nil end
    self.reads+=1
    local ok,raw
    if kind=="hand" then ok,raw=pcall(self.api.hand,side) else ok,raw=pcall(self.api.joint,bone.id) end
    local ended=self:time();if not ended or self.terminal then return nil end
    if not ok then self.dto.failed={kind=kind,requested_id=bone.id,begin_ms=begin,end_ms=ended};self:finish("partial","read_exception");return nil end
    if kind=="warm" then if raw==nil then self.dto.warm_nil+=1 end;return true end
    local row,why
    if kind=="hand" then row,why=hand_row(raw,side,bone.id) else row,why=joint_row(raw,bone) end
    if not row then self.dto.failed={kind=kind,requested_id=bone.id,begin_ms=begin,end_ms=ended};self:finish("partial",why);return nil end
    row.read_begin_ms,row.read_end_ms=begin,ended
    return row
end
function Model:advance_capture()
    local at=self.index
    if at==1 then self.dto.root_before=self:read("root",self.bones[1])
    elseif at<=15 then
        local row=self:read("joint",self.bones[at-1]);if row then table.insert(self.dto.joints,row) end
    elseif at==16 then self.dto.hands.left=self:read("hand",self.bones[8],"left")
    elseif at==17 then self.dto.hands.right=self:read("hand",self.bones[5],"right")
    else self.dto.root_after=self:read("root",self.bones[1]) end
    self.index+=1
end
function Model:complete()
    local a,b=self.dto.root_before,self.dto.root_after
    if distance(a.position,b.position)>.01 or angle(a.rotation,b.rotation)>.02 then self:finish("partial","root_movement_observed");return end
    self.dto.root_drift=distance(a.position,b.position);self.dto.root_angle=angle(a.rotation,b.rotation)
    self.dto.hand_residuals={scope="Different read times and last-evaluated copies; diagnostic only"}
    for _,item in ipairs({{side="left",index=8},{side="right",index=5}}) do
        local hand,joint=self.dto.hands[item.side],self.dto.joints[item.index]
        self.dto.hand_residuals[item.side]={position=distance(hand.position,joint.position),angle=angle(hand.rotation,joint.rotation)}
    end
    self.dto.stationary_observed=true;self:finish("complete","finite_stationary_observations_only")
end
function Model:step()
    if not self.used or self.terminal then return self:status() end
    if not self:facts() then return self:status() end
    if self.phase=="warming" then
        for _=1,2 do
            if self.warm>#self.bones then break end
            if not self:read("warm",self.bones[self.warm]) then break end
            self.warm+=1
        end
        if not self.terminal and self.warm>#self.bones then self.phase="settling";self.settle=2 end
    elseif self.phase=="settling" then
        self.settle-=1;if self.settle==0 then self.phase="capturing" end
    else
        for _=1,2 do
            if self.index>18 or self.terminal then break end
            self:advance_capture()
        end
    end
    if not self.terminal and self:facts() and self.phase=="capturing" and self.index>18 then self:complete() end
    return self:status()
end
return table.freeze(S)
