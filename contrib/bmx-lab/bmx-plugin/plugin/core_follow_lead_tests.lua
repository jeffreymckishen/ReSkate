-- Real public Core mount, Source and Spawn against constructed SDK services.
-- The runner flips only FOLLOW_LEAD_QUALIFIED in the private Core copy.
-- A known reserve refusal ends each attempt; no Follow or force is published.
local Core=require("./bike_runtime_core")
local Trial=require("./bike_runtime_core_follow_lead_fixture")
local Spawn=require("./bike_spawn")
local Fixture=require("./core_floor_spawn_fixture")
local G=require("./bike_geometry")
local Tests={}
local function equal(a,b)
    if typeof(a)~=typeof(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function fields(value) local n=0 for _ in pairs(value) do n+=1 end return n end
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local reports={}
    for _,entry in {{Core,false},{Trial,true}} do
        cases+=1
        local enabled=entry[2]
        local f=Fixture.new(entry[1],Spawn)
        local out=f.drive()
        check(#f.reserves==1 and f.reserves[1].body==f.body,"real Core reserves the exact body handed off by real Spawn")
        local attachment=f.reserves[1].attachment
        check(attachment.offset_from_com==vector.create(-G.com[1],-G.com[2],-G.com[3]),"lead does not change the COM-relative point")
        check(equal(attachment.root_in_body,{0,0,0,1}),"lead does not change the root rotation")
        check(attachment.cleanup=="owned_body" and attachment.motion_policy=="callback_entry" and attachment.lifetime==nil,
            "lead changes no cleanup, motion or lifetime policy")
        check(fields(attachment)==(enabled and 5 or 4),"the closed literal adds only the lead field")
        if enabled then
            check(type(attachment.lead)=="table" and getmetatable(attachment.lead)==nil and fields(attachment.lead)==2,
                "the trial has only the two declared lead options")
            check(attachment.lead.steps==2 and attachment.lead.angular==true,"the private trial requests two measured steps including angular point motion")
        else
            check(attachment.lead==nil,"the default sends no lead field to older or current SDKs")
        end
        check(f.rays==0 and f.proxy.world.raycast==nil,"the independent floor literal remains off")
        check(f.calls["world.physics.create"]==1 and f.calls["world.physics.read"]==1
            and f.calls["entities.bounds"]==8 and f.calls["entities.set"]==16 and f.calls["entities.status"]==8,
            "both settings retain the actual asset, visual and measured-body cadence")
        check(out.last_source_step and out.last_source_step.input_ok==true,"reserve follows the actual selected Source capture frame")
        check(out.reserve_refused and not out.published_seen and not out.reserve_unknown
            and #f.releases==1 and f.releases[1]==f.body,"the known refusal releases only the handed-off body")
        check(next(f.forbidden)==nil,"no force, contact, input pulse or Follow publication is reached")
        local done=f.drain()
        check(done.source and done.source.phase=="complete" and not done.cleanup_unknown
            and #f.reserves==1 and #f.releases==1,"cleanup finishes without another reserve or release")
        local plain_attachment={}
        for key,value in pairs(attachment) do if key~="lead" then plain_attachment[key]=value end end
        table.insert(reports,{attachment=plain_attachment,definition=f.definition,calls=f.calls,order=f.order,
            at_refusal=out,after_cleanup=done})
    end
    cases+=1
    check(equal(reports[1],reports[2]),"lead changes only the reserve option, not the constructed lifecycle, placement or call reports")
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)