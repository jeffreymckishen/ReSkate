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
-- its own up. How far that raises the front hub and the rear one, in the bike's frame, or nil for a geometry
-- without its hubs and pivot. The neutral front hub stands for a steered one: steering moves it at most 1.8 cm
-- along the bike, at full lock, which changes its rise by under 5 mm at the steepest pitch Ride draws.
function G.hub_rise(geometry,pitch,lift)
    if type(geometry)~="table" or not point(geometry.front_axle) or not point(geometry.rear_axle)
        or not point(geometry.steering_pivot) or not finite(pitch) or not finite(lift) then return nil end
    local c=geometry.steering_pivot
    local co,si=math.cos(pitch),math.sin(pitch)
    local function rise(p)
        local v2,v3=p[2]-c[2],p[3]-c[3]
        return v2*co-v3*si-v2+lift
    end
    return rise(geometry.front_axle),rise(geometry.rear_axle)
end
-- The pitch and lift that raise the front hub by front and the rear one by rear: hub_rise turned round. The
-- pitch is very nearly the angle whose sine is the difference over the wheelbase; it is solved exactly, as the
-- fitted hubs are not quite level. nil for a geometry hub_rise refuses or a difference the wheelbase cannot span.
function G.pitch_lift(geometry,front,rear)
    if not G.hub_rise(geometry,0,0) or not finite(front) or not finite(rear) then return nil end
    local c,f,r=geometry.steering_pivot,geometry.front_axle,geometry.rear_axle
    -- Raising the front by front and the rear by rear, the difference solves b*cos(pitch)-a*sin(pitch)=front-rear+b.
    local a,b=f[3]-r[3],f[2]-r[2]
    local span=math.sqrt(a*a+b*b)
    local k=(front-rear+b)/span
    if span<1e-6 or math.abs(k)>=1 then return nil end
    local pitch=math.acos(k)-math.atan2(a,b)
    local v2,v3=f[2]-c[2],f[3]-c[3]
    return pitch,front-(v2*math.cos(pitch)-v3*math.sin(pitch)-v2)
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
