-- Materialize this exact suite as json_encoding_tests.lua in its own Test-only
-- unit so the EXISTING runner passes its actual SDK-compatible JSON helper.
local Fixture=require("./two_cycle_fixture")
local T={}
function T.run(helper)
    local n=0;local function check(v,why)n+=1;assert(v,why)end
    check(type(helper)=="table" and type(helper.json_encode)=="function","actual runner JSON helper required")
    local f=Fixture.new(check)
    f.R.json.encode=helper.json_encode
    for i=1,900 do f.T.counts[string.rep("bounded_count_",6)..tostring(i)]=i end
    local before=#f.saves
    check(not f.owner:archive_return(),"actual encoded archive beyond unchanged48000 bytes refuses")
    check(f.records.bmx_bike_cycle_1_stock100_v1==nil and #f.saves==before,"oversized archive never reaches storage")
    check(not f.owner:archive_return() and f.owner:successor(f.R,{qualification_only=true},f.second_state())==nil,
        "size refusal permanently closes intent2 rather than raising caps/retrying")
    check(f.count("lease")==1,"no replacement acquisition after archive quota refusal")
    return {cases=1,assertions=n,constructed=true,native_authority=false,actual_json_helper=true}
end
return T
