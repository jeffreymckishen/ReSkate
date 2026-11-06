-- Test-only exact-main wrapper and constructor/event/menu wiring. No game APIs.
local Main=require("./playable_main_fixture")
local ScoreHUD=require("./score_hud")
local YButton=require("./y_button")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,fn) cases+=1;local ok,why=pcall(fn);assert(ok,name..": "..tostring(why)) end
    -- world, when given, is the game around bike mode (y_button.lua): storage, clock, focus, menus, pad and rider.
    local function pad()
        local p={left_x=0,left_y=0,right_x=0,right_y=0,left_trigger=0,right_trigger=0,buttons={}}
        for _,name in {"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"} do p.buttons[name]=false end
        return p
    end
    local function setup(score_view,world)
        local f={new_calls=0,callbacks={},buttons={},mounts=0,returns=0,recovers=0,cancels=0,steps=0,unloads=0,status_reads=0,score_reads=0,requires={},binds={},notes={},
            toggles={},controls={},events={}}
        local Runtime,Survey={},{}
        local controller={}
        function controller:mount() f.mounts+=1;f.events[#f.events+1]="mount";return false,"closed" end
        function controller:return_to_skateboard() f.returns+=1;return false,"not mounted" end
        function controller:recover()
            f.recovers+=1
            if f.report and f.report.recovery_available==true then
                f.report.recovery_available=false;f.report.recovery_pending=true;return true
            end
            return false,"not eligible"
        end
        function controller:cancel() f.cancels+=1;return true end
        function controller:step(dt) f.steps+=1;f.last_dt=dt end
        function controller:unload() f.unloads+=1;f.events[#f.events+1]="unload" end
        function controller:next_start_state() return f.start end
        function controller:set_controls(kind) f.controls[#f.controls+1]=kind;return true end
        -- What Entry's HUD help says; nil (the default) is none.
        function controller:help_line() return f.help end
        function controller:score_view()
            f.score_reads+=1
            if score_view==nil then return nil,"ride_unavailable","unavailable" end
            return score_view,"none","unavailable"
        end
        function controller:status()
            f.status_reads+=1
            if f.report then return f.report end
            return {phase="idle",detail="closed",admitted=false,core_phase="idle",cleanup_pending=false,cleanup_unknown=false}
        end
        local R={menu={},input={}}
        if world then
            R.storage,R.time,R.skater={},{},{}
            function R.storage.get(key) return world.records[key] end
            function R.storage.set(key,value) world.writes+=1;world.records[key]=value end
            function R.time.now() return world.now end
            function R.input.focus() return {focused=true,gameplay=true,interface_open=world.overlay==true} end
            function R.menu.game() return {open=false} end
            function R.input.gamepad() return world.pad end
            function R.input.game_buttons(hidden,held,pause)
                world.masks[#world.masks+1]={hidden,held,pause};f.events[#f.events+1]="mask "..hidden
            end
            function R.skater.telemetry()
                return {skater=true,airborne=false,teleport_pending=false,watch={valid=true,state=world.state,ragdoll_known=true,ragdoll=false}}
            end
            function R.skater.get() return {airborne=false} end
        end
        function R.input.bind(name,key) f.binds[#f.binds+1]={name=name,key=key};return true end
        function R.on(event,fn) check(f.callbacks[event]==nil,"one callback per event");f.callbacks[event]=fn end
        function R.menu.page(name,fn) f.page=name;f.menu=fn end
        local E={}
        function E.new(actual,run,survey,options)
            f.new_calls+=1;check(actual==R and run==Runtime and survey==Survey,"main binds exact service/runtime/survey modules")
            check(options.admitted==false and options.slot==0,"source admission stays closed and slot unchanged")
            f.options=options
            return controller
        end
        local modules={["./bike_runtime"]=Runtime,["./ride_r1_record"]=Survey,["./bmx_playable_entry"]=E,["./score_hud"]=ScoreHUD,["./y_button"]=YButton}
        local function require_one(name) check(modules[name]~=nil,"no undeclared main dependency");f.requires[#f.requires+1]=name;return modules[name] end
        Main(R,require_one)
        local ui={}
        function ui:warn(_) end;function ui:note(text) f.notes[#f.notes+1]=text end;function ui:info(_,_) end
        function ui:button(id,_) return f.buttons[id]==true end
        function ui:toggle(id,text,on,help)
            f.toggles[#f.toggles+1]={id=id,text=text,on=on,help=help}
            if f.flip and f.flip[id]~=nil then local to=f.flip[id];f.flip[id]=nil;return to end
            return on
        end
        f.ui=ui;return f
    end
    case("one inert controller and five declared Lua dependencies",function()
        local f=setup();check(f.new_calls==1 and #f.requires==5 and f.requires[5]=="./y_button","main creates one owner coordinator once")
        check(type(f.callbacks.tick)=="function" and type(f.callbacks.draw)=="function" and type(f.callbacks.unload)=="function" and type(f.callbacks.action)=="function" and type(f.menu)=="function","entry binds normal events/menu")
    end)
    case("explicit Mount Return Cancel reach the same controller",function()
        local f=setup();f.menu(f.ui);check(f.mounts==0 and f.returns==0 and f.cancels==0,"draw alone dispatches no command")
        f.buttons.bmx_play_mount=true;f.menu(f.ui);f.buttons={}
        f.buttons.bmx_play_return=true;f.menu(f.ui);f.buttons={}
        check(f.mounts==1 and f.returns==1 and f.new_calls==1,"two explicit buttons, no second owner")
    end)
    case("tick and unload delegate without constructing sessions",function()
        local f=setup();for _=1,20 do f.callbacks.tick(16) end;f.callbacks.unload()
        check(f.steps==20 and f.last_dt==16 and f.unloads==1 and f.new_calls==1,"same controller receives ordinary ticks/unload")
    end)
    case("F8 action uses the guarded Return path without opening the menu",function()
        local f=setup()
        check(#f.binds==6 and f.binds[1].name=="bmx_return" and f.binds[1].key=="F8","F8 default remains alongside recovery; remapping belongs to Binds")
        check(f.returns==0 and f.mounts==0 and f.cancels==0 and f.steps==0 and #f.notes==0,"registration dispatches no lifecycle command or menu draw")
        f.callbacks.action("another_action");f.callbacks.action(nil);f.callbacks.action({name="bmx_return"})
        check(f.returns==0 and f.mounts==0 and f.cancels==0,"only the exact action name selects Return")
        f.callbacks.action("bmx_return")
        check(f.returns==1 and f.new_calls==1 and #f.notes==0,"action reaches the existing controller without menu interaction")
        f.callbacks.action("bmx_return")
        check(f.returns==2 and f.mounts==0 and f.cancels==0 and f.steps==0,"guarded refusal is not converted into Mount, Cancel, input or a replacement owner")
        f.buttons.bmx_play_return=true;f.menu(f.ui)
        check(f.returns==3 and f.new_calls==1,"menu and action use the exact same Return method")
        local noted=false
        for _,note in ipairs(f.notes) do if note:find("F8",1,true) and note:find("skateboard",1,true) then noted=true end end
        check(noted,"menu documents the normal gameplay action and remapping")
    end)
    case("F9 requests existing eligible recovery once and is inert after unload",function()
        local f=setup()
        check(#f.binds==6 and f.binds[2].name=="bmx_recover" and f.binds[2].key=="F9","one remappable F9 recovery default")
        check(f.recovers==0 and f.status_reads==0 and f.steps==0 and #f.notes==0,"registration never requests recovery or draws the menu")
        f.report={phase="riding",detail="constructed",admitted=true,core_phase="following",recovery_available=false,
            attempts_used=1,attempt_limit=2,cleanup_pending=false,cleanup_unknown=false}
        f.callbacks.action("bmx_recover")
        check(f.recovers==0 and f.mounts==0 and f.returns==0 and f.cancels==0 and #f.notes==0,"active ride cannot request recovery or menu inspection")
        f.report.phase="fallen";f.report.recovery_available=nil
        f.callbacks.action("bmx_recover");f.callbacks.action({name="bmx_recover"});f.callbacks.action("another_action")
        f.report.recovery_available=1;f.callbacks.action("bmx_recover")
        f.report.recovery_available="true";f.callbacks.action("bmx_recover")
        check(f.recovers==0,"missing/nonboolean eligibility and nonmatching actions never reach Recover")
        f.report.recovery_available=true;f.report.fall_reason="constructed measured tilt stop"
        f.callbacks.action("bmx_recover")
        check(f.recovers==1 and f.report.recovery_pending==true and f.report.recovery_available==false,"eligible key press delegates one existing intent")
        f.callbacks.action("bmx_recover");f.callbacks.action("bmx_recover")
        check(f.recovers==1,"pending intent makes repeated key actions ineligible")
        check(f.new_calls==1 and f.mounts==0 and f.returns==0 and f.cancels==0 and f.steps==0 and #f.notes==0,
            "direct key creates no owner, direct Mount/Return, tick or menu work")
        f.menu(f.ui)
        check(f.recovers==1,"drawing the menu recovers nothing")
        f.report.recovery_available=true
        local reads,notes=f.status_reads,#f.notes
        f.callbacks.unload();f.callbacks.action("bmx_recover")
        check(f.unloads==1 and f.recovers==1,"unload disables even a late key callback with stale eligible status")
        check(f.status_reads==reads and #f.notes==notes and f.returns==0 and f.mounts==0,
            "late key callback performs no status, menu or lifecycle work")
    end)
    case("controller recovery shares exact eligibility and pending intent with F9",function()
        local f=setup()
        check(#f.binds==6 and f.binds[3].name=="bmx_recover_pad" and f.binds[3].key=="Pad.LB+Pad.RB+Pad.L3",
            "separate remappable controller action preserves the F8/F9 defaults")
        f.report={phase="riding",detail="constructed",admitted=true,core_phase="following",recovery_available=false,
            attempts_used=1,attempt_limit=2,cleanup_pending=false,cleanup_unknown=false}
        f.callbacks.action("bmx_recover_pad")
        check(f.recovers==0,"controller action cannot request recovery while riding")
        f.report.phase="fallen";f.report.recovery_available=1;f.callbacks.action("bmx_recover_pad")
        f.report.recovery_available=nil;f.callbacks.action("bmx_recover_pad")
        check(f.recovers==0,"controller action uses only exact existing boolean eligibility")
        f.report.recovery_available=true;f.report.fall_reason="constructed measured tilt stop"
        f.callbacks.action("bmx_recover_pad")
        check(f.recovers==1 and f.report.recovery_pending==true and f.report.recovery_available==false,
            "eligible controller action calls the same existing Recover intent")
        f.callbacks.action("bmx_recover_pad");f.callbacks.action("bmx_recover")
        check(f.recovers==1,"controller repeat and F9 cannot duplicate the same pending intent")
        check(f.new_calls==1 and f.mounts==0 and f.returns==0 and f.cancels==0 and f.steps==0 and #f.notes==0,
            "controller action adds no owner, direct Mount/Return, tick or menu work")
        f.menu(f.ui)
        check(f.recovers==1,"drawing the menu does not recover")
        f.report.recovery_available=true;local reads=f.status_reads
        f.callbacks.unload();f.callbacks.action("bmx_recover_pad");f.callbacks.action("bmx_recover")
        check(f.unloads==1 and f.recovers==1 and f.status_reads==reads,"unload blocks both late recovery actions before status or intent calls")
    end)
    case("controller Return uses the exact F8 path without a menu or ride input step",function()
        local f=setup()
        check(#f.binds==6 and f.binds[4].name=="bmx_return_pad" and f.binds[4].key=="Pad.LB+Pad.RB+Pad.R3",
            "separate remappable Return chord preserves all earlier binding defaults")
        check(f.returns==0 and f.mounts==0 and f.recovers==0 and f.steps==0 and f.status_reads==0,
            "registering the Return chord performs no lifecycle or input work")
        f.callbacks.action("Pad.LB+Pad.RB+Pad.R3");f.callbacks.action({name="bmx_return_pad"});f.callbacks.action(nil)
        check(f.returns==0 and f.status_reads==0,"only the action identity selects Return; raw or remapped key text is not a command")
        f.callbacks.action("bmx_return_pad")
        check(f.returns==1 and f.new_calls==1 and f.status_reads==0 and f.steps==0 and #f.notes==0,
            "the chord directly invokes the existing guarded Entry Return before any tick or menu")
        f.callbacks.action("bmx_return");f.callbacks.action("bmx_return_pad")
        check(f.returns==3 and f.mounts==0 and f.recovers==0 and f.cancels==0 and f.steps==0,
            "F8 and the pad action share refusal semantics without a replacement owner, recovery or input step")
        f.menu(f.ui)
        check(f.returns==3,"drawing the menu never repeats Return")
        f.callbacks.unload()
        check(f.unloads==1 and f.new_calls==1 and f.returns==3 and f.steps==0,"unload delegates cleanup to the same existing Entry")
        check(#f.binds==6 and f.mounts==0 and f.recovers==0 and f.cancels==0,
            "events and unload add no rebindings or alternate lifecycle actions; SDK owns binding cleanup")
    end)
    case("controller Mount requests the existing guarded intent without a menu or input step",function()
        local f=setup()
        check(#f.binds==6 and f.binds[5].name=="bmx_mount_pad" and f.binds[5].key=="Pad.LB+Pad.A",
            "a separate remappable Mount action preserves the Return and recovery defaults")
        check(f.mounts==0 and f.returns==0 and f.recovers==0 and f.steps==0 and f.status_reads==0,
            "registration never requests Mount or bypasses the closed source constructor")
        f.callbacks.action("Pad.LB+Pad.A");f.callbacks.action({name="bmx_mount_pad"});f.callbacks.action(nil)
        check(f.mounts==0 and f.status_reads==0,"only the stable Mount action name selects the intent after any remap")
        f.callbacks.action("bmx_mount_pad")
        check(f.mounts==1 and f.new_calls==1 and f.status_reads==0 and f.steps==0 and #f.notes==0,
            "the action calls the same Entry Mount directly without a new owner, authority latch or tick")
        f.callbacks.action("bmx_mount_pad")
        check(f.mounts==2 and f.returns==0 and f.recovers==0 and f.cancels==0 and f.steps==0,
            "a separately delivered explicit event preserves Entry refusal instead of queuing an automatic retry")
        f.buttons.bmx_play_mount=true;f.menu(f.ui);f.buttons={}
        check(f.mounts==3 and f.new_calls==1,"the menu button and controller action use exactly the same guarded Mount method")
        check(f.mounts==3,"drawing the menu performs no automatic Mount")
        f.callbacks.unload()
        check(f.unloads==1 and f.new_calls==1 and f.mounts==3 and f.returns==0 and f.cancels==0 and #f.binds==6,
            "unload uses the existing Entry and SDK binding cleanup without an alternate lifecycle")
    end)
    case("score HUD draws six cached lines above stock hints at the observed resolution",function()
        local score={scope="authored_mod_score_only",calibration="C0_UNRUN",native_score=false,
            active=true,stopped=false,issue="none",pending_score=120,eligible_pending_score=0,
            banked_total=400,best_combo=250,tricks=2,multiplier=2,combo_factor=1.2,
            rows={{name="Barspin"},{name="Tailwhip"}}}
        local f=setup(score)
        local expected=ScoreHUD.lines(score,"none","unavailable")
        local draw={calls={},sizes=0,measures=0,panels={},order={}}
        function draw:size() self.sizes+=1;return vector.create(2560,1440,0) end
        function draw:measure(text,style)
            self.measures+=1
            return vector.create(#text*8*(1440/1080),style.size*(1440/1080),0)
        end
        function draw:rect(a,b,style)
            self.panels[#self.panels+1]={a=a,b=b,style=style};self.order[#self.order+1]="rect"
        end
        function draw:text(position,text,style)
            self.order[#self.order+1]="text"
            self.calls[#self.calls+1]={position=position,text=text,style=style}
        end
        f.callbacks.draw(draw)
        check(#draw.calls==0 and draw.sizes==0 and draw.measures==0 and #draw.panels==0 and f.steps==0 and f.score_reads==0,
            "draw before a tick has no score cache or lifecycle work")
        f.callbacks.tick(16)
        check(f.steps==1 and f.last_dt==16 and f.score_reads==1,"only tick refreshes the cached score view")
        f.callbacks.draw(draw)
        check(draw.sizes==1 and draw.measures==6 and #draw.calls==6 and #draw.panels==1,"one size read, bounded text measurements, one backing and the same six text calls")
        local panel=draw.panels[1]
        local measured_width=0
        for _,text in expected do measured_width=math.max(measured_width,#text*8*(1440/1080)) end
        check(panel.style==ScoreHUD.panel_style and table.isfrozen(panel.style) and panel.style.fill==true
            and panel.style.colour=="#10151DE6" and panel.style.rounding==8
            and #draw.order==7 and draw.order[1]=="rect","one frozen translucent dark fill precedes the unchanged six texts")
        check(panel.a.x==32 and panel.a.y==32 and panel.b.y==248
            and math.abs(panel.b.x-(64+measured_width))<.001 and panel.b.x<=2560-32 and panel.b.y<=1440-32,
            "compact backing uses measured pixels once with scaled padding inside the viewport")
        for i=1,6 do
            local call=draw.calls[i]
            check(call.position.x==48 and call.position.y==48+(i-1)*32 and call.position.z==0,
                "score row "..i.." uses the upper-left scaled position")
            check(call.text==expected[i] and call.style==(i==1 and ScoreHUD.header_style or ScoreHUD.row_style),
                "moving row "..i.." preserves the exact authored score text and style")
        end
        check(f.score_reads==1 and f.status_reads==0 and f.steps==1 and #f.notes==0
            and f.mounts==0 and f.returns==0 and f.recovers==0 and f.cancels==0,
            "drawing reads only cached text and never opens menus or drives lifecycle actions")
        f.callbacks.unload();f.callbacks.draw(draw)
        check(f.unloads==1 and #draw.calls==6 and draw.sizes==1 and draw.measures==6 and #draw.panels==1 and f.score_reads==1,
            "unload clears the display cache without any late draw or score read")
    end)
    case("before the first ride the HUD panel still shows the help line",function()
        -- With no Ride yet ScoreHUD.lines is nil, and copying it raised inside the tick's pcall, so nothing was drawn
        -- while the bike got ready, checked for room or said why a Mount did not start.
        local f=setup()
        local draw={calls={},panels={}}
        function draw:size() return vector.create(1920,1080,0) end
        function draw:measure(text,style) return vector.create(#text*8,style.size,0) end
        function draw:rect(a,b,style) self.panels[#self.panels+1]={a=a,b=b,style=style} end
        function draw:text(position,text,style) self.calls[#self.calls+1]={position=position,text=text,style=style} end
        f.callbacks.tick(16);f.callbacks.draw(draw)
        check(#draw.calls==0 and #draw.panels==0,"no Ride and no help draws nothing, as before")
        f.help="Getting the bike ready: stand still."
        f.callbacks.tick(16);f.callbacks.draw(draw)
        check(#draw.calls==1 and draw.calls[1].text==f.help and #draw.panels==1,"the help is the panel's one row")
        f.help="Step off your skateboard with Y, then hold LB and press A."
        draw.calls,draw.panels={},{}
        f.callbacks.tick(16);f.callbacks.draw(draw)
        check(#draw.calls==1 and draw.calls[1].text==f.help,"and a refused Mount's notice shows the same way")
        f.help=nil;draw.calls,draw.panels={},{}
        f.callbacks.tick(16);f.callbacks.draw(draw)
        check(#draw.calls==0,"and it goes when the help does")
    end)
    case("the sixth bind is Y on its own, and does nothing until bike mode is switched on",function()
        local f=setup()
        check(#f.binds==6 and f.binds[6].name=="bmx_y" and f.binds[6].key=="Pad.Y","Y alone, listed in Binds like the rest")
        check(f.options.settings_key=="bmx_settings_v1","Entry is told the one storage key bike mode keeps")
        f.callbacks.action("bmx_y");for _=1,5 do f.callbacks.tick(16) end
        check(f.mounts==0 and f.returns==0 and f.status_reads==0 and #f.controls==0,"bike mode off: Y asks nothing of Entry and reads nothing")
        f.menu(f.ui)
        local toggle=f.toggles[1]
        check(#f.toggles==1 and toggle.id=="bmx_bike_mode" and toggle.on==false and #toggle.text<=60 and #toggle.help<=300
            and toggle.text:find("Y",1,true)~=nil,"the page has the bike mode switch, off by default, within the SDK's text limits")
    end)
    case("the bike mode switch is kept in one storage key, written only when it changes",function()
        local world={records={},writes=0,now=0,pad=pad(),masks={},state=504}
        local f=setup(nil,world)
        f.menu(f.ui);check(world.writes==0 and #f.controls==0,"drawing the page writes nothing")
        f.flip={bmx_bike_mode=true};f.menu(f.ui)
        local kept=world.records.bmx_settings_v1
        check(world.writes==1 and kept.schema==1 and kept.bike_mode==true and f.controls[1]=="y",
            "switching on writes the one key once, and Entry's lines say Y")
        for _=1,3 do f.menu(f.ui) end
        check(world.writes==1 and f.toggles[#f.toggles].on==true,"the page shows it on and writes nothing more")
        local noted=false
        for _,note in f.notes do if note:find("PlayStation",1,true) and note:find("Steam Input",1,true) then noted=true end end
        check(noted,"the page says a PlayStation pad without Steam Input may still pass Y to the game")
        local g=setup(nil,{records=world.records,writes=0,now=0,pad=pad(),masks={},state=504})
        check(g.controls[1]=="y","the next launch starts in bike mode")
        g.flip={bmx_bike_mode=false};g.menu(g.ui)
        check(g.controls[2]=="lb_a" and world.records.bmx_settings_v1==nil,"switching off clears the key")
    end)
    case("in bike mode Y reaches the same Entry, other buttons give Y back first, and unload gives it back before Entry",function()
        local world={records={bmx_settings_v1={schema=1,bike_mode=true}},writes=0,now=0,pad=pad(),masks={},state=504}
        local f=setup(nil,world)
        f.report={phase="riding",admitted=true,detail="",core_phase="following",cleanup_pending=false,cleanup_unknown=false}
        f.callbacks.action("bmx_y")
        check(f.returns==1 and f.mounts==0 and #world.masks==0,"riding, Y is the Return, with nothing hidden")
        f.report.phase="idle";f.start=504
        for _=1,3 do world.now+=16;f.callbacks.tick(16) end
        check(#world.masks==1 and world.masks[1][1]==0x8000 and world.masks[1][2]==0 and world.masks[1][3]==false,
            "idle on foot before the first ride: Y is kept from the game")
        f.callbacks.action("bmx_mount_pad")
        check(#world.masks==2 and world.masks[2][1]==0 and f.events[#f.events]=="mount" and f.events[#f.events-1]=="mask 0",
            "LB + A gives Y back before it asks Entry for the Mount")
        for _=1,3 do world.now+=16;f.callbacks.tick(16) end
        check(#world.masks==3 and world.masks[3][1]==0x8000,"the refused Mount left the mod idle, so Y is kept again")
        f.callbacks.unload()
        check(#world.masks==4 and world.masks[4][1]==0 and f.events[#f.events]=="unload" and f.events[#f.events-1]=="mask 0",
            "unload gives Y back, then unloads Entry")
    end)
    return {cases=cases,assertions=assertions,game_evidence=false,native_actions=0}
end
return table.freeze(Tests)
