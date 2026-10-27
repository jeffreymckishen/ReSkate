-- The runner wraps the current entry bytes in a private lexical fixture. The
-- scoring modules below are real; only lifecycle, storage and UI are constructed.
local Entry=require("./main_score_entry_fixture")
local Tests={}
local function copy(value)
    if type(value)~="table" then return value end
    local out={};for key,item in pairs(value) do out[key]=copy(item) end;return out
end
local function landed()
    local e={air_seconds=.9,sequence={{kind="bar",id=34,dir=-1,start=.1,finish=.55,hold=0}},
        landing={body_up=1,heading_cos=1,closing=4.32}}
    for _,name in ipairs({"took_off","landed","combo_landed","failed","canceled","bar_caught","tail_caught","movement_caught"}) do e[name]=false end
    for _,name in ipairs({"barspins","tailwhips","spin_half_turns","units","movements","front_flips","back_flips","barrel_rolls"}) do e[name]=0 end
    e.landed,e.barspins,e.units=true,1,1
    e.failure,e.fakie_takeoff,e.overflow="none",false,false
    e.spin_radians,e.flip_radians,e.roll_radians=0,0,0
    return e
end
local function fixture(options)
    options=options or {}
    local f={callbacks={},pages={},panels={},requires={},events={},queries={},rows={},n=0,generation=0,
        seconds=0,reads=0,writes={},steps=0,mounts=0,boards=0,stocks=0,stops=0,unloads=0,
        lifecycle={phase="idle",qualification_only=options.qualified==true,mount_enabled=false,
            bike_authority=false,cleanup_pending=false,cleanup_unknown=false,equipment={phase="idle"}}}
    function f:land()
        if self.generation==0 then self.generation=1 end
        self.n+=1;self.seconds+=.1
        table.insert(self.rows,{n=self.n,seconds=self.seconds,h=.1,speed=1,mode="rolling",
            landing_pending=false,events=landed()})
    end
    function f:finish(reason)
        if self.generation==0 then return end
        self.n+=1;table.insert(self.rows,{n=self.n,control="ended",reason=reason})
    end
    function f:new_generation()
        self.generation+=1;self.n=0;self.rows={};self.seconds=0
    end
    local bike={}
    function bike:status() return copy(f.lifecycle) end
    function bike:step()
        f.steps+=1;table.insert(f.events,"step");return self:status()
    end
    function bike:score_feed(after_n)
        table.insert(f.events,"feed");table.insert(f.queries,after_n)
        if after_n==0 and f.change_on_zero then
            f.generation+=1;f.change_on_zero=false
        end
        local valid=type(after_n)=="number" and after_n>=0 and after_n%1==0 and after_n<=f.n
        local log={generation=f.generation,n=f.n,rows={},gap=not valid}
        if not valid then return log end
        if f.rows[1] and after_n<f.rows[1].n-1 then log.gap=true end
        for _,row in ipairs(f.rows) do if row.n>after_n then table.insert(log.rows,copy(row)) end end
        return log
    end
    function bike:request_mount()
        f.mounts+=1
        if not f.lifecycle.qualification_only then return false,"Native bike lifecycle qualification unavailable" end
        return true
    end
    function bike:request_stock_toggle() f.stocks+=1;return true end
    function bike:request_board() f.boards+=1;return true end
    function bike:request_stop(reason) f.stops+=1;f:finish(reason);return true end
    function bike:unload()
        table.insert(f.events,"unload")
        if f.unloads==0 then f:finish("unload") end
        f.unloads+=1;return self:status()
    end
    local api={storage={},menu={}}
    function api.storage.get(key)
        assert(key=="bmx_score_v1","scoring reads only its own record")
        f.reads+=1;table.insert(f.events,"read");return copy(options.record)
    end
    function api.storage.set(key,value)
        assert(key=="bmx_score_v1","scoring writes only its own record")
        table.insert(f.events,"write");table.insert(f.writes,copy(value))
    end
    function api.on(event,fn)
        assert(not f.callbacks[event],"one callback per event");f.callbacks[event]=fn
    end
    function api.menu.page(title,fn) table.insert(f.pages,{title=title,build=fn}) end
    function api.menu.panel(title,fn) table.insert(f.panels,{title=title,build=fn}) end
    local function load(name)
        table.insert(f.requires,name);table.insert(f.events,"require")
        if name=="./bike_runtime" then return {new=function() return bike end} end
        if name==options.fail_module then error("constructed module load refusal") end
        return require(name)
    end
    Entry(api,load)
    local function ui()
        local u={values={}}
        function u:info(label,value) self.values[label]=value end
        function u:warn() end
        function u:note() end
        function u:button(id) return id==f.action end
        function u:tabs(_,_,selected) return selected end
        return u
    end
    function f:page(action)
        self.action=action;local u=ui();self.pages[1].build(u);self.action=nil;return u.values
    end
    function f:panel()
        local u=ui();self.panels[1].build(u);return u.values
    end
    function f:tick(dt)
        self.events={};local before=#self.requires
        self.callbacks.tick(dt or 16)
        return #self.requires-before
    end
    function f:ready()
        for _=1,40 do if self.reads>0 then return end;self:tick() end
        error("entry did not construct scoring within bounded idle ticks")
    end
    function f:draw()
        local d={calls=0}
        function d:size() return {x=1920,y=1080} end
        function d:text() self.calls+=1 end
        function d:line() self.calls+=1 end
        function d:rect() self.calls+=1 end
        self.callbacks.draw(d);return d.calls
    end
    return f
