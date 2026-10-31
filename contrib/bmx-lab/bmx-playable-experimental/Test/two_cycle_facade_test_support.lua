local Wrapper=require("./two_cycle_facade_fixture")
local M={}
function M.new(check)
    local f={now=1000,state=504,events={},core_count=0,archives=0,stock_requests=0,done504=false,aborted=false}
    local function event(s) f.events[#f.events+1]=s end
    local Admission={}
    function Admission.snapshot(t) return {phase=t.phase,stock_toggle_blocked=false} end
    function Admission.ready(o) return o and o.grounded and o.upright_stock end
    function Admission.matches(a,b) return a.state==b.state and a.level==b.level and a.wipeouts==b.wipeouts end
    function Admission.bind(t)
        return {marker_clear=function()return true end,persist=function()event("marker");f.marker_limit=t.experimental_attempt_limit;f.marker_session=t.experimental_session;f.marker_arm=t.arm_at;f.marker_admitted=t.startup_admitted_at;return true end,
            available=function()return true end,clock=function()f.now+=16;t.now=f.now;return f.now end,
            facts=function()return {state=f.state,grounded=true,upright_stock=true,level="constructed",wipeouts=0}end}
    end
    local function core(t)
        f.core_count+=1;local object={}
        function object:status()return {phase=t.phase,stock_toggle_blocked=false,bike_cleanup_complete=true,cleanup_unknown=false}end
        function object:prepare_backend()event("backend");return true end
        function object:request_mount(slot,actual)
            check(actual==t,"actual facade hands off its OWN shared state")
            event("mount"..tostring(f.core_count));t.phase="following";return true
        end
        function object:request_stock_toggle()f.stock_requests+=1;f.gear_admission_at=t.gear_admission_at;event("stock504");t.phase="stock_switching";return true end
        function object:request_stop()event("stop");return not t.retired end
        function object:step()return self:status()end
        function object:unload()event("unload");t.unloaded=true;return self:status()end
        return object
    end
    local Core={}
    function Core.new(_,_,t)return core(t)end
    function Core.experimental_two_cycle_owner()
        local owner={}
        function owner:first(_,_,t)f.old=t;return core(t)end
        function owner:can_archive_return()return not f.aborted end
        function owner:archive_return()
            f.archives+=1;event("archive100")
            if f.on_archive then f.on_archive()end
            return not f.aborted,f.aborted and "cancelled" or nil
        end
        function owner:ready()if f.on_ready then return f.on_ready()end;if f.aborted then return false,"cancelled"end;return f.done504,f.done504 and 2 or "pending"end
        function owner:abort_preparation()f.aborted=true;event("abort")end
        function owner:successor(_,_,t)
            event("archive504");f.old.retired=true;event("retire")
            if f.on_marker then f.on_marker()end
            event("newmarker")
            if f.aborted then return nil,"cancelled"end
            return core(t)
        end
        return owner
    end
    local Runtime=Wrapper(function(name)
        if name=="./bike_admission"then return Admission end
        if name=="./bike_runtime_core"then return Core end
        return {}
    end)
    f.Runtime=Runtime
    f.manager=assert(Runtime.new_experimental_two_cycle({}, {qualification_only=true}))
    check(Runtime.new_experimental_two_cycle({}, {qualification_only=true})==nil,"second manager constructor refuses before callbacks")
    check(f.manager:request_mount(0),"first facade intent admitted")
    for _=1,80 do f.manager:step(16)end
    check(f.core_count==1,"first facade startup created one Core")
    f.old.phase="done";f.old.bike_cleanup_complete=true;f.old.stop_latched=true;f.state=100
    return f
end
return M
