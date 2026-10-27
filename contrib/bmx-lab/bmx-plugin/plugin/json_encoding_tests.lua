-- Standalone runner conformance for the SDK-compatible table conversion and the
-- real Engine/Core/Json writer. No plugin Host or permission checks are claimed.
local Math=require("./force_math")
local Tests={}
function Tests.run(runner)
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(run) cases+=1;run() end
    check(reskate==nil and bmx_luau_runner==nil,"JSON helper is never a module global")
    check(type(runner)=="table" and table.isfrozen(runner),"runner helper argument is required and frozen")
    check(getfenv(Math.finite).bmx_luau_runner==nil,"an imported production dependency has no JSON helper")
    local encode=runner.json_encode
    check(type(encode)=="function","actual Json writer helper is available")
    local function refused(value,reason)
        local ok,message=pcall(encode,value)
        check(not ok and type(message)=="string" and string.find(message,reason,1,true)~=nil,
            "JSON refusal must identify "..reason..", got "..tostring(message))
    end
    case(function()
        check(encode(nil)=="null" and encode(true)=="true" and encode(false)=="false","scalar JSON forms")
        check(encode({})=="{}" and encode({1,2,3})=="[1,2,3]","empty tables are objects and dense tables are arrays")
        check(encode({z=2,a=1})=='{"a":1,"z":2}',"object keys use the SDK writer's stable ordering")
        check(encode({x=1},true)=='{\n  "x": 1\n}',"pretty formatting matches the actual writer")
    end)
    case(function()
        check(encode(9007199254740992)=="9007199254740992","safe integer boundary is written as an integer")
        check(encode(-9007199254740992)=="-9007199254740992" and encode(-0)=="0","negative safe integer and signed zero")
        check(encode(.5)=="0.5","fractional values remain doubles")
        check(encode("18446744073709551615")=='"18446744073709551615"',"u64 identity strings remain exact")
        check(encode(vector.create(1,2,3))=="[1.0,2.0,3.0]","vector components retain SDK double encoding")
    end)
    case(function()
        check(encode('a"\\\n\0b')=='"a\\\"\\\\\\n\\u0000b"',"quotes, slash, newline and NUL use real escaping")
        local utf8=string.char(0xC3,0xA9)
        check(encode(utf8)=='"'..utf8..'"',"UTF-8 bytes are preserved")
        local key="nul\0key"
        check(encode({[key]=true})=='{"nul\\u0000key":true}',"embedded NUL in object key is length delimited")
        local ok=pcall(encode,string.char(0xFF))
        check(not ok,"invalid UTF-8 is refused by the actual JSON writer")
    end)
    case(function()
        refused({[1]=1,[3]=3},"only a list")
        refused({[1]=1,x=2},"only a list")
        refused({[0]=1},"only a list")
        refused({[1.5]=1},"only a list")
        refused({[false]=1},"only a list")
    end)
    case(function()
        refused(0/0,"JSON has no NaN or infinity")
        refused(math.huge,"JSON has no NaN or infinity")
        refused(-math.huge,"JSON has no NaN or infinity")
        refused(vector.create(math.huge,0,0),"JSON has no NaN or infinity")
        refused(newproxy(),"cannot be turned into JSON")
        refused(function() end,"cannot be turned into JSON")
        refused(coroutine.create(function() end),"cannot be turned into JSON")
        refused(buffer.create(1),"cannot be turned into JSON")
    end)
    case(function()
        local cycle={};cycle.self=cycle
        refused(cycle,"tables nested deeper than 32")
        local value={};for _=1,32 do value={value} end
        check(type(encode(value))=="string","a table at depth32 is allowed")
        refused({value},"tables nested deeper than 32")
        local child={x=1}
        check(encode({child,child})=='[{"x":1},{"x":1}]',"shared non-cyclic tables are encoded twice")
        check(encode({ok=true})=='{"ok":true}',"a refusal does not poison the next conversion")
    end)
    case(function()
        local invoked=0
        local function trap() invoked+=1;error("JSON invoked metatable",0) end
        local value=setmetatable({a=1},{__pairs=trap,__index=trap,__len=trap,__tostring=trap})
        check(encode(value)=='{"a":1}' and invoked==0,"SDK raw iteration ignores metatable behavior")
        check(not pcall(function() runner.json_encode=nil end),"test helper is read-only")
    end)
    case(function()
        -- Core's ledger bound against the actual writer: never below it, and nil where it cannot say.
        local Core=require("./bike_runtime_core")
        local control=""
        for byte=0,31 do control..=string.char(byte) end
        local values={true,false,0,-0,1,-1,9007199254740992,-9007199254740992,9007199254740993,.5,-.5,1/3,-2/3,
            1e-7,-1.2345678901234567e-308,1.7976931348623157e308,-1e21,123456.789,0.000001234567890123,
            "","plain",'quote " and \\ backslash',control,string.rep('"',100),string.rep("\\",64),"tab\tnew\nline\127del",
            {},{1,2,3},{x={y={z={}}}},{a="b",c={1,{d=false}}},{list={1,2,{3,4}},n=-12.5},
            table.freeze({row=table.freeze({call="time.now",at_ms=1234.5,called=true,returns=1,first_type="number"})})}
        local cyclic={};cyclic.self=cyclic
        for index,value in ipairs(values) do
            local bound=Core.ledger_bound(value)
            local text=encode(value)
            check(type(bound)=="number" and bound>=#text,"value "..index.." bound "..tostring(bound).." covers "..#text.." bytes")
        end
        local frozen=values[#values]
        check(Core.ledger_bound(frozen)==Core.ledger_bound(frozen),"a frozen table keeps its bound")
        for _,value in ipairs({"caf\195\169",{1,x=2},{[3]=1},{0/0},{-1/0},setmetatable({a=1},{}),cyclic,newproxy(),
            vector.create(1,2,3),function() end}) do
            check(Core.ledger_bound(value)==nil,"no bound for "..typeof(value))
        end
    end)
    return {cases=cases,assertions=assertions,native_actions=0}
end
return Tests