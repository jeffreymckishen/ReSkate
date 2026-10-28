local Fixture=require("./two_cycle_fixture")
local Tests={}
function Tests.run()
    local n=0
    local function check(v,why)n+=1;assert(v,why)end
    local f=Fixture.new(check)    f.prepare_504()
    local before=f.count("lease")
    f.on_store=function(key)if key=="bmx_bike_cycle_1_onfoot504_v1" then error("constructed second archive refusal",0)end end
    check(f.owner:successor(f.R,{qualification_only=true},f.second_state())==nil,"post504 archive failure refuses successor")
    f.on_store=nil
    check(f.owner:successor(f.R,{qualification_only=true},f.second_state())==nil,"failed second archive is permanently spent")
    check(f.records.bmx_bike_cycle_1_stock100_v1~=nil and not f.T.session_retired,"stock100 history remains intact before retirement")
    check(f.count("lease")==before,"no replacement Source after failed archive")    return {cases=1,assertions=n,native_authority=false,constructed=true}
end
return Tests