end
function Tests.run(progress)
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,body)
        cases+=1;local ok,why=pcall(body)
        if not ok then error(name..": "..tostring(why),0) end
        if type(progress)=="function" then progress(cases,assertions) end
    end
    case("entry registers one page and one read-only stats panel",function()
        local f=fixture()
        check(#f.pages==1 and f.pages[1].title=="BMX Lua migration" and #f.panels==1
            and f.panels[1].title=="BMX local scores","separate page and stats card")
        check(type(f.callbacks.tick)=="function" and type(f.callbacks.draw)=="function"
            and type(f.callbacks.unload)=="function","all lifecycle/display bindings")
        f:page();f:panel();check(f:draw()==0,"cold draw is inert")
        check(#f.requires==1 and f.reads==0 and #f.writes==0,"render callbacks do not bootstrap")
        f.events={};f.callbacks.unload()
        check(f.events[1]=="unload" and #f.queries==0 and f.reads==0 and #f.writes==0,"cold unload only cleans lifecycle")
    end)
    case("idle staging is cleanup-first and construction has its own tick",function()
        local f=fixture();local ticks=0
        repeat
            local reads=f.reads;local added=f:tick();ticks+=1
            check(f.events[1]=="step" and added<=1,"cleanup precedes at most one entry import")
            if f.reads>reads then check(added==0 and #f.queries==0,"constructor tick imports and scores nothing") end
            local loaded,stored=#f.requires,f.reads
            f:draw();f:panel()
            check(#f.requires==loaded and f.reads==stored and #f.writes==0,"render does not load/read/write storage")
            check(ticks<=40,"bounded idle preparation")
        until f.reads>0
        check(f.reads==1 and #f.writes==0,"one constructor storage read")
        f:tick();check(f.events[1]=="step" and f.events[2]=="feed" and f.queries[1]==0,"ready scoring runs with Observe off")
    end)
    case("startup work suppresses imports construction and scoring",function()
        local f=fixture();f:tick();f:tick()
        f.lifecycle.startup={work_this_tick=true};local loaded=#f.requires
        for _=1,4 do check(f:tick()==0 and f.events[1]=="step","startup keeps lifecycle first") end
        check(#f.requires==loaded and f.reads==0 and #f.queries==0,"startup does not advance cold scoring")
        f.lifecycle.startup=nil;f:ready();f:land()
        f.lifecycle.startup={work_this_tick=true};local queries=#f.queries
        f:tick();check(#f.queries==queries,"warm startup also leaves scoring work to a later tick")
        f.lifecycle.startup=nil;f:tick()
        check(f:panel()["Best single air"]=="240","retained first landing drains after startup")
    end)
    case("cleanup and board return keep priority over idle compilation",function()
        local f=fixture({qualified=true})
        f.lifecycle.phase="stopping";f.lifecycle.cleanup_pending=true
        for _=1,3 do check(f:tick()==0,"cleanup tick does not compile scoring") end
        f.lifecycle.phase="idle";f.lifecycle.cleanup_pending=false;f.lifecycle.board_return={pending=true}
        check(f:tick()==0,"board return does not share cold work")
        f:page("bike_mount0");check(f.mounts==0,"qualified mount cannot produce a row before readiness")
        f:page("equipment0");f:page("bike_board0");f:page("bike_stop")
        check(f.stocks==1 and f.boards==1 and f.stops==1,"stock/board/stop are independent of score readiness")
        f.lifecycle.board_return=nil;f:ready();f:page("bike_mount0")
        check(f.mounts==1,"qualified mount can be requested after score construction")
    end)
    case("public mount retains its native-closed refusal",function()
        local f=fixture()
        local cold=f:page("bike_mount0")
        check(cold["Last mount click"]=="Native bike lifecycle qualification unavailable" and f.mounts==1,"cold public refusal unchanged")
        f:ready();local warm=f:page("bike_mount0")
        check(warm["Last mount click"]=="Native bike lifecycle qualification unavailable" and f.mounts==2,"ready scores cannot enable mounting")
    end)
    case("stop drains after lifecycle and banks completed credit once",function()
        local f=fixture();f:ready();f:land();f:tick()
        check(f:panel()["Best single air"]=="240" and #f.writes==0,"landing credit is memory-only")
        f:page("bike_stop")
        check(#f.writes==0,"menu request does not run scoring persistence")
        f.lifecycle.phase="stopping";f.lifecycle.cleanup_pending=true
        f:tick();local stats=f:panel()
        check(f.events[1]=="step" and f.events[2]=="feed" and f.events[3]=="write","cleanup precedes drain and bank")
        check(stats["Best line"]=="360" and stats["Total banked score"]=="360" and #f.writes==1,"deliberate stop banks once")
        f:tick();check(#f.writes==1 and f.queries[#f.queries]==2,"retained terminal is not replayed")
    end)
    case("unload drains its terminal without a synthetic physics row",function()
        local f=fixture();f:ready();f:land();f:tick();f.events={}
        f.callbacks.unload();local stats=f:panel()
        check(f.events[1]=="unload" and f.events[2]=="feed","unload produces terminal before read")
        check(stats["Total banked score"]=="360" and #f.writes==0,"interrupted completed credit remains in memory")
        f.callbacks.unload()
        check(f:panel()["Total banked score"]=="360" and #f.writes==0,"repeat unload cannot duplicate credit")
    end)
    case("a higher generation retries an invalid old cursor once",function()
        local f=fixture();f:ready();f:land();f:finish("dismount");f:tick()
        check(#f.writes==1 and f.writes[1].session_total==360,"first generation bank")
        f:new_generation();f:land();local before=#f.queries;f:tick()
        check(#f.queries==before+2 and f.queries[before+1]==2 and f.queries[before+2]==0,"old cursor header then one zero retry")
        f:finish("dismount");f:tick()
        check(#f.writes==2 and f.writes[2].session_total==720,"new generation first landing preserved")
    end)
    case("same-generation reads never replay from zero",function()
        local f=fixture();f:ready();f:land();f:tick();local before=#f.queries
        for _=1,3 do f:tick() end
        check(#f.queries==before+3,"one feed read per ordinary tick")
        check(f.queries[before+1]==1 and f.queries[before+2]==1 and f.queries[before+3]==1,"current cursor passed unchanged")
        check(f:panel()["Best single air"]=="240" and #f.writes==0,"empty repeat logs do not bank or duplicate")
    end)
    case("generation retry preserves a retained-buffer gap",function()
        local f=fixture();f:ready();f:land();f:finish("dismount");f:tick()
        f:new_generation();f.n=8;f:land();local before=#f.queries;f:tick()
        check(#f.queries==before+2 and f.queries[before+2]==0,"bounded generation retry")
        check(f:panel()["Total banked score"]=="360" and #f.writes==1,"gap cannot earn a partial new landing")
    end)
    case("a producer changing during retry interrupts without partial credit",function()
        local f=fixture();f:ready();f:land();f:tick()
        f:new_generation();f:land();f.change_on_zero=true;local before=#f.queries;f:tick()
        check(#f.queries==before+2,"generation disagreement does not retry again")
        check(f:panel()["Total banked score"]=="360" and #f.writes==0,"only old completed credit closes in memory")
    end)
    case("display callbacks cannot credit or persist score",function()
        local f=fixture();f:ready();f:land();f:finish("dismount");f:tick()
        local loaded,reads,queries,writes=#f.requires,f.reads,#f.queries,#f.writes
        check(f:draw()>0,"entry dispatches the actual score HUD")
        f:panel();f:draw();f:panel()
        check(#f.requires==loaded and f.reads==reads and #f.queries==queries and #f.writes==writes,"render only reads display state")
        f:tick(2000)
        check(f:panel()["Total banked score"]=="360" and #f.writes==writes,"wall time changes banner expiry only")
    end)
    case("a cold load refusal leaves cleanup and stock controls available",function()
        local f=fixture({qualified=true,fail_module="./motions"})
        for _=1,6 do f:tick() end
        local loaded=#f.requires;f:tick();f:page("bike_mount0")
        check(#f.requires==loaded and f.reads==0 and f.mounts==0,"failed preparation does not retry or permit qualified mounting")
        f:page("equipment0");f:page("bike_board0");f:page("bike_stop")
        check(f.stocks==1 and f.boards==1 and f.stops==1 and f.steps==7,"lifecycle and stock controls remain available")
        f.callbacks.unload();check(f.unloads==1 and #f.writes==0,"cleanup still runs on unload")
    end)
    return {cases=cases,assertions=assertions,native_actions=0}
end
return Tests
