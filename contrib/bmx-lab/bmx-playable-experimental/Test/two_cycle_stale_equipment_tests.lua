local Fixture=require("./two_cycle_fixture")
local Tests={}
function Tests.run()
    local n=0
    local function check(v,why)n+=1;assert(v,why)end
    local f=Fixture.new(check)    check(f.owner:archive_return(),"clean stock100 history is archived once")
    f.stock=504 -- A sampled state change alone is not a NEW SDK transaction.
    check(not f.owner:ready(),"old100 ACK plus sampled504 cannot prove newer target504 transaction")
    check(f.owner:successor(f.R,{qualification_only=true},f.second_state())==nil,"stale equipment proof cannot admit new Core")
    check(f.count("lease")==1 and not f.T.session_retired,"no allocation or old-owner retirement on stale proof")    return {cases=1,assertions=n,native_authority=false,constructed=true}
end
return Tests
