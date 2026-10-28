local Fixture=require("./two_cycle_fixture")
local Tests={}
function Tests.run()
    local n=0
    local function check(v,why)n+=1;assert(v,why)end
    local f=Fixture.new(check)    f.prepare_504()
    f.on_store=function(key,row)if key=="bmx_bike_lifecycle_v1" and row.experimental_session==2 then f.owner:abort_preparation() end end
    check(f.owner:successor(f.R,{qualification_only=true},f.second_state())==nil,"cancel inside new-marker callback prevents publication of fresh owner")
    check(f.T.session_retired and f.count("lease")==1,"old owner remains inert; no new Source acquisition")
    check(f.owner:successor(f.R,{qualification_only=true},f.second_state())==nil,"cancel is irreversible despite successful storage callback")    return {cases=1,assertions=n,native_authority=false,constructed=true}
end
return Tests
