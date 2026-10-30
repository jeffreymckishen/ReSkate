-- One first-tick wiring regression. Real Ride/Mapping/Contact/ForceStage;
-- constructed SDK query/receipt transport, no Host, game or optional tricks.
local Ride=require("./ride_runtime")
local Mapping=require("./ride_input_mapping")
local Contact=require("./contact_runtime")
local Stage=require("./force_stage")
local Forces=require("./forces")
local Geometry=require("./bike_geometry")
local Tests={}
function Tests.run()
 local n=0
 local function check(ok,why)n+=1;assert(ok,why)end
 local body,incarnation,lease,epoch=newproxy(),newproxy(),newproxy(),newproxy()
 local serial,sequence="9007199254741001","9007199254744002"
 local batches,submits,acks,receipts=0,0,0,0
 local batch_sizes={6,1,3,3}
 local parked=false
 local command
 local height=.04 -- Small static step makes all three wheel-query phases nonempty.
 local function ray_hit(ray)
  local a,b=ray.from,ray.to
  local dx,dy,dz=b.x-a.x,b.y-a.y,b.z-a.z
  local best
  local function offer(t,nx,ny,nz,inside)
   if t<0 or t>1 or not inside or dx*nx+dy*ny+dz*nz>0 then return end
   if not best or t<best.fraction then
    best={status="hit",position=vector.create(a.x+t*dx,a.y+t*dy,a.z+t*dz),fraction=t,
     normal=vector.create(nx,ny,nz),surface_velocity=vector.create(0,0,0),
     normal_available=true,surface_velocity_available=true,motion="measured"}
   end
  end
  if dy<0 then
   local t=-a.y/dy
   offer(t,0,1,0,a.z+t*dz<0)
   t=(height-a.y)/dy
   offer(t,0,1,0,a.z+t*dz>=0)
  end
  if dz>0 then
   local t=-a.z/dz
   local y=a.y+t*dy
   offer(t,0,0,-1,y>=0 and y<=height)
  end
  return best or {status="clear"}
 end
 local api={}
 function api.probe_batch(got_epoch,plan,options)
  batches+=1
  check(got_epoch==epoch,"every query retains the exact observed native epoch")
  check(batches<=4 and #plan==batch_sizes[batches],"primary6, wall1, witness3, rider-tripwire3 query order")
  check(options.require_contact==true and options.query_preset=="camera"
   and options.require_named_actor_categories_absent==true,"actual category-lane query requirements remain intact")
  local rays={}
  for i,ray in ipairs(plan)do rays[i]=ray_hit(ray) end
  if batches==4 then
   for _,row in ipairs(rays)do check(row.status=="clear","actual rider-tripwire segments remain clear") end
  end
  -- Explicit constructed transport claims. Actual Contact validates each batch;
  -- these are not native exclusion, measured terrain or consumption evidence.
  return {status="available",epoch=got_epoch,native_casts=#plan,budget_exhausted=false,
   local_actor_excluded=false,owned_bodies_excluded=true,requested_query_preset="camera",
   named_actor_categories_absent=true,rays=rays}
 end
 function api.submit(got_epoch,value)
  submits+=1
  check(got_epoch==epoch and batches==4,"first force reaches submit only after all contact phases and tripwire")
  check(typeof(value.force)=="vector" and typeof(value.torque)=="vector","actual ForceStage supplies native-vector packet shape")
  local f,t=value.force,value.torque
  check(math.sqrt(f.x*f.x+f.y*f.y+f.z*f.z)<=6000
   and math.sqrt(t.x*t.x+t.y*t.y+t.z*t.z)<=2000,"unchanged authored force and torque caps govern the packet")
  check(value.impulse==nil and value.impulse_id==nil,"neutral first frame invents no hop or optional trick")
  command=value
  return true,nil,sequence
 end
 function api.receipt(got_sequence)
  receipts+=1
  check(got_sequence==sequence and submits==1,"receipt reads retain the original accepted identity")
  return {sequence=sequence,requested_serial=serial,produced_serial=parked and "9007199254741002" or "0",
   outcome=parked and "applied" or "queued",force_attempted=parked,torque_attempted=parked,
   retained=parked,quarantined=false,cleanup_disposition=parked and "parked_without_successor" or "none"}
 end
 function api.acknowledge(got_sequence)
  check(parked and got_sequence==sequence and acks==0,"only the original terminal parked receipt can ACK once")
  acks+=1
  return true
 end
 local pad={left_x=0,left_y=0,right_x=0,right_y=0,left_trigger=0,right_trigger=0,playstation=false,
  buttons={a=false,b=false,right_stick=false,lb=false,rb=false}}
 local source_frame={input_ok=true,phase="capturing",generation=1,lease_handle=lease,
  sample={user=0,sequence="9007199254740993",source_epoch="9007199254740995",
   context_generation="9007199254740997",observation_serial="9007199254742001",
   observed_ms="1000",packet=9,pad=pad}}
 local raw={epoch=epoch,serial=serial,time=1,seconds=Forces.native_seconds,mass=Geometry.mass,
  position=vector.create(0,.9,-.23-(Geometry.front_axle[3]-Geometry.com[3])),
  velocity=vector.create(0,0,0),angular_velocity=vector.create(0,0,0),
  inertia=vector.create(26,32,10),rotation={0,0,0,1}}
 local context={now_ms=1000,focused=true,menu_open=false,loaded=true}
 -- Same owner/model contracts as ride_runtime_tests.fixture, without its old
 -- two-ray fake decoder, qualified copy, or optional trick adapter.
 local ride=Ride.new(api,{mapping=Mapping.new(),force=Stage.new(),contact=Contact},
  {body_handle=body,incarnation=incarnation})
 local first=ride:observe(source_frame,raw,context)
 check(not first.stop_requested,"first eligible observation must not stop: "..tostring(first.issue))
 check(first.activation_qualified==true and first.observed_steps==1 and first.model_steps==1,
  "actual active Ride advances one observed and one companion/model frame")
 check(first.submitted==1 and submits==1 and command~=nil,"first eligible native frame submits exactly one force packet")
 check(first.input_consumed==1 and first.last_serial==serial,"first model retains exact selected input and body serial")
 check(first.pending_count==1 and first.pending_sequence==sequence and first.acknowledged==0 and acks==0,
  "accepted command keeps its own pending receipt; no invented successor or early ACK")
 check(first.model_history.kind=="predictive_accepted" and first.model_history.serial==serial
  and first.model_history.sequence==sequence and first.model_history.native_wheel_state_known==false,
  "accepted real ForceStage history remains predictive, not native wheel evidence")
 check(first.model.trick_fallbacks==0 and first.model.trick_status==nil,
  "companion route reaches submit without requiring an optional trick adapter")
 local duplicate=ride:observe(source_frame,raw,context)
 check(not duplicate.stop_requested and duplicate.submitted==1 and submits==1 and batches==4,
  "duplicate observed epoch may poll receipts but cannot requery or submit twice")
 local stopped=ride:stop("constructed first-tick transport cleanup")
 check(stopped.stop_requested and stopped.force_pending and acks==0,"stop keeps the original queued receipt duty")
 parked=true -- Bounded fake SDK terminal park, not native retirement proof.
 local drained=ride:drain()
 check(drained.stop_requested and not drained.force_pending and not drained.unknown
  and drained.acknowledged==1 and acks==1,"known terminal park drains exactly the original transport receipt")
 ride:drain()
 local final=ride:observe(source_frame,raw,context)
 check(final.stop_requested and final.submitted==1 and submits==1 and acks==1 and batches==4,
  "terminal cleanup cannot rearm observation, replay a packet or duplicate ACK")
 return {cases=1,assertions=n,contact_batches=batches,submitted=submits,acknowledged=acks,
  native_actions=0,game_evidence=false}
end
return table.freeze(Tests)
