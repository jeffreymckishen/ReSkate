local Fixture=require("./two_cycle_fixture")
local Tests={}
function Tests.run()
    local n=0
    local function check(v,why)n+=1;assert(v,why)end
    local f=Fixture.new(check)    f.prepare_504()
    f.on_store=function(key,row)if key=="bmx_bike_lifecycle_v1" and row.experimental_session==2 then error("constructed active marker refusal",0)end end
    local saves=#f.saves
    check(f.owner:successor(f.R,{qualification_only=true},f.second_state())==nil,"new active marker refusal blocks admission")
    check(f.T.session_retired==true,"old callbacks retired before successor marker callback")
    check(f.records.bmx_bike_cycle_1_stock100_v1 and f.records.bmx_bike_cycle_1_onfoot504_v1,"both previous terminal archives preserved")
    f.on_store=nil
    check(f.owner:successor(f.R,{qualification_only=true},f.second_state())==nil,"no replacement after marker failure")
    local before=#f.calls;f.core:step(16);f.core:unload()
    check(#f.calls==before and #f.saves>=saves,"late old methods cannot regain authority")    return {cases=1,assertions=n,native_authority=false,constructed=true}
end
return Tests
