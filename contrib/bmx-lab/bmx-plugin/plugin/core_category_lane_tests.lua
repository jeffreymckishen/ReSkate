-- New mod suite: existing Host-pinned persistence counts remain unchanged.
-- The inert factory binds only constructed callbacks, never a Core owner.
local Core=require("./bike_runtime_core")
local Identity=require("./lease_identity")
local Tests={}
local A={require_contact=true,exclude_local_actor=true}
local B={require_contact=true,query_preset="camera",require_named_actor_categories_absent=true}
local function changed(source,key,value)
    local out=table.clone(source);out[key]=value;return out
end
local function fixture(flag)
    local f={serial="9007199254740993",epoch=newproxy(),rays={},queries=0,guards=0,afters=0,
        guard_ok=true,current=true,trace={}}
    local function stop(why) f.stopped=true;f.reason=f.reason or why end
    f.call=Core.probe_batch_adapter(Identity,
        function(epoch)
            f.guards+=1;table.insert(f.trace,"guard")
            if f.stopped or not f.guard_ok or epoch~=f.epoch then stop("current Core Source/Follow/body/epoch force guard refused");return false end
            return true
        end,
        function() table.insert(f.trace,"serial");return f.serial end,
        function(epoch,rays,options)
            f.queries+=1;table.insert(f.trace,"invoke");f.last={epoch=epoch,rays=rays,options=options}
            return table.pack(true,f.queries)
        end,
        function(epoch) f.afters+=1;table.insert(f.trace,"after");return f.current and not f.stopped and epoch==f.epoch end,
        stop,flag)
    function f:query(options) return self.call(self.epoch,self.rays,options) end
    return f
end
function Tests.run()
    local cases,assertions=0,0
    local function check(v,why) assertions+=1;assert(v,why) end
    local function case() cases+=1 end
    case() do
        local f=fixture(false)
        check(f.guards==0 and f.queries==0 and Core.probe_batches_per_serial==4,"construction stays inert with the unchanged fixed budget")
        check(f:query(A)==1 and f.last.options==A and f.last.epoch==f.epoch and f.last.rays==f.rays,"shape A preserves the exact arguments")
        check(table.concat(f.trace,",")=="guard,serial,invoke,after","the option gate preserves every per-call check")
    end
    case() do
        local f=fixture(false)
        check(f:query(B)==nil and f.guards==0 and f.queries==0 and f.afters==0 and not f.stopped,"the false literal refuses B before callbacks")
        for batch=1,4 do check(f:query(A)==batch,"a refused category request does not spend shape A's allowance") end
        check(f:query(A)==nil and f.queries==4 and f.reason=="fifth contact batch for one native serial refused","the original fifth-call stop is unchanged")
    end
    case() do
        local f=fixture(true)
        for batch,options in ipairs({A,B,A,B}) do check(f:query(options)==batch,"the two exact shapes share one allowance") end
        check(f:query(B)==nil and f.queries==4 and f.guards==5 and f.afters==4
            and f.reason=="fifth contact batch for one native serial refused","category calls cannot obtain a second budget")
    end
    for _,flag in ipairs({1,"true",{},false}) do case() do
        local f=fixture(flag)
        check(f:query(B)==nil and f.guards==0 and f.queries==0,"only an actual true qualification accepts B")
        check(f:query(A)==1,"truthy or false qualification never changes A")
    end end
    for _,bad in ipairs({
        setmetatable({}, {__index=A}),
        setmetatable(table.clone(A), {__metatable=false}),
        changed(B,"exclude_local_actor",false),
        changed(B,"exclude_local_actor",true),
        changed(B,"query_preset","all"),
        changed(B,"query_preset","terrain"),
        changed(B,"include_shape_categories",false),
        changed(B,"include_hit_owner",false),
        changed(B,"exclude_bodies",{}),
        changed(B,"require_named_actor_categories_absent",false),
        changed(A,"require_contact",1),
        changed(A,"query_preset","camera"),
        changed(A,"extra",false),
        false,
        {query_preset="camera",require_named_actor_categories_absent=true},
    }) do case() do
        local f=fixture(true)
        check(f:query(bad)==nil and f.guards==0 and f.queries==0 and f.afters==0 and not f.stopped,
            "metatables, diagnostics, mixtures and every extra/missing key are refused before callbacks")
        check(f:query(A)==1,"a malformed shape neither spends nor refreshes the allowance")
    end end
    case() do
        local f=fixture(true);f:query(A);f:query(B)
        check(f:query(changed(B,"include_shape_categories",true))==nil and f.queries==2 and f.guards==2 and f.afters==2,
            "options are checked again after a partial spend")
        check(f:query(A)==3 and f:query(B)==4,"the remaining allowance is shared after that refusal")
        check(f:query(A)==nil and f.queries==4 and f.reason=="fifth contact batch for one native serial refused","the invalid attempt cannot reset the count")
    end
    for _,failure in ipairs({"pre","post"}) do case() do
        local f=fixture(true);f:query(A);f:query(B)
        if failure=="pre" then f.guard_ok=false else f.current=false end
        local result=f:query(B)
        local expected_result=failure=="post" and 3 or nil
        check(f.stopped and f.queries==(failure=="pre" and 2 or 3) and result==expected_result
            and f.reason==(failure=="pre" and "current Core Source/Follow/body/epoch force guard refused" or "Core guard changed during contact query"),
            "shape B still stops on the "..failure.." owner check")
        local before=f.queries
        check(f:query(A)==nil and f.queries==before,"neither shape can resume the stopped owner")
    end end
    return {cases=cases,assertions=assertions,native_actions=0}
end
return Tests
