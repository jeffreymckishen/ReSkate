-- Pure mod-local accounting. A feed is an observation, never a native score write.
local Rules = require("./score_rules")
local Catalog = require("./score_catalog")
local Names = require("./trick_names")
local Line = {}
local Object = {}
Object.__index = Object
local MAX = Rules.MAX_SCORE
local modes = { rolling=true, airborne=true, manual=true, nose_manual=true, grinding=true, stalling=true, bailed=true }
local ground_categories = { manual=true, grind=true, stall=true }
local grind_kinds = { double_peg=true, feeble=true, smith=true, icepick=true, toothpick=true, stall=true }
local manual_exits = { front_drop=true, rear_drop=true, hop_out=true, airborne=true }
local bail_reasons = { bail=true, bailed=true, loop_out=true, nose_over=true, tilt_stop=true, roll_stop=true }
local function plain(value) return type(value) == "table" and getmetatable(value) == nil end
local function number(value, low, high)
    return Rules.finite(value) and value >= low and value <= high
end
local function integer(value, high) return number(value, 0, high) and value == math.floor(value) end
local function sat(value) return math.floor(math.clamp(value, 0, MAX)) end
local function reason(value, fallback)
    return type(value) == "string" and #value > 0 and #value <= 160 and value or fallback
end
local function is_bail(value)
    return bail_reasons[value] == true or (type(value) == "string" and #value<=160
        and (string.match(value, "^measured tilt .+ over the %d+ deg Ride stop$") ~= nil
        or string.match(value, "^measured roll rate .+ over the %d+ rad/s Ride stop$") ~= nil))
end
local function empty(self)
    self._active, self._points, self._tricks, self._links = false, 0, 0, 0
    self._categories, self._category_count, self._repeats, self._repeat_count = {}, 0, {}, 0
    self._remaining, self._idle, self._last_credit = 0, 0, nil
    self._airborne, self._manual, self._grind = false, nil, nil
end
function Line.new(rules)
    local self = setmetatable({ _rules=Rules.sanitize(rules), _seconds=nil }, Object)
    empty(self)
    return self
end
function Object:_multiplier()
    local r = self._rules
    return math.min(r.multiplier_cap, 1 + r.category_step*self._category_count
        + r.link_step*math.min(r.max_links,self._links))
end
function Object:_snapshot()
    local multiplier = self:_multiplier()
    return { active=self._active, points=self._points, score=sat(self._points*multiplier),
        multiplier=multiplier, tricks=self._tricks, links=self._links, categories=self._category_count,
        remaining=self._remaining, airborne=self._airborne,
        manual_seconds=self._manual and self._manual.seconds or 0,
        grind_points=self._grind and sat(self._grind.points) or 0 }
end
function Object:_close(outcome, why)
    local multiplier = self:_multiplier()
    local closed
    if self._active or outcome=="lost" or self._airborne or self._manual or self._grind then
        closed = { outcome=outcome, reason=why, points=self._points, multiplier=multiplier,
            score=outcome=="lost" and 0 or sat(self._points*multiplier), tricks=self._tricks }
    end
    empty(self)
    return closed
end
function Object:_repeat(key)
    return math.max(self._rules.repeat_floor, 1-self._rules.repeat_step*(self._repeats[key] or 0))
end
function Object:_credit(points, categories, name, seconds, keys, landing)
    local fresh = 0
    for _, key in ipairs(keys or {}) do if not self._repeats[key] then fresh += 1 end end
    if self._repeat_count + fresh > Rules.MAX_REPEAT_KEYS then return nil, "repeat_capacity" end
    local ground = false
    for _, category in ipairs(categories) do
        if not self._categories[category] then
            self._categories[category], self._category_count = true, self._category_count+1
        end
        ground = ground or ground_categories[category] == true
    end
    local prior = self._last_credit
    if prior and seconds-prior.seconds <= self._rules.link_seconds and (ground or prior.ground) then
        self._links = math.min(self._rules.max_links,self._links+1)
    end
    self._active, self._points, self._tricks = true, sat(self._points+points), sat(self._tricks+1)
    self._remaining, self._idle = self._rules.line_seconds, 0
    self._last_credit = { seconds=seconds, ground=ground }
    for _, key in ipairs(keys or {}) do
        if not self._repeats[key] then self._repeat_count += 1 end
        self._repeats[key] = math.min(100,self._repeats[key] or 0)+1
    end
    return { name=name, points=points, landing=landing, multiplier=self:_multiplier(), score=sat(self._points*self:_multiplier()) }
