local Fixture=require("./two_cycle_fixture")
local Tests={}
function Tests.run()
    local n=0
    local function check(v,why)n+=1;assert(v,why)end
    local f=Fixture.new(check)    local before=f.count("lease")
    f.on_store=function(key)if key=="bmx_bike_cycle_1_stock100_v1" then error("constructed archive refusal",0)end end
    check(not f.owner:archive_return(),"archive100 storage failure refuses admission")
    f.on_store=nil
    check(not f.owner:archive_return(),"failed first archive cannot be retried")
    check(f.owner:successor(f.R,{qualification_only=true},f.second_state())==nil,"no successor after failed archive")
    check(f.count("lease")==before and not f.T.session_retired,"no new authority and original history owner remains")    return {cases=1,assertions=n,native_authority=false,constructed=true}
end
return Tests
