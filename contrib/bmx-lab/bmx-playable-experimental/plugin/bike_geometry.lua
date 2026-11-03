-- Fitted anchors and authored collision proxies from our existing supplied-FBX
-- prototype. No game content is included. The installed native pack must match.
local G = {scale = .7737670588235294, com = {0, .9, -.05}}
local s = G.scale
local function scaled(x,y,z) return {x*s,y*s,z*s} end
G.wheel_radius = .34*s
G.wheelbase = 1.203956057050485*s
G.front_axle = scaled(0,.33993130346462175,.6019780285252407)
G.rear_axle = scaled(0,.3399312125684516,-.6019780285252407)
G.bottom_bracket = scaled(0,.4009181147792979,-.13677059002727915)
G.steering_pivot = scaled(0,.9602538008020781,.3685461188163388)
G.steering_axis = {0,.9601195908265842,-.279589648075517}
-- The fork has offset from its head tube, so steering moves its hub as well
-- as its tyre direction. Use the same fitted pivot/axis as bike_visual. This
-- is an accepted Lua articulation, not an observed native steering joint.
-- A geometry snapshot is explicit so private/custom frames keep their anchors.
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function point(v)
    if type(v)~="table" then return false end
    for i=1,3 do if not finite(v[i]) or math.abs(v[i])>10 then return false end end
    return true
end
function G.front_axle_at(geometry,steer)
    if type(geometry)~="table" or not point(geometry.front_axle)
        or not finite(steer) or math.abs(steer)>1 then return nil end
    local p=geometry.front_axle
    -- Keep the original neutral path exact, including snapshots that only
    -- supply the neutral contact geometry.
    if steer==0 then return {p[1],p[2],p[3]} end
    local c,k=geometry.steering_pivot,geometry.steering_axis
    if not point(c) or not point(k) then return nil end
    local length=math.sqrt(k[1]*k[1]+k[2]*k[2]+k[3]*k[3])
    if length<1e-8 then return nil end
    local k1,k2,k3=k[1]/length,k[2]/length,k[3]/length
    local v1,v2,v3=p[1]-c[1],p[2]-c[2],p[3]-c[3]
    local co,si=math.cos(steer),math.sin(steer)
    local e=(k1*v1+k2*v2+k3*v3)*(1-co)
    return {v1*co+(k2*v3-k3*v2)*si+k1*e+c[1],
        v2*co+(k3*v1-k1*v3)*si+k2*e+c[2],
        v3*co+(k1*v2-k2*v1)*si+k3*e+c[3]}
end
-- bike_visual draws the whole bike pitched about the steering pivot, positive nose down, and then lifted along
-- its own up and shifted along its own forward. How far that raises the front hub and the rear one, in the bike's
-- frame, or nil for a geometry without its hubs and pivot; the shift moves neither up. The neutral front hub stands
-- for a steered one: steering moves it at most 1.8 cm along the bike, at full lock, which changes its rise by under
-- 5 mm at the steepest pitch Ride draws.
-- Given a tilt, in radians from the bike's up toward its forward, the rise is measured along that direction instead,
-- and the shift moves the hubs along it too: the ground's normal under a bike on its rear wheel in a manual stands
-- 20 to 36 degrees from the bike's up. Without one the rise is the bike's-up rise, exactly as before.
function G.hub_rise(geometry,pitch,lift,shift,tilt)
    shift,tilt=shift or 0,tilt or 0
    if type(geometry)~="table" or not point(geometry.front_axle) or not point(geometry.rear_axle)
        or not point(geometry.steering_pivot) or not finite(pitch) or not finite(lift)
        or not finite(shift) or not finite(tilt) then return nil end
    local c=geometry.steering_pivot
    local co,si=math.cos(pitch),math.sin(pitch)
    local up,along=math.cos(tilt),math.sin(tilt)
    local function rise(p)
        local v2,v3=p[2]-c[2],p[3]-c[3]
        return (v2*co-v3*si-v2+lift)*up+(v2*si+v3*co-v3+shift)*along
    end
    return rise(geometry.front_axle),rise(geometry.rear_axle)