end
local function read_air(air)
    if not plain(air) or not number(air.air_seconds,0,Rules.MAX_AIR_SECONDS) or air.overflow == true
        or (air.overflow ~= nil and type(air.overflow) ~= "boolean")
        or (air.fakie_takeoff ~= nil and type(air.fakie_takeoff) ~= "boolean") then return nil end
    local out = { air_seconds=air.air_seconds, fakie_takeoff=air.fakie_takeoff==true, rows={} }
    for _, key in ipairs({"spin_half_turns","front_flips","back_flips","barrel_rolls"}) do
        local value = air[key]
        if value==nil then value=0 end
        if not integer(value,key=="spin_half_turns" and Rules.MAX_HALF_TURNS or 2) then return nil end
        out[key] = value
    end
    -- The event projector derives front/back from one signed pitch rotation.
    if out.front_flips>0 and out.back_flips>0 then return nil end
    if not plain(air.sequence) then return nil end
    -- Look up only the bounded prefix. A sparse, oversized or keyed sequence is refused.
    local count = 0
    for key in pairs(air.sequence) do
        if not integer(key,Rules.MAX_SEQUENCE) or key < 1 then return nil end
        count += 1
        if count > Rules.MAX_SEQUENCE then return nil end
    end
    for i=1,count do
        local row=air.sequence[i]
        if not plain(row) or (row.kind~="bar" and row.kind~="tail" and row.kind~="move")
            or not integer(row.id,1000) or not number(row.start,0,air.air_seconds)
            or not number(row.finish,row.start,air.air_seconds)
            or not number(row.hold==nil and 0 or row.hold,0,row.finish-row.start)
            or (row.dir~=nil and row.dir~=-1 and row.dir~=0 and row.dir~=1) then return nil end
        local info=Catalog.get(row.id)
        if not info or (row.kind=="bar" and info.key~="barspin")
            or (row.kind=="tail" and info.key~="tailwhip")
            or (info.key=="barspin" and row.kind~="bar")
            or (info.key=="tailwhip" and row.kind~="tail")
            or row.finish<=row.start or (i>1 and row.start<out.rows[i-1].start) then return nil end
        for _,prior in ipairs(out.rows) do
            if prior.info.key==info.key and row.start<prior.finish and row.finish>prior.start then return nil end
        end
        out.rows[i]={ kind=row.kind, info=info, start=row.start, finish=row.finish, hold=row.hold or 0 }
    end
    if air.landing~=nil then
        local l=air.landing
        if not plain(l) or not number(l.body_up,-1.000001,1.000001) or not number(l.heading_cos,-1,1)
            or not number(l.closing,0,1000000) then return nil end
        out.landing={body_up=math.clamp(l.body_up,-1,1),heading_cos=l.heading_cos,closing=l.closing}
    end
    return out
