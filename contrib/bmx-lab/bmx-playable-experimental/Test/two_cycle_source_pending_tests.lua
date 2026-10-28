local Fixture=require("./two_cycle_fixture")
local T={}
function T.run()
    local n=0;local function check(v,why)n+=1;assert(v,why)end
    local f=Fixture.new(check,{pending_source=true})
    check(not f.owner:archive_return(),"actual Source debt cannot qualify a previous clean cycle")
    check(f.owner:successor(f.R,{qualification_only=true},{})==nil,"no successor after missing native-shaped Source ACK")
    check(f.handle~=nil and f.count("lease_acknowledge_capture")==0 and f.count("lease_acknowledge")==0,
        "Source cleanup remains retained and truthful")
    check(f.count("lease")==1,"no second Source may overlap retained first lease")
    return {cases=1,assertions=n,native_authority=false,constructed=true}
end
return T
