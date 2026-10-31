-- Authored source fixture only; Root executes after exclusive filesystem return.
local HUD=require("./score_hud")
local Tests={}
function Tests.run()
    local n=0
    local function check(ok,why)n+=1;assert(ok,why)end
    local function has(text,needle)return string.find(text,needle,1,true)~=nil end
    local function view()
        return {scope="authored_mod_score_only",calibration="C0_UNRUN",native_score=false,
            active=true,stopped=false,issue="none",pending_points=50,pending_score=120,
            eligible_pending_score=0,tricks=2,observed_command_tricks=0,multiplier=2,combo_factor=1.2,
            rows={{name="Barspin"},{name="Tailwhip"}},banked_total=400,best_combo=250,landed_combos=2}
    end
    check(HUD.lines(nil,"ride_unavailable","unavailable")==nil,"inactive package has no idle HUD")
    local v=view();local text=HUD.lines(v,"none","unavailable")
    check(#text==6 and table.isfrozen(text),"bounded frozen text snapshot")
    check(has(text[1],"MOD SCORE") and has(text[1],"UNCALIBRATED"),"authored scope and missing C0 are explicit")
    check(has(text[2],"Pending 120") and has(text[2],"2 tricks"),"pending combo remains separate")
    check(has(text[3],"Barspin") and has(text[3],"Tailwhip"),"authored trick names are visible")
    check(has(text[4],"candidate 0") and has(text[4],"UNBANKED"),"prediction is not force-observed or banked")
    check(has(text[5],"Qualified local bank 400"),"prior mod-qualified bank is separate")
    check(has(text[6],"Landing: unavailable"),"missing landing is explicit")
    check(v.eligible_pending_score==0 and v.banked_total==400,"pure formatting changes no ledger fields")
    v.eligible_pending_score=120;text=HUD.lines(v,"none","settling")
    check(has(text[4],"candidate 120") and has(text[4],"UNBANKED"),"observed-force candidate stays unbanked")
    check(has(text[5],"bank 400"),"underlying force observation alone cannot grow the displayed bank")
    v.stopped=true;v.active=false;v.issue="source stopped";v.pending_score=0;v.eligible_pending_score=0
    text=HUD.lines(v,"source stopped","unavailable")
    check(has(text[6],"STOPPED: source stopped"),"stopped score state is explicit")
    check(has(text[5],"bank 400"),"stop preserves prior qualified local totals")
    local missing=HUD.lines(nil,"disabled","unavailable")
    check(has(missing[2],"Scoring unavailable"),"disabled scoring is not invented zero credit")
    check(has(missing[5],"bank: unavailable"),"missing bank stays unavailable")
    v=view();v.native_score=true
    check(has(HUD.lines(v,"bad scope","unavailable")[2],"unavailable"),"native score view cannot enter authored HUD")
    v=view();v.banked_total=0/0
    check(has(HUD.lines(v,"bad total","unavailable")[5],"unavailable"),"nonfinite bank is not shown as qualified")
    v=view();v.rows[1].name="Barspin\n"..string.rep("x",200)
    local bounded=HUD.lines(v,"none","unavailable")
    check(not has(bounded[3],"\n") and #bounded[3]<=HUD.MAX_TEXT,"labels are bounded and printable")
    for _,line in bounded do
        check(type(line)=="string" and #line<=HUD.MAX_TEXT,"each line respects its text bound")
        check(not string.find(line,"[^ -~]"),"all rendered text is printable ASCII")
    end
    check(#HUD.fit(string.rep("x",120),20)==20,"narrow-screen fitting bounds even oversized text")
    check(HUD.fit("A\nB",16)=="A?B","screen fitting preserves printable text only")
    check(HUD.fit("text",8)=="","an unsupported fit limit yields no draw text")
    return {cases=1,assertions=n}
end
return Tests
