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
    local function recorded(name,channel)
        return {name=name or "Barspin",channel=channel or "barspin",body_serial="9007199254740993",
            accepted_sequence="18446744073709551615",state="force_applied_observed"}
    end
    local function closed(outcome,rows)
        return {outcome=outcome,reason="constructed mod policy",score=120,points=50,tricks=2,
            authored=true,native_score=false,native_landing=false,rows=rows}
    end
    v=view();v.last_closed=closed("landed",{recorded("Old tailwhip","tailwhip")})
    check(HUD.lines(v,"none","airborne")[3]=="Tricks: Barspin + Tailwhip","active pending names win over old closed names")
    v.last_closed.rows="bad"
    check(HUD.lines(v,"none","airborne")[3]=="Tricks: Barspin + Tailwhip","malformed old history cannot replace an active pending line")
    v=view();v.active=false;v.rows={}
    v.last_closed=closed("landed",{recorded(),recorded("Tailwhip","tailwhip")})
    text=HUD.lines(v,"none","qualified")
    check(text[3]=="Last landed: Barspin + Tailwhip","closed local landing retains the original trick names")
    check(has(text[1],"UNCALIBRATED") and has(text[5],"bank 400") and has(text[4],"UNBANKED"),"closed names alter no score provenance or totals")
    check(v.last_closed.rows[1].body_serial=="9007199254740993"
        and v.last_closed.rows[1].accepted_sequence=="18446744073709551615"
        and v.last_closed.rows[1].state=="force_applied_observed","formatting preserves exact original metadata")
    check(has(text[6],"LOCAL COMBO BANKED"),"existing authored local closed status stays intact")
    v.last_closed.outcome="lost";text=HUD.lines(v,"none","unavailable")
    check(text[3]=="Last lost: Barspin + Tailwhip" and has(text[6],"LOCAL COMBO LOST")
        and not has(text[6],"BANKED"),"a lost combo is never relabelled as banked")
    v.stopped=true;v.issue="source stopped";text=HUD.lines(v,"source stopped","unavailable")
    check(has(text[3],"Last lost:") and has(text[6],"STOPPED: source stopped"),"history does not replace the stopped-state warning")
    v.stopped=false;v.last_closed.rows=nil
    check(HUD.lines(v,"none","unavailable")[3]=="Tricks: none","legacy closed records with no rows preserve old behavior without invented names")
    v.last_closed=closed("landed",{})
    check(HUD.lines(v,"none","qualified")[3]=="Last landed: none","present empty history never invents a trick from points")
    v.last_closed=closed("landed",{recorded()});v.last_closed.authored=false
    check(HUD.lines(v,"none","qualified")[3]=="Tricks: none","only authored closed history can label the line")
    v.last_closed.authored=true;v.last_closed.native_score=true
    check(HUD.lines(v,"none","qualified")[3]=="Tricks: none","a native-score claim cannot enter closed local labels")
    v.last_closed.native_score=false;v.last_closed.native_landing=true
    check(HUD.lines(v,"none","qualified")[3]=="Tricks: none","a native-landing claim cannot enter closed local labels")
    v.last_closed.native_landing=false;v.last_closed.outcome="interrupted"
    check(HUD.lines(v,"none","unavailable")[3]=="Tricks: none","unrecognized outcomes are not guessed as landed or lost")
    local malformed={"bad",{[2]=recorded()},{recorded(),recorded(),recorded(),recorded(),recorded()},
        {recorded()},{recorded()},{recorded()},{recorded()},{recorded()},{recorded()},{recorded()},{recorded()},
        {setmetatable(recorded(),{__index=function()error("closed row callback must never run")end})}}
    malformed[4][1].name=""
    malformed[5][1].name=string.rep("x",81)
    malformed[6][1].channel="grind"
    malformed[7][1].state="native_landed"
    malformed[8][1].body_serial=9007199254740992
    malformed[9][1].body_serial="18446744073709551616"
    malformed[10][1].accepted_sequence="0"
    malformed[11][1].accepted_sequence="01"
    for _,rows in malformed do
        v.last_closed=closed("landed",rows)
        check(HUD.lines(v,"none","qualified")[3]=="Last landed: unavailable","malformed closed metadata is explicit rather than partially fabricated")
    end
    v.last_closed=closed("landed",{recorded(),recorded()});v.last_closed.tricks=1
    check(HUD.lines(v,"none","qualified")[3]=="Last landed: unavailable","closed row count cannot exceed original trick count")
    local long_name="Barspin\n"..string.rep("x",72)
    v.last_closed=closed("landed",{recorded(long_name),recorded(long_name),recorded(long_name),recorded(long_name)})
    v.last_closed.tricks=4;v.last_closed.rows[1].state="prediction_only"
    text=HUD.lines(v,"none","qualified")
    check(has(text[3],"Last landed:") and #text[3]==HUD.MAX_TEXT and not has(text[3],"\n"),"closed names stay bounded and printable without changing original truth")
    check(v.last_closed.rows[1].name==long_name and v.last_closed.rows[1].state=="prediction_only","text never upgrades stored prediction metadata")
    check(#text==HUD.MAX_LINES and table.isfrozen(text),"closed results keep exactly the same frozen six-line budget")
    for _,line in text do
        check(#line<=HUD.MAX_TEXT and not string.find(line,"[^ -~]"),"every closed-result line retains its ASCII text budget")
    end
    v=view();v.active=false;v.rows={}
    v.last_closed=closed("landed",{recorded("One Hander","one_hander")})
    v.last_closed.tricks=1;v.last_closed.points=100;v.last_closed.score=100
    check(HUD.lines(v,"none","qualified")[3]=="Last landed: One Hander","existing authored one-hander metadata retains its landed name")
    return {cases=1,assertions=n}
end
return Tests
