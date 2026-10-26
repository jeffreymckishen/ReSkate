-- Actual public Core mount and Source, constructed SDK-shaped services and a
-- fake Spawn. Captures the real reserve call; no Follow is published or driven.
local Core=require("./bike_runtime_core")
local Trial=require("./bike_runtime_core_provisional_follow_fixture")
local Services=require("./core_ride_staging_tests")
local Spawn=require("./bike_spawn")
local G=require("./bike_geometry")
local Tests={}
local function reserve(module)
    local f,s=Services.spawn_services()
    f.body=newproxy()
    local fake={phase="idle"}
    function fake:request() self.phase="armed";return true end
    function fake:update() if self.phase=="armed" then self.phase="spawned" end end
    function fake:status() return {phase=self.phase,cleanup_unknown=false,creation_unknown=false,body=false,
        visual_remove_requested=self.phase=="closed"} end
    function fake:handoff_follow() self.phase="follow_owned";return f.body,{serial="1"},nil end
    function fake:follow_visual() return true end
    function fake:stop() self.phase="closed" end
    local core=module.new(s,{qualification_only=true})
    local original=Spawn.new
    Spawn.new=function() return fake end
    local ok,bound=pcall(core.prepare_backend,core)
    Spawn.new=original
    assert(ok and bound==true,"constructed backend binds a single stand-in Spawn")
    assert(core:request_mount(0),"one public mount per copied Core module")
    local out
    for _=1,200 do
        f.now+=16;out=core:step(16)
        if #f.reserves>0 or out.stop_latched then break end
    end
    return f,out
end
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    for _,entry in {{Core,false},{Trial,true}} do
        cases+=1
        local f,out=reserve(entry[1])
        check(#f.reserves==1 and f.reserves[1].body==f.body,"actual Core reserve receives its exact handed-off body")
        local attachment=f.reserves[1].attachment
        local expected=entry[2] and vector.create(0,.05,-.05) or vector.create(-G.com[1],-G.com[2],-G.com[3])
        check(attachment.offset_from_com==expected,entry[2] and "trial uses the M1-derived P-COM offset" or "literal off preserves exact -COM offset")
        check(attachment.root_in_body[1]==0 and attachment.root_in_body[2]==0 and attachment.root_in_body[3]==0
            and attachment.root_in_body[4]==1,"root rotation stays identity")
        check(attachment.cleanup=="owned_body" and attachment.motion_policy=="callback_entry","cleanup and motion policies are unchanged")
        local fields=0 for _ in pairs(attachment) do fields+=1 end
        check(fields==4,"provisional offset adds no attachment authority or option")
        check(out.reserve_refused and not out.published_seen and not out.reserve_unknown and #f.releases==1,
            "known refusal releases only the handed-off body and never publishes")
        check(next(f.forbidden)==nil,"no force, contact, pulse or Follow publication is reached")
        check(out.last_source_step and out.last_source_step.input_ok==true,"reserve follows an actual selected Source capture frame")
        if entry[2] then
            local p=attachment.offset_from_com+vector.create(unpack(G.com))
            check(math.abs(p.x)<1e-6 and math.abs(p.y-.95)<1e-6 and math.abs(p.z+.10)<1e-6,
                "the offset reconstructs the provisional body-frame pelvis P")
        end
    end
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)