end
-- The pitch, lift and shift that raise the front hub by front and the rear one by rear and leave the lower of the
-- two where the body has it along the bike: hub_rise turned round. The pitch is very nearly the angle whose sine is
-- the difference over the wheelbase; it is solved exactly, as the fitted hubs are not quite level. nil for a
-- geometry hub_rise refuses or a difference the wheelbase cannot span.
-- The pitch turns about the steering pivot, which stands 48 cm above the hubs, so on its own it carries both hubs
-- along the bike by about that much times the pitch: 7 to 8 cm with one wheel 14 cm up, the wheel left on the
-- road included. The shift takes that back off the lower hub, so the bike is drawn turned about the wheel on the
-- ground, which stays where the physics has it. The raised hub then comes in toward it by what the climb shortens
-- the wheelbase seen from above, 1 cm at 14 cm and 3 cm at the most Ride draws, as a real wheel climbing a kerb does.
-- Given a tilt the rises are along it, as hub_rise takes them, and the lower hub is kept where the body has it across
-- that direction. Equal rises lift the whole bike along the tilt with no pitch, so which hub is kept does not matter
-- there, and the choice changes only where the rises cross, unpitched. So a bike on its rear wheel in a manual is
-- lifted by the rear's rise straight off the ground that wheel is on: lifted along its own up, 30 degrees off it,
-- the rear tyre was drawn 2 to 3 cm into a kerb and 4 to 7 cm behind where it touches it. The lift and shift come
-- back along the bike's own up and forward, as bike_visual applies them; without a tilt they are the numbers this
-- gave before.
function G.pitch_lift(geometry,front,rear,tilt)
    tilt=tilt or 0
    if not G.hub_rise(geometry,0,0) or not finite(front) or not finite(rear) or not finite(tilt) then return nil end
    local up,along=math.cos(tilt),math.sin(tilt)
    -- A point of the bike in the frame turned by the tilt: how high it is along the tilt, then how far across it.
    local function turned(p) return p[2]*up+p[3]*along,p[3]*up-p[2]*along end
    local c2,c3=turned(geometry.steering_pivot)
    local f2,f3=turned(geometry.front_axle)
    local r2,r3=turned(geometry.rear_axle)
    -- Raising the front by front and the rear by rear, the difference solves b*cos(pitch)-a*sin(pitch)=front-rear+b.
    local a,b=f3-r3,f2-r2
    local span=math.sqrt(a*a+b*b)
    local k=(front-rear+b)/span
    if span<1e-6 or math.abs(k)>=1 then return nil end
    -- A turn about the bike's left is the same turn in either frame.
    local pitch=front==rear and 0 or math.acos(k)-math.atan2(a,b)
    local co,si=math.cos(pitch),math.sin(pitch)
    local v2,v3=f2-c2,f3-c3
    local w2,w3=(front<rear and f2 or r2)-c2,(front<rear and f3 or r3)-c3
    local lift,shift=front-(v2*co-v3*si-v2),-(w2*si+w3*co-w3)
    return pitch,lift*up-shift*along,shift*up+lift*along
end
G.left_grip = scaled(.33457504536745686,1.2319480593290573,.3406239453545827)
G.right_grip = scaled(-.33457504173973396,1.2319480453628473,.34062398104089797)
G.pedals = {scaled(.084980725506,.211285091841,.011246842761),
    scaled(-.084980725506,.590551321670,-.284787818885)}
G.blueprints = {"reskate/bmx/frame","reskate/bmx/fork","reskate/bmx/rear_wheel",
    "reskate/bmx/front_wheel","reskate/bmx/cranks","reskate/bmx/handlebars",
    "reskate/bmx/left_pedal","reskate/bmx/right_pedal"}
-- Each spinning part's mesh has its origin where it spins (prepare_free_native_parts.py): the game
-- smooths position and rotation separately between ticks, so a far origin walks a wheel off its axle
-- by the chord of each tick's turn. Every other part's origin is the bike's, at {0,0,0}.
G.part_origins = {[3]=G.rear_axle,[4]=G.front_axle,[5]=G.bottom_bracket}
local r = G.wheel_radius-.03-.005
G.capsules = {
    {a={0,G.front_axle[2]-.005,G.front_axle[3]},b={0,G.front_axle[2]+.005,G.front_axle[3]},radius=r},
    {a={0,G.rear_axle[2]-.005,G.rear_axle[3]},b={0,G.rear_axle[2]+.005,G.rear_axle[3]},radius=r},
    {a=scaled(0,.45,-.30),b=scaled(0,.60,.20),radius=.12*s},
    {a=G.right_grip,b=G.left_grip,radius=.055*s},
    {a=scaled(0,.73,-.31),b=scaled(0,.73,-.09),radius=.10*s},
    {a={-.12,.89,-.305},b={.12,.89,-.305},radius=.16},
    {a={0,.97,-.30},b={0,1.20,-.15},radius=.18},
    {a={0,1.30,.135},b={0,1.50,.135},radius=.16},
}
-- The original combined bike/rider model. It is proposed tuning, not mesh mass
-- or BMX Streets physics. These values must be qualified in the native trial.
G.mass, G.inertia = 106, {26,32,10}
return G