end
function Object:_air(a,seconds)
    local r=self._rules
    local factor,label=r.sketchy_factor,nil
    if a.landing then
        local l=a.landing
        local clean=math.abs(l.body_up)>=r.clean_alignment and math.abs(l.heading_cos)>=r.clean_heading
            and l.closing<=r.clean_closing
        factor,label=clean and 1 or r.sketchy_factor,clean and "Clean" or "Sketchy"
    end
    local groups,by_key,keys,categories,seen_category={}, {}, {}, {}, {}
    local function category(name)
        if not seen_category[name] then seen_category[name]=true;table.insert(categories,name) end
    end
    local function key(name) table.insert(keys,name) end
    local catches={bar=0,tail=0}
    for _,row in ipairs(a.rows) do
        local info=row.info
        local part=by_key[info.key]
        if not part then
            part={key=info.key,display=info.display,count=0,start=row.start,finish=row.finish,value=0,overlap=false,intervals={}}
            by_key[info.key]=part;table.insert(groups,part);key(info.key);category(info.category)
        end
        table.insert(part.intervals,{start=row.start,finish=row.finish})
        part.count+=1;part.start=math.min(part.start,row.start);part.finish=math.max(part.finish,row.finish)
        local hold=info.pose and 1+r.hold_bonus*math.min(1,row.hold/r.hold_seconds) or 1
        local catch=1
        if row.kind=="bar" or row.kind=="tail" then
            catches[row.kind]+=1
            catch=1+r.catch_step*(catches[row.kind]-1)
        end
        -- Each completed catch contributes: double bar is base*(1+1.5), not base*1.5.
        part.value+=r.base[info.difficulty]*hold*catch
        if row.kind=="bar" or row.kind=="tail" then
            for _,other in ipairs(a.rows) do
                if (row.kind=="bar" and other.kind=="tail") or (row.kind=="tail" and other.kind=="bar") then
                    local duration=math.min(row.finish-row.start,other.finish-other.start)
                    local overlap=math.min(row.finish,other.finish)-math.max(row.start,other.start)
                    if duration>0 and overlap>=r.overlap_fraction*duration then part.overlap=true end
                end
            end
        end
    end
    local spin=a.spin_half_turns
    local flips=a.front_flips+a.back_flips
    local rolls=a.barrel_rolls
    local part_points,spin_points,flip_points=0,0,0
    for _,part in ipairs(groups) do
        part_points+=part.value*(part.overlap and r.overlap_factor or 1)*self:_repeat(part.key)
    end
    if spin>0 then
        local spin_key="rotation:"..spin
        key(spin_key);category("rotation")
        spin_points=r.spin_base*spin*(1+r.spin_step*(spin-1))*self:_repeat(spin_key)
    end
    for _,axis in ipairs({{"front_flip",a.front_flips},{"back_flip",a.back_flips},{"barrel_roll",rolls}}) do
        if axis[2]>0 then
            key(axis[1]);category("flip")
            flip_points+=(axis[2]==1 and r.flip_single or r.flip_double)*self:_repeat(axis[1])
        end
    end
    local air_points=math.floor(r.air_rate*math.max(0,a.air_seconds-r.air_free_seconds))
    local points
    if #keys==0 then
        if a.air_seconds<r.hop_min_seconds then return nil end
        key("bunny_hop");category("air")
        points=sat((r.hop_base*self:_repeat("bunny_hop")+air_points)*factor)
    else
        local rotation=math.min(r.rotation_cap,1+r.rotation_step*spin+r.flip_rotation_step*(flips+rolls))
        local combo=math.min(r.combo_cap,1+r.combo_step*(#keys-1))
        points=sat(((part_points*rotation+spin_points+flip_points)*combo+air_points)*factor)
    end
    local name=Names.format({parts=groups,spin_half_turns=spin,front_flips=a.front_flips,
        back_flips=a.back_flips,barrel_rolls=rolls,fakie_takeoff=a.fakie_takeoff,
        heading_cos=a.landing and a.landing.heading_cos or nil})
    return self:_credit(points,categories,name,seconds,keys,label)
end
local function valid_event(event,kind)
    if event==nil then return true end
    if not plain(event) or type(event.event)~="string" then return false end
    if kind=="manual" then
        return (event.event=="balancing" or event.event=="ended") and
            (event.kind=="manual" or event.kind=="nose_manual")
    end
    return (event.event=="lock_on" or event.event=="grind_changed" or event.event=="exit")
        and grind_kinds[event.grind]==true
end
function Object:step(h,feed)
    local credits,closed={},nil
    local function result(issue)
        return {snapshot=self:_snapshot(),credits=credits,closed=closed,issue=issue or "none"}
    end
    if not number(h,0,10) or not plain(feed) or not number(feed.seconds,0,MAX)
        or not modes[feed.mode] or not number(feed.speed,-1000,1000)
        or not valid_event(feed.manual,"manual") or not valid_event(feed.grind,"grind")
        or (feed.air~=nil and not plain(feed.air)) or (feed.ended~=nil and not plain(feed.ended)) then
        closed=self:_close("interrupted","invalid_feed");return result("invalid_feed")
    end
    if self._seconds~=nil and feed.seconds<=self._seconds then return result("stale_feed") end
    self._seconds=feed.seconds
    local ending=feed.ended
    -- Failure beats the landed flag, which existing trick events also set on a bail.
    if feed.mode=="bailed" or (feed.air and feed.air.failed)
        or (feed.manual and is_bail(feed.manual.reason))
        or (feed.grind and is_bail(feed.grind.reason))
        or (ending and is_bail(ending.reason)) then
        closed=self:_close("lost",reason(feed.air and feed.air.failed,
            reason(feed.manual and feed.manual.reason,reason(feed.grind and feed.grind.reason,
            reason(ending and ending.reason,"bail")))));return result()
    end
    if feed.gap==true or feed.interrupted~=nil
        or (feed.grind and feed.grind.reason=="contact_unavailable")
        or (ending and ending.infrastructure==true) then
        closed=self:_close("interrupted",reason(feed.interrupted,
            feed.gap==true and "feed_gap" or reason(feed.grind and feed.grind.reason,
            reason(ending and ending.reason,"infrastructure"))))
        return result()
    end
    -- Validate a landed packet before crediting any activity in this feed.
    local landed
    if feed.air and feed.air.landed~=nil then
        landed=read_air(feed.air.landed)
        if not landed then
            closed=self:_close("interrupted","invalid_air");return result("invalid_air")
        end
    end
    local r=self._rules
    if self._manual and (feed.mode=="manual" or feed.mode=="nose_manual") then
        self._manual.seconds=math.min(r.manual_max_seconds,self._manual.seconds+h)
    end
    if self._grind and (feed.mode=="grinding" or feed.mode=="stalling") then
        local g=self._grind
        if g.kind=="stall" then
            local before=g.seconds
            g.seconds=math.min(r.stall_max_seconds,g.seconds+h)
            g.points=math.min(MAX,g.points+r.stall_rate*(g.seconds-before))
        else g.points=math.min(MAX,g.points+r[g.kind.."_rate"]*math.abs(feed.speed)*h) end
    end
    local function add(points,cats,name)
        local credit,why=self:_credit(sat(points),cats,name,feed.seconds)
        if credit then table.insert(credits,credit) else closed=self:_close("interrupted",why) end
    end
    local m=feed.manual
    if m then
        if m.event=="balancing" then
            if not self._manual then self._manual={kind=m.kind,seconds=0} end
        elseif self._manual then
            local manual=self._manual;self._manual=nil
            if manual_exits[m.reason] and manual.seconds>=r.manual_min_seconds then
                add(manual.seconds*(manual.kind=="nose_manual" and r.nose_manual_rate or r.manual_rate),
                    {"manual"},manual.kind=="nose_manual" and "Nose Manual" or "Manual")
            end
        end
    end
    local g=feed.grind
    if g then
        if g.event=="lock_on" then
            if not self._grind then
                self._grind={kind=g.grind,seconds=0,points=g.grind=="stall" and r.stall_base or r.grind_lock}
            end
        elseif self._grind and g.event=="grind_changed" then
            self._grind.kind=g.grind
            self._grind.points=math.min(MAX,self._grind.points+r.grind_change)
        elseif self._grind then
            local grind=self._grind;self._grind=nil
            add(grind.points,{grind.kind=="stall" and "stall" or "grind"},
                grind.kind=="stall" and "Stall" or "Grind")
        end
    end
    if feed.air then
        if feed.air.took_off==true then self._airborne=true end
        if feed.air.landed~=nil then
            self._airborne=false
            local credit,why=self:_air(landed,feed.seconds)
            if why then closed=self:_close("interrupted",why);return result(why) end
            if credit then table.insert(credits,credit) end
        end
    end
    if ending then
        closed=self:_close(ending.deliberate==true and "banked" or "interrupted",
            reason(ending.reason,ending.deliberate==true and "deliberate_stop" or "unclassified_stop"))
        return result()
    end
    local frozen=self._airborne or feed.mode=="airborne" or feed.landing_pending==true
        or self._manual~=nil or self._grind~=nil or feed.mode=="manual" or feed.mode=="nose_manual"
        or feed.mode=="grinding" or feed.mode=="stalling"
    if self._active and not frozen and #credits==0 then
        self._remaining=math.max(0,self._remaining-h)
        self._idle=math.abs(feed.speed)<r.idle_speed and self._idle+h or 0
        if self._remaining<=0 then closed=self:_close("banked","timeout")
        elseif self._idle>=r.idle_seconds then closed=self:_close("banked","idle") end
    elseif frozen then self._idle=0 end
    return result()
end
return table.freeze(Line)
