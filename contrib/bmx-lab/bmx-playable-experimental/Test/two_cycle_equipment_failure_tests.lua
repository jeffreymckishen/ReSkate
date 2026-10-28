local Fixture=require("./two_cycle_fixture")
local T={}
function T.run()
    local n=0;local function check(v,why)n+=1;assert(v,why)end
    local f=Fixture.new(check)
    check(f.owner:archive_return(),"clean old100 terminal archived")
    check(f.core:request_stock_toggle(f.user),"new504 transaction starts once")
    f.bad_pulse=true
    f.ticks(200)
    local ok,why=f.owner:ready()
    check(not ok and why~="pending","real malformed/unresolved504 is a sticky failure, never endless pending")
    check(f.T.gear_unknown or f.T.gear_cancelled,"real Core latched the bad stock transaction")
    check(f.core:status().stock_toggle_blocked,"uncertain equipment still blocks authority")
    check(f.owner:successor(f.R,{qualification_only=true},f.second_state())==nil,"no new Core on failed504 proof")
    check(f.count("lease")==1,"failed target acquisition creates no replacement Source")
    return {cases=1,assertions=n,native_authority=false,constructed=true}
end
return T
