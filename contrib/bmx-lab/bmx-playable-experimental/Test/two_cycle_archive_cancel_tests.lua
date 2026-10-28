local Fixture=require("./two_cycle_fixture")
local Tests={}
function Tests.run()
    local n=0
    local function check(v,why)n+=1;assert(v,why)end
    local f=Fixture.new(check)    f.on_store=function(key)if key=="bmx_bike_cycle_1_stock100_v1" then f.core:request_stop("reentrant old archive stop");f.owner:abort_preparation() end end
    check(not f.owner:archive_return(),"reentrant Stop invalidates the archive handoff")
    check(not f.owner:archive_return() and f.count("lease")==1,"old archive callbacks cannot regain second admission")    return {cases=1,assertions=n,native_authority=false,constructed=true}
end
return Tests
