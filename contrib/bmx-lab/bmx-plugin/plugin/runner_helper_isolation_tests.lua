-- The harness helper is an explicit capability for two selected suites, never
-- a production-module global and never inherited by importing those suites.
local Math=require("./force_math")
local JsonTests=require("./json_encoding_tests")
local Tests={}
function Tests.run(...)
    local assertions=0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    check(getfenv(Math.finite).bmx_luau_runner==nil,"production dependency sees the runner-only JSON helper")
    check(bmx_luau_runner==nil and reskate==nil,"ordinary suite has only its ordinary sandbox globals")
    check(select("#",...)==0,"ordinary suite received a runner-only argument")
    check(getfenv(JsonTests.run).bmx_luau_runner==nil,"importing a privileged suite grants no ambient helper")
    local ok,reason=pcall(JsonTests.run)
    check(not ok and type(reason)=="string" and string.find(reason,"runner helper argument",1,true)~=nil,
        "importing a privileged suite must not grant its explicit helper argument")
    return {cases=1,assertions=assertions,native_actions=0}
end
return Tests