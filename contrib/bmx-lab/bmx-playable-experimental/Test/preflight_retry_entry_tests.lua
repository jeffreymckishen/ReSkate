-- Pure source proposal tests. Root must run with the exact pinned Runtime and
-- Survey beside this file and the proposed Entry. No native API or HID exists.
local Entry=require("./bmx_playable_entry")
local Survey=require("./ride_r1_record")
local Runtime=require("./bike_runtime")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,fn) cases+=1;local ok,why=pcall(fn);assert(ok,name..": "..tostring(why)) end
    local function copy(v) if type(v)~="table" then return v end;local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out end
    local function idle()
        -- This fixture starts from the ACTUAL pinned facade, not invented fields.
        return Runtime.new({}, {qualification_only=true}):status()
    end
    local function fixture()
        local f={now=0,position=vector.create(0,.5,0),heading=0,slope=0,rough=true,overlay=false,
            focused=true,stock=504,keys={},latest=idle(),news=0,mounts=0,stops=0,stock_calls=0,
            prepares=0,probes=0,floor_probes=0,unloads=0}
        local R={time={},input={},menu={},skater={},storage={},world={physics={}}}
        function R.time.now() return f.now end
        function R.input.focus()return{focused=f.focused,gameplay=true,interface_open=f.overlay}end
        function R.menu.game()return{open=false}end
        function R.skater.get()return{position=f.position,heading=f.heading}end
        function R.skater.telemetry()return{watch={state=f.stock}}end
        function R.storage.keys()if f.on_keys then return f.on_keys() end;return f.keys end
        function R.world.physics.prepare()
            f.prepares+=1;if f.on_prepare then return f.on_prepare() end;return true
        end
        function R.world.probe(from,to)
            f.probes+=1
            if f.on_probe then local value=f.on_probe(from,to);if value then return value end end
            if from.y-to.y>1 then
                f.floor_probes+=1
                local y=math.tan(math.rad(f.slope))*from.x
                if f.rough and from.x>0 then y+=.405 end
                if f.change_floor and f.floor_probes>180 then y+=1 end
                return{status="hit",position=vector.create(from.x,y,from.z)}
            end
            return{status=f.obstacle or "clear"}
        end
        local owner={}
        function owner:status()
            if f.on_status then f.on_status() end
            return copy(f.latest)
        end
        function owner:step()if f.on_step then f.on_step() end;return copy(f.latest)end
        function owner:request_mount(slot)
            f.mounts+=1;check(slot==0,"same selected slot")
            if f.on_mount then return f.on_mount() end
            f.latest.used=true;f.latest.phase="following";f.latest.bike_authority=true
            f.latest.stock_toggle_blocked=true
            return true
        end
        function owner:request_stop()
            f.stops+=1;f.latest.phase="done";f.latest.used=true;return true
        end
        function owner:request_stock_toggle()f.stock_calls+=1;return false,"not exercised"end
        function owner:unload()f.unloads+=1;f.latest.unloaded=true;return copy(f.latest)end
        local Fake={}
        function Fake.new(services,options)
            f.news+=1;check(services==R and options.qualification_only==true,"private inert construction")
            return owner
        end
        Fake.new_experimental_two_cycle=Fake.new
        f.entry=Entry.new(R,Fake,Survey,{admitted=true,slot=0,experimental_two_cycle=true})
        function f.tick(n)for _=1,n or 1 do f.now+=16;f.entry:step(16)end end
        function f.await()
            for _=1,200 do
                f.tick();local s=f.entry:status()
                if s.phase=="preflight_refused" or s.phase=="blocked" or s.mount_requested then return s end
            end
            error("bounded survey did not reach terminal preflight or mount")
        end
        function f.refuse()
            check(f.entry:mount(),"first explicit intent")
            local s=f.await();check(s.phase=="preflight_refused","geometric refusal is recoverable")
            return s
        end
        return f
    end
    case("01 actual Runtime idle has every required proof field",function()
        local s=idle()
        check(s.schema==1 and s.kind=="bike-lifecycle-v1" and s.phase=="idle","actual facade identity")
        check(s.qualification_only==true and s.mount_enabled==false and s.used==false,"actual idle flags")
        check(s.bike_authority==false and s.cleanup_pending==false and s.cleanup_unknown==false,"actual no authority/duty")
        check(s.stock_toggle_blocked==false and s.unloaded==false,"actual availability")
        check(s.equipment.phase=="idle" and s.equipment.retained==false and s.equipment.unloaded==false,"actual equipment inert")
        check(s.startup.pending==false and s.startup.loaded==0 and s.startup.core_ready==false and s.startup.backend_ready==false,"actual startup absent")
        check(s.stop_latched==nil,"no fake-only stop_latched requirement")
    end)
    case("02 rough terrain retains charged attempt and no native call",function()
        local f=fixture();local s=f.refuse()
        check(s.attempts_used==1 and s.mount_intent_used and not s.mount_requested,"same reserved intent remains charged")
        check(f.news==1 and f.mounts==0 and f.stops==0 and f.stock_calls==0,"no owner admission/stop/equipment")
        check(s.terrain_refusal_count==1 and s.terrain_refusals[1].residual_mm>40,"numeric failure retained")
        check(s.detail:find("Move to a flat clear area",1,true)~=nil,"visible actionable retry")
    end)
    case("03 move then explicit retry performs full new survey on same owner",function()
        local f=fixture();f.refuse();local old_probes=f.probes
        f.position=vector.create(20,.5,0);f.rough=false
        check(f.entry:mount(),"explicit preflight retry")
        local s=f.await()
        check(f.news==1 and f.mounts==1 and f.prepares==2,"same owner, one native request, original prepare repeated")
        check(f.probes-old_probes>=1260,"full original floor and obstacle survey repeated")
        check(s.attempts_used==1 and s.terrain_refusal_count==1,"charged attempt/history never reset")
        check(not f.entry:mount() and f.mounts==1,"native request permanently closes preflight retry")
    end)
    case("04 repeated terrain refusals preserve immutable ordered history",function()
        local f=fixture();f.refuse()
        for n=2,3 do check(f.entry:mount(),"explicit terrain retry");local s=f.await();check(s.terrain_refusal_count==n,"history appends")end
        local s=f.entry:status()
        check(table.isfrozen(s.terrain_refusals) and table.isfrozen(s.terrain_refusals[1]),"history cannot mutate authority")
        check(s.terrain_refusals[1].index==1 and s.terrain_refusals[3].at>s.terrain_refusals[1].at,"prior reason/time retained")
        check(s.attempts_used==1 and f.news==1 and f.mounts==0 and f.stops==0,"no native rearm/reset")
    end)
    case("05 original displayed slope rule is still enforced",function()
        local f=fixture();f.rough=false;f.slope=.06
        f.refuse();check(f.mounts==0,"0.06 display still refuses")
        f.slope=.0525;check(f.entry:mount(),"new survey after turn/move")
        check(f.await().mount_requested and f.mounts==1,"historical0.05display threshold unchanged")
    end)
    case("06 survey geometric slope refusal can retry without relaxing limit",function()
        local f=fixture();f.rough=false;f.slope=.8
        f.refuse();check(f.mounts==0,"generic slope guard still refuses")
        f.slope=0;check(f.entry:mount(),"fresh flat survey intent")
        check(f.await().mount_requested,"only new passing terrain reaches owner")
    end)
    case("07 obstruction and unavailable rays stay sticky",function()
        for _,kind in ipairs({"hit","unavailable"})do
            local f=fixture();f.rough=false;f.obstacle=kind
            check(f.entry:mount(),"first intent");local s=f.await()
            check(s.phase=="blocked" and s.terrain_refusal_count==0 and not f.entry:mount(),"hit/unknown is not geometric retry")
            check(f.mounts==0 and f.stops==1,"original stop path")
        end
    end)
    case("08 missing floor ray stays sticky",function()
        local f=fixture();f.on_probe=function()return{status="unavailable"}end
        check(f.entry:mount(),"first intent");local s=f.await()
        check(s.phase=="blocked" and not f.entry:mount() and s.terrain_refusal_count==0,"missing floor never becomes terrain retry")
    end)
    case("09 changing floor stays sticky",function()
        local f=fixture();f.rough=false;f.change_floor=true
        check(f.entry:mount(),"first intent");local s=f.await()
        check(s.phase=="blocked" and not f.entry:mount() and f.mounts==0,"moving floor check unchanged")
    end)
    case("10 unknown preparation and original timeout stay sticky",function()
        for _,answer in ipairs({function()return false,"unknown"end,function()return true,"extra"end,
            function()error("prepare failed")end,function()return false,"waiting for a fresh qualified 60 Hz physics step"end})do
            local f=fixture();f.on_prepare=answer
            check(f.entry:mount(),"first intent")
            f.tick(200);check(f.entry:status().phase=="blocked" and not f.entry:mount() and f.mounts==0,"no preflight retry for prepare uncertainty/timeout")
            check(f.prepares<=20,"original20call bound")
        end
    end)
    case("11 freshness movement guard stays sticky after passing survey",function()
        local f=fixture();f.rough=false;f.overlay=true
        check(f.entry:mount(),"first intent");f.tick(100)
        check(f.entry:status().phase=="awaiting_mount","survey passes while overlay delays mount")
        f.position=vector.create(.3,.5,0);f.overlay=false;f.tick()
        check(f.entry:status().phase=="blocked" and not f.entry:mount() and f.mounts==0,"no stale/moved survey retry")
    end)
    case("12 malformed or non-inert proof never gains terrain retry",function()
        local mutations={function(s)s.used=nil end,function(s)s.used=true end,function(s)s.cleanup_unknown=true end,
            function(s)s.startup.loaded=1 end,function(s)s.startup.pending=true end,function(s)s.equipment.retained=true end,
            function(s)s.bike_authority=nil end,function(s)s.qualification_only=nil end}
        for _,mutate in ipairs(mutations)do
            local f=fixture();mutate(f.latest)
            check(f.entry:mount(),"first intent");local s=f.await()
            check(s.phase=="blocked" and s.terrain_refusal_count==0 and not f.entry:mount(),"exact positive proof required")
        end
    end)
    case("13 new storage or changed owner between refusal and retry stays sticky",function()
        for _,change in ipairs({function(f)f.keys={"retained_lifecycle"}end,
            function(f)f.latest.startup.pending=true end,function(f)f.on_status=function()error("status unavailable")end end})do
            local f=fixture();f.refuse();local prepares=f.prepares;change(f)
            check(not f.entry:mount() and f.entry:status().phase=="blocked","retry rechecks current owner/storage")
            check(f.prepares==prepares and f.mounts==0 and f.entry:status().terrain_refusal_count==1,"no work/history erasure after proof loss")
        end
    end)
    case("14 refused or throwing native mount is permanently consumed",function()
        for _,answer in ipairs({function()return false,"refused"end,function()error("uncertain mount")end})do
            local f=fixture();f.refuse();f.rough=false;f.on_mount=answer
            check(f.entry:mount(),"terrain retry only");local s=f.await()
            check(s.phase=="blocked" and s.mount_requested and not f.entry:mount() and f.mounts==1,"never retry after owner callback")
            check(s.attempts_used==1 and s.terrain_refusal_count==1,"native budget/history unchanged")
        end
    end)
    case("15 cancellation in fresh proof cannot race into retry",function()
        local f=fixture();f.refuse();f.on_status=function()f.on_status=nil;f.entry:cancel()end
        check(not f.entry:mount(),"reentrant cancellation wins")
        check(f.entry:status().cancelled and f.mounts==0 and f.stops==1,"one stop, no native request")
    end)
    case("16 bounded terrain history never drops earlier refusals",function()
        local f=fixture();f.refuse()
        for n=2,8 do check(f.entry:mount(),"explicit bounded retry");local s=f.await();check(s.terrain_refusal_count==n,"all refusals retained")end
        local s=f.entry:status()
        check(s.phase=="blocked" and not f.entry:mount() and #s.terrain_refusals==8,"eighth refusal sticky; no eviction")
        check(s.terrain_refusals[1].index==1 and f.news==1 and f.mounts==0,"first failure and owner preserved")
    end)
    case("17 second-cycle or previously used owner cannot regain terrain retry",function()
        local f=fixture();f.latest.used=true;f.latest.phase="done";f.latest.bike_cleanup_complete=true
        check(f.entry:mount(),"first Entry intent does not itself grant proof")
        local s=f.await();check(s.phase=="blocked" and not f.entry:mount(),"used/done owner never returns to preflight path")
    end)
    case("18 clock reversal and cancellation remain sticky",function()
        local f=fixture();f.refuse();f.now=-1
        check(not f.entry:mount() and f.entry:status().phase=="blocked" and f.mounts==0,"monotonic clock never reset")
        local g=fixture();g.refuse();g.entry:cancel()
        check(not g.entry:mount() and g.entry:status().terrain_refusal_count==1,"cancel leaves retained history and no rearm")
    end)
    case("19 resource proof callback cancellation during refusal stays sticky",function()
        local f=fixture();f.on_status=function()f.on_status=nil;f.entry:cancel()end
        check(f.entry:mount(),"first intent");f.tick(100)
        check(f.entry:status().cancelled and f.mounts==0 and f.stops==1,"proof callback cannot overwrite cancel or duplicate stop")
    end)
    return{cases=cases,assertions=assertions}
end
return Tests