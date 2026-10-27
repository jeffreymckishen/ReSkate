-- Dynamic namespace proxies preserve the SDK's plain-function convention.
-- No body read, receipt poll, conversion, retry or cleanup is added here.
local Services={}
local watched={
    ["time.now"]=true,["skater.pose"]=true,["world.probe"]=true,
    ["world.physics.prepare"]=true,
    ["world.physics.create"]=true,["world.physics.read"]=true,["world.physics.release"]=true,
    ["world.physics.probe_batch"]=true,["world.physics.submit"]=true,
    ["world.physics.receipt"]=true,["world.physics.acknowledge"]=true,
    ["world.physics.reserve_follow"]=true,["world.physics.publish_follow"]=true,
    ["world.physics.read_follow"]=true,["world.physics.stop_follow"]=true,
    ["world.physics.acknowledge_follow"]=true,["world.physics.read_follow_lease"]=true,
}
for _,name in ipairs({"lease","lease_read","lease_renew","lease_state","lease_release","lease_acknowledge",
    "lease_capture","lease_capture_state","lease_release_capture","lease_acknowledge_capture"}) do
    watched["input."..name]=true
end
local branches={input=true,time=true,skater=true,world=true,["world.physics"]=true}
function Services.wrap(real,context)
    assert(type(real)=="table" and type(context)=="table","SDK table and trial context required")
    local function observe(path,args,result)
        local ok,accepted=pcall(context.observe_service,context,path,args,result)
        if not ok or accepted==false then pcall(context.request_stop,context,"service observer failed") end
    end
    local function forward(fn,path,...)
        local args=table.pack(...)
        local result=table.pack(pcall(fn,table.unpack(args,1,args.n)))
        observe(path,args,result)
        if not result[1] then error(result[2],0) end
        return table.unpack(result,2,result.n)
    end
    local function proxy(resolve,prefix)
        return table.freeze(setmetatable({},{__index=function(_,key)
            local parent=resolve()
            local value=type(parent)=="table" and parent[key] or nil
            local path=prefix=="" and key or prefix.."."..tostring(key)
            if branches[path] and type(value)=="table" then
                return proxy(function() local p=resolve();return type(p)=="table" and p[key] or nil end,path)
            end
            if not watched[path] or type(value)~="function" then return value end
            return function(...)
                -- Resolve again: lookup cannot pin a removed or replaced API.
                local latest=resolve();local fn=type(latest)=="table" and latest[key] or nil
                if path=="world.physics.submit" then
                    local args=table.pack(...)
                    return context:submit(args[1],args[2],args[3],function(body,epoch,packet)
                        assert(body==args[1] and epoch==args[2] and packet==args[3],"guard changed the submitted arguments")
                        return forward(fn,path,table.unpack(args,1,args.n))
                    end)
                end
                return forward(fn,path,...)
            end
        end}))
    end
    return proxy(function() return real end,"")
end
return table.freeze(Services)
