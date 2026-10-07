-- A player character for the physics scene (lib/physics-mode.lua), controlled the way
-- Darksiders is: a third-person camera on the character, movement relative to the camera,
-- a sword combo, a launcher, a plunging attack from the air, a dodge roll, a double jump
-- and a glide, and an aim mode that brings the camera over the shoulder for throwing.
--
-- The body is a Jolt character (world:character): a capsule that walks on the scene's
-- bodies, steps up and sticks to slopes, and pushes what it walks into. The host moves it
-- at the physics rate; Lua sets its horizontal velocity and its jumps every frame. Attacks
-- set the velocities of the bodies they hit.
--
-- The figure is drawn from boxes and a sphere: "visual" bodies in two groups, which the
-- host draws (and shadows) like the scene's other bodies, posed by Lua every frame.
--
-- Steam Controller:
--   left stick      move (walk to run)           right stick / right pad   camera
--   A               jump; again in the air: double jump; hold while falling: glide
--   B               dodge roll                    X   sword combo (in the air: plunge)
--   Y               launcher                      R3  (press the right stick) toggle aim mode
--   RT              throw (in aim mode: at the crosshair; hold to keep throwing)
--   LT              camera behind the character
--   gyro            in aim mode: a small extra tilt of the aim, on top of the right stick
-- Keyboard and mouse: WASD move, mouse drag camera, Space jump, Shift dodge, F combo,
-- G launcher, Q aim mode, E throw, C camera behind.

local AXIS_DEADZONE = 0.16
-- The Steam Controller's gyro is reported in [-1, 1] over its full range, taken to be
-- +-2000 degrees per second (as for the Steam Deck). Which axis is which follows SDL's
-- Steam Deck mapping: x pitch, z yaw. Flip the signs here if aiming goes the wrong way.
-- The readings carry a constant offset (one controller read -0.147 on x at rest, about
-- 5 rad/s), so the player tracks it while not aiming, and subtracts it.
--
-- In aim mode the gyro doesn't turn the camera: it tilts the aim a little away from where
-- the right stick points it -- at most GYRO_TILT_MAX radians, GYRO_TILT_GAIN of the
-- controller's own turn -- and the tilt eases back to nothing at GYRO_TILT_RETURN per
-- second, so that drift can't pile up.
local GYRO_RATE = 2000 * math.pi / 180
local GYRO_YAW_AXIS, GYRO_YAW_SIGN = 3, -1
local GYRO_PITCH_AXIS, GYRO_PITCH_SIGN = 1, -1
local GYRO_DEADBAND = 0.0015
local GYRO_BIAS_RATE = 2 -- per second
local GYRO_TILT_GAIN = 0.5
local GYRO_TILT_MAX = { 0.14, 0.1 } -- yaw, pitch: about 8 and 6 degrees
local GYRO_TILT_RETURN = 0.6

local RUN_SPEED, AIM_SPEED = 6.5, 3.0
-- Heavier than the scene's gravity, for snappy jumps: about 1.7 m, and 1.3 m more.
local GRAVITY_SCALE = 1.7
local JUMP_SPEED, DOUBLE_JUMP_SPEED = 7.6, 6.6
local GLIDE_FALL_SPEED = 1.7
local DODGE_SPEED, DODGE_TIME = 11, 0.38
local THROW_SPEED = 32

-- ---------------------------------------------------------------------------------------
-- Vectors and quaternions ({x, y, z, w}), for the camera and the figure
-- ---------------------------------------------------------------------------------------

local function add(a, b) return { a[1] + b[1], a[2] + b[2], a[3] + b[3] } end
local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function scale(a, s) return { a[1] * s, a[2] * s, a[3] * s } end
local function length(a) return math.sqrt(a[1] * a[1] + a[2] * a[2] + a[3] * a[3]) end
local function normalize(a)
    local l = length(a)
    return l > 1e-6 and scale(a, 1 / l) or { 0, 0, 0 }
end
local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local function lerp(a, b, t) return a + (b - a) * t end
-- The fraction of the way to a target to go this frame, for exponential smoothing.
local function approach(rate, dt) return 1 - math.exp(-rate * dt) end
local function wrapAngle(a) return (a + math.pi) % (2 * math.pi) - math.pi end
local function smoothstep(t)
    t = clamp(t, 0, 1)
    return t * t * (3 - 2 * t)
end

local function qaxis(axis, angle)
    local s, c = math.sin(angle / 2), math.cos(angle / 2)
    if axis == "x" then return { s, 0, 0, c } end
    if axis == "y" then return { 0, s, 0, c } end
    return { 0, 0, s, c }
end

local function qmul(a, b)
    return {
        a[4] * b[1] + a[1] * b[4] + a[2] * b[3] - a[3] * b[2],
        a[4] * b[2] - a[1] * b[3] + a[2] * b[4] + a[3] * b[1],
        a[4] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[4],
        a[4] * b[4] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
    }
end

local function qrotate(q, v)
    -- v + 2w (q x v) + 2 q x (q x v)
    local tx = 2 * (q[2] * v[3] - q[3] * v[2])
    local ty = 2 * (q[3] * v[1] - q[1] * v[3])
    local tz = 2 * (q[1] * v[2] - q[2] * v[1])
    return {
        v[1] + q[4] * tx + q[2] * tz - q[3] * ty,
        v[2] + q[4] * ty + q[3] * tx - q[1] * tz,
        v[3] + q[4] * tz + q[1] * ty - q[2] * tx,
    }
end

-- A frame of the figure: a position and a rotation. child() makes one relative to it.
local function child(frame, offset, rotation)
    return { p = add(frame.p, qrotate(frame.q, offset)), q = rotation and qmul(frame.q, rotation) or frame.q }
end

-- Rotations of the arms and legs: about x (raise forward; a leg's positive angle swings it
-- back), then about y (sweep toward the character's right) and z (out to the side).
local function limb(raise, sweep, out)
    return qmul(qaxis("y", sweep or 0), qmul(qaxis("z", out or 0), qaxis("x", -raise)))
end

-- The direction the camera looks for a yaw (0: +z; increasing toward +x, the screen's
-- right) and a pitch (positive: looking down).
local function lookDirection(yaw, pitch)
    local cp = math.cos(pitch)
    return { math.sin(yaw) * cp, -math.sin(pitch), math.cos(yaw) * cp }
end

-- ---------------------------------------------------------------------------------------

return function(world, options)
    local player = {}
    local spawn = options.spawn or { 0, 0.05, -5 }
    local targets = options.targets       -- body groups the attacks hit
    local projectiles = options.projectiles -- the group thrown balls go into

    local character
    local parts, round      -- the figure's groups: boxes, spheres
    local controller = input.controller()

    -- State of the character.
    local state = {
        yaw = 0,                -- the way it faces
        velocity = { 0, 0 },    -- horizontal velocity it is steering
        jumps = 0,              -- jumps since it last stood on the ground
        lastGround = 0,         -- time it last stood on the ground
        jumpLock = 0,           -- after a jump: not grounded yet whatever the host says
        gliding = false,
        dodge = nil,            -- { t, dir }
        attack = nil,           -- { kind, t, duration, hit, queued }
        flip = nil,             -- seconds into a double jump's flip
        land = 0,               -- landing squash, seconds left
        throwAnim = 0,
        throwCooldown = 0,
        aiming = false,
        phase = 0,              -- walk cycle
        fallSpeed = 0,
        time = 0,
    }

    -- State of the camera.
    local camera = {
        yaw = 0, pitch = 0.32, distance = 5.2, fovY = math.rad(55),
        pivot = nil, aim = 0, idle = 0, shake = 0, pullIn = 5.2,
        tilt = { 0, 0 }, -- the gyro's, in aim mode: yaw, pitch
        spread = 0, hot = 0,
        eye = { 0, 2, -10 }, forward = { 0, 0, 1 },
    }

    -- Input this frame: axes polled, presses queued by the callbacks.
    local pressed = {}
    local keyboardLook = { 0, 0 }
    local triggers = { left = false, right = false }

    -- ------------------------------------------------------------------------------------
    -- The figure
    -- ------------------------------------------------------------------------------------

    local ARMOR = { 0.24, 0.26, 0.3 }
    local DARK = { 0.14, 0.14, 0.16 }
    local RED = { 0.62, 0.1, 0.07 }
    local GOLD = { 0.8, 0.6, 0.25 }
    local STEEL = { 0.78, 0.8, 0.84 }
    local GLOW = { 1.0, 0.75, 0.3 }

    -- Box parts: name, half extents, color. Their placement is computed in pose().
    local BOX_PARTS = {
        { "legL", { 0.085, 0.44, 0.095 }, DARK }, { "legR", { 0.085, 0.44, 0.095 }, DARK },
        { "footL", { 0.085, 0.05, 0.14 }, ARMOR }, { "footR", { 0.085, 0.05, 0.14 }, ARMOR },
        { "belt", { 0.22, 0.05, 0.15 }, GOLD },
        { "abdomen", { 0.2, 0.17, 0.13 }, DARK },
        { "chest", { 0.27, 0.18, 0.16 }, ARMOR },
        { "head", { 0.12, 0.13, 0.13 }, ARMOR },
        { "visor", { 0.085, 0.018, 0.012 }, GLOW },
        { "hornL", { 0.025, 0.13, 0.025 }, GOLD }, { "hornR", { 0.025, 0.13, 0.025 }, GOLD },
        { "pauldronL", { 0.15, 0.09, 0.17 }, RED }, { "pauldronR", { 0.17, 0.11, 0.18 }, RED },
        { "armL", { 0.075, 0.3, 0.075 }, DARK }, { "armR", { 0.075, 0.3, 0.075 }, DARK },
        { "gauntletL", { 0.085, 0.08, 0.085 }, ARMOR }, { "gauntletR", { 0.085, 0.08, 0.085 }, ARMOR },
        { "cape", { 0.17, 0.34, 0.015 }, RED },
        { "grip", { 0.024, 0.11, 0.024 }, DARK },
        { "guard", { 0.15, 0.028, 0.04 }, GOLD },
        { "blade", { 0.022, 0.62, 0.085 }, STEEL },
    }
    local partIndex = {}

    local function createFigure()
        parts = world:group { capacity = #BOX_PARTS }
        for i, part in ipairs(BOX_PARTS) do
            parts:add { motion = "visual", shape = "box", half_extents = part[2], color = part[3] }
            partIndex[part[1]] = i - 1
        end
        round = world:group { capacity = 1 }
        round:add { motion = "visual", shape = "sphere", radius = 0.1, color = GLOW, pattern = 1 }
        -- For the scene's draws: the boxes with the cube mesh, the sphere with the ball.
        player.parts, player.round = parts, round
    end

    local function place(name, frame, offset)
        parts:set_transform(partIndex[name], add(frame.p, qrotate(frame.q, offset or { 0, 0, 0 })), frame.q)
    end

    -- Where the attack has the sword arm, `p` of the way through it: the sweep and raise of
    -- the arm, the sword's tilt from the arm, and the body's twist and lean.
    local SWINGS = {
        -- Forehand: from the right across to the left.
        slash1 = { from = { sweep = 1.7, raise = 1.5, tilt = -0.15 }, to = { sweep = -1.4, raise = 1.35, tilt = -0.1 } },
        -- Backhand: back from the left to the right.
        slash2 = { from = { sweep = -1.4, raise = 1.2, tilt = -0.1 }, to = { sweep = 1.7, raise = 1.35, tilt = -0.15 } },
        -- Overhead: from high behind down in front.
        slash3 = { from = { sweep = 0.15, raise = 3.4, tilt = -0.2 }, to = { sweep = 0.1, raise = 0.75, tilt = -0.4 } },
        -- Launcher: from low in front up over the head.
        launch = { from = { sweep = 0.25, raise = 0.2, tilt = -0.3 }, to = { sweep = 0.1, raise = 3.0, tilt = -0.2 } },
        -- Plunge: held overhead while falling, down on landing.
        plunge = { from = { sweep = 0.1, raise = 3.2, tilt = -0.1 }, to = { sweep = 0.1, raise = 0.8, tilt = -0.5 } },
    }

    local function swingPose(attack, idle)
        local swing = SWINGS[attack.kind]
        local p = attack.t / attack.duration
        if attack.kind == "plunge" then
            p = attack.landed and 0.25 + 0.75 * (attack.t - attack.landed) / 0.35 or 0.2
        end
        local function mix(a, b, t)
            return { sweep = lerp(a.sweep, b.sweep, t), raise = lerp(a.raise, b.raise, t), tilt = lerp(a.tilt, b.tilt, t) }
        end
        if p < 0.25 then return mix(idle, swing.from, smoothstep(p / 0.25)) end      -- wind up
        if p < 0.5 then return mix(swing.from, swing.to, 1 - (1 - (p - 0.25) / 0.25) ^ 3) end -- strike
        if p < 0.7 then return swing.to end                                           -- follow through
        return mix(swing.to, idle, smoothstep((p - 0.7) / 0.3))                        -- recover
    end

    local function pose(feet, dt)
        local speed = math.sqrt(state.velocity[1] ^ 2 + state.velocity[2] ^ 2)
        local run = clamp(speed / RUN_SPEED, 0, 1)
        local airborne = not state.grounded
        state.phase = state.phase + dt * (2.2 + speed * 1.45)
        local stride = math.sin(state.phase)

        -- The hips: bob with the stride, squash on landing, lower in a roll.
        local hipY = 0.95 - math.abs(math.cos(state.phase)) * 0.06 * run + 0.03 * run
        if state.land > 0 then hipY = hipY - 0.14 * (state.land / 0.18) end
        local roll = 0
        local tuck = 0
        if state.dodge then
            local p = state.dodge.t / DODGE_TIME
            roll = 2 * math.pi * smoothstep(p)
            tuck = math.sin(math.pi * p)
            hipY = hipY - 0.35 * tuck
        elseif state.flip then
            local p = state.flip / 0.42
            roll = 2 * math.pi * smoothstep(p)
            tuck = math.sin(math.pi * clamp(p, 0, 1))
        end
        -- A roll turns about the body's middle, not the hips.
        local facing = qaxis("y", state.yaw)
        local hips = { p = add(feet, { 0, hipY, 0 }), q = facing }
        if roll ~= 0 then
            local middle = { p = add(feet, { 0, hipY + 0.05, 0 }), q = qmul(facing, qaxis("x", roll)) }
            hips = child(middle, { 0, -0.05, 0 })
        end

        -- Legs: a stride when running, tucked in a roll or a flip, one forward in the air.
        local swingL, swingR = stride * 0.75 * run, -stride * 0.75 * run
        if airborne and not state.gliding then
            local up = clamp(state.fallSpeed / 6, -1, 1)
            swingL, swingR = -0.6 + 0.2 * up, 0.3 - 0.2 * up
        elseif state.gliding then
            swingL, swingR = 0.35, 0.45
        end
        swingL = lerp(swingL, -1.4, tuck)
        swingR = lerp(swingR, -1.4, tuck)
        for side, angle in pairs { L = swingL, R = swingR } do
            local x = side == "L" and -0.13 or 0.13
            local leg = child(hips, { x, 0, 0 }, qaxis("x", angle))
            place("leg" .. side, leg, { 0, -0.44, 0 })
            place("foot" .. side, leg, { 0, -0.86, 0.06 })
        end

        -- The body: leans into the run (and into a glide), twists with a swing.
        local swingArm = { sweep = 0.12, raise = -stride * 0.55 * run, tilt = -1.15 }
        if airborne then swingArm = { sweep = 0.2, raise = 0.5, tilt = -0.9 } end
        local twist, lean = 0, 0.12 * run
        if state.attack then
            swingArm = swingPose(state.attack, swingArm)
            twist = swingArm.sweep * 0.3
            lean = lean + (state.attack.kind == "slash3" and 0.25 or 0.08)
        end
        if state.gliding then lean = 0.55 end
        if state.aiming then lean, twist = 0.05, -0.25 end
        local torso = child(hips, { 0, 0, 0 }, qmul(qaxis("y", twist), qaxis("x", lean)))
        place("belt", torso, { 0, 0.02, 0 })
        place("abdomen", torso, { 0, 0.16, 0 })
        place("chest", torso, { 0, 0.46, 0.01 })

        -- The head: looks where the camera aims, in aim mode.
        local headTurn = state.aiming and qaxis("x", clamp(camera.pitch, -0.6, 0.6) * 0.7) or nil
        local head = child(torso, { 0, 0.66, 0 }, headTurn)
        place("head", head, { 0, 0.12, 0 })
        place("visor", head, { 0, 0.13, 0.125 })
        for side, sign in pairs { L = -1, R = 1 } do
            local horn = child(head, { 0.1 * sign, 0.2, -0.02 }, qmul(qaxis("z", -0.55 * sign), qaxis("x", -0.45)))
            place("horn" .. side, horn, { 0, 0.1, 0 })
            local pauldron = child(torso, { 0.34 * sign, 0.6, 0 }, qaxis("z", -0.32 * sign))
            place("pauldron" .. side, pauldron)
        end

        -- The cape: hangs from the shoulders, streams back with speed and in the air.
        local capeAngle = 0.12 + 0.55 * run + (airborne and 0.5 or 0) + math.sin(state.time * 9) * 0.06 * (run + 0.3)
        if state.gliding then capeAngle = 1.2 + math.sin(state.time * 14) * 0.08 end
        local cape = child(torso, { 0, 0.6, -0.18 }, qaxis("x", capeAngle))
        place("cape", cape, { 0, -0.34, 0 })

        -- The arms. Left: swings, spreads in a glide, points at the crosshair in aim mode.
        local leftQ
        if state.aiming or state.throwAnim > 0 then
            local raise = math.pi / 2 - (state.aiming and camera.pitch or 0.1)
            if state.throwAnim > 0 then raise = raise + 0.4 * state.throwAnim / 0.15 end
            leftQ = limb(raise, state.aiming and 0.25 or 0, 0)
        elseif state.gliding then
            leftQ = limb(0.2, 0, -1.35)
        else
            leftQ = limb(stride * 0.55 * run + (airborne and 0.6 or 0), 0, -0.12 - (airborne and 0.5 or 0))
        end
        local armL = child(torso, { -0.33, 0.55, 0 }, leftQ)
        place("armL", armL, { 0, -0.3, 0 })
        place("gauntletL", armL, { 0, -0.6, 0 })
        local hand = child(armL, { 0, -0.7, 0 })
        state.leftHand = hand.p
        local orb = state.aiming and 0.09 + 0.015 * math.sin(state.time * 12) or 0.0001
        round:set_transform(0, hand.p, hand.q, { orb, orb, orb })

        -- Right: holds the sword.
        local rightQ = state.gliding and limb(0.2, 0, 1.35) or limb(swingArm.raise, swingArm.sweep, 0.12)
        local armR = child(torso, { 0.33, 0.55, 0 }, rightQ)
        place("armR", armR, { 0, -0.3, 0 })
        place("gauntletR", armR, { 0, -0.6, 0 })
        local sword = child(armR, { 0, -0.64, 0 }, qaxis("x", state.gliding and -1.4 or swingArm.tilt))
        place("grip", sword, { 0, 0.02, 0 })
        place("guard", sword, { 0, -0.11, 0 })
        place("blade", sword, { 0, -0.75, 0 })
    end

    -- ------------------------------------------------------------------------------------
    -- Combat
    -- ------------------------------------------------------------------------------------

    -- Calls fn(group, i, offset, distance) for every target body within `radius` of
    -- `center`, and in front of the character if `cone` (cosine of the half angle) is given.
    local function forBodiesNear(center, radius, cone, fn)
        local forward = { math.sin(state.yaw), 0, math.cos(state.yaw) }
        local hits = 0
        for _, group in ipairs(targets) do
            for i = 0, group.count - 1 do
                local x, y, z = group:position(i)
                local offset = { x - center[1], y - center[2], z - center[3] }
                local d = length(offset)
                if d < radius then
                    local flat = normalize({ offset[1], 0, offset[3] })
                    if not cone or d < 0.35 or flat[1] * forward[1] + flat[3] * forward[3] > cone then
                        fn(group, i, offset, d)
                        hits = hits + 1
                    end
                end
            end
        end
        return hits
    end

    local function strike(kind, feet)
        local chest = add(feet, { 0, 1.1, 0 })
        local forward = { math.sin(state.yaw), 0, math.cos(state.yaw) }
        local right = { forward[3], 0, -forward[1] }
        local hits
        if kind == "slash1" or kind == "slash2" then
            -- Out and along the swing: a forehand sends things to the left, a backhand right.
            local across = kind == "slash1" and -1 or 1
            hits = forBodiesNear(chest, 2.4, -0.2, function(group, i, offset)
                local out = normalize({ offset[1], 0, offset[3] })
                group:set_velocity(i, add(add(scale(out, 6.5), scale(right, 3.5 * across)), { 0, 2.8, 0 }))
            end)
        elseif kind == "slash3" then
            local center = add(feet, add(scale(forward, 1.3), { 0, 0.3, 0 }))
            hits = forBodiesNear(center, 2.2, nil, function(group, i, offset, d)
                local out = normalize({ offset[1], 0, offset[3] })
                local k = 1 - d / 2.2
                group:set_velocity(i, add(scale(out, 4 + 5 * k), { 0, 3 + 5 * k, 0 }))
            end)
            camera.shake = math.max(camera.shake, 0.35)
        elseif kind == "launch" then
            hits = forBodiesNear(chest, 2.3, 0.1, function(group, i, offset)
                local out = normalize({ offset[1], 0, offset[3] })
                group:set_velocity(i, add(scale(out, 1.2), { 0, 10.5, 0 }))
            end)
        elseif kind == "plunge" then
            hits = forBodiesNear(add(feet, { 0, 0.3, 0 }), 3.6, nil, function(group, i, offset, d)
                local out = normalize({ offset[1], 0, offset[3] })
                local k = 1 - d / 3.6
                group:set_velocity(i, add(scale(out, 3 + 8 * k), { 0, 2 + 8 * k, 0 }))
            end)
            camera.shake = math.max(camera.shake, 0.6)
        end
        if hits > 0 then camera.shake = math.max(camera.shake, 0.18) end
    end

    local ATTACKS = {
        slash1 = { duration = 0.36, lunge = 3.5 },
        slash2 = { duration = 0.36, lunge = 3.5 },
        slash3 = { duration = 0.55, lunge = 4.5 },
        launch = { duration = 0.5, lunge = 1.5 },
    }

    local function startAttack(kind)
        local a = ATTACKS[kind]
        state.attack = { kind = kind, t = 0, duration = a and a.duration or 10, lunge = a and a.lunge or 0, hit = false }
    end

    -- X: the next swing of the combo, queued if one is still going.
    local function comboPress()
        local a = state.attack
        if not state.grounded and not a then
            startAttack("plunge")
            character.velocity = { 0, -17, 0 }
            return
        end
        if not a then
            startAttack("slash1")
        elseif a.t / a.duration > 0.3 and (a.kind == "slash1" or a.kind == "slash2") then
            a.queued = a.kind == "slash1" and "slash2" or "slash3"
        end
    end

    local function throw(feet)
        local forward = { math.sin(state.yaw), 0, math.cos(state.yaw) }
        local origin = state.leftHand or add(feet, { 0, 1.3, 0 })
        origin = add(origin, scale(forward, 0.25))
        local dir
        if state.aiming then
            -- At whatever is under the crosshair: cast from the camera, then aim from the hand.
            local distance, point = world:raycast(camera.eye, camera.forward, 120)
            local target = distance and point or add(camera.eye, scale(camera.forward, 120))
            dir = normalize(sub(target, origin))
        else
            dir = normalize(add(forward, { 0, 0.1, 0 }))
        end
        projectiles:add {
            shape = "sphere", radius = 0.15, density = 3500, restitution = 0.3, friction = 0.4,
            position = origin, velocity = scale(dir, THROW_SPEED),
            color = { 1.0, 0.55, 0.15 }, pattern = 1,
        }
        state.throwAnim = 0.15
        state.throwCooldown = 0.16
        camera.spread = 8
    end

    -- ------------------------------------------------------------------------------------
    -- Input
    -- ------------------------------------------------------------------------------------

    local function deadzone(x, y)
        local m = math.sqrt(x * x + y * y)
        if m < AXIS_DEADZONE then return 0, 0, 0 end
        local k = math.min(1, (m - AXIS_DEADZONE) / (1 - AXIS_DEADZONE)) / m
        return x * k, y * k, math.min(1, m * k)
    end

    local function keyAxis(negative, positive)
        return (input.key_down(positive) and 1 or 0) - (input.key_down(negative) and 1 or 0)
    end

    -- Sticks, triggers and the keyboard, as move and look axes and held buttons.
    local function readInput()
        local i = { moveX = 0, moveY = 0, lookX = 0, lookY = 0, jumpHeld = false, throwHeld = false, gyro = nil }
        if controller.connected then
            local ls, rs = controller.left_stick, controller.right_stick
            i.moveX, i.moveY = deadzone(ls[1], ls[2])
            local lx, ly = deadzone(rs[1], rs[2])
            -- A response curve: fine near the center, fast at the edge.
            i.lookX, i.lookY = lx * math.abs(lx) ^ 0.6, ly * math.abs(ly) ^ 0.6
            i.jumpHeld = controller:button(buttons.A)
            -- The triggers, as buttons with some hysteresis.
            local lt, rt = controller.left_trigger, controller.right_trigger
            local left = lt > 0.55 or (triggers.left and lt > 0.35)
            local right = rt > 0.55 or (triggers.right and rt > 0.35)
            if left and not triggers.left then pressed.recenter = true end
            if right and not triggers.right then pressed.throw = true end
            triggers.left, triggers.right = left, right
            i.throwHeld = right
            -- The right trackpad drags the camera like a mouse.
            local pad = controller.right_pad
            if controller:button(buttons.RightPadTouch) then
                if camera.padLast then
                    i.padX, i.padY = pad[1] - camera.padLast[1], pad[2] - camera.padLast[2]
                end
                camera.padLast = { pad[1], pad[2] }
            else
                camera.padLast = nil
            end
            -- The gyro, less its offset, which follows the readings while not aiming.
            local gyro = controller.gyro
            camera.gyroBias = camera.gyroBias or { gyro[1], gyro[2], gyro[3] }
            if not state.aiming then
                local k = approach(GYRO_BIAS_RATE, camera.lastDt or 0)
                for a = 1, 3 do camera.gyroBias[a] = lerp(camera.gyroBias[a], gyro[a], k) end
            end
            i.gyro = { gyro[1] - camera.gyroBias[1], gyro[2] - camera.gyroBias[2], gyro[3] - camera.gyroBias[3] }
        end
        local kx, ky = keyAxis(keys.A, keys.D), keyAxis(keys.S, keys.W)
        if kx ~= 0 or ky ~= 0 then
            local m = math.sqrt(kx * kx + ky * ky)
            i.moveX, i.moveY = kx / m, ky / m
        end
        i.jumpHeld = i.jumpHeld or input.key_down(keys.SPACE)
        i.throwHeld = i.throwHeld or input.key_down(keys.E)
        return i
    end

    -- ------------------------------------------------------------------------------------
    -- The camera
    -- ------------------------------------------------------------------------------------

    local function updateCamera(feet, i, dt)
        -- Turning: the right stick, the right pad and the mouse; in aim mode, slower.
        local aimRate = lerp(1, 0.45, camera.aim)
        local looking = i.lookX ~= 0 or i.lookY ~= 0 or i.padX or keyboardLook[1] ~= 0 or keyboardLook[2] ~= 0
        camera.yaw = camera.yaw + i.lookX * 3.0 * aimRate * dt
        camera.pitch = camera.pitch - i.lookY * 2.0 * aimRate * dt
        if i.padX then
            camera.yaw = camera.yaw + i.padX * 2.2 * aimRate
            camera.pitch = camera.pitch - i.padY * 1.6 * aimRate
        end
        camera.yaw = camera.yaw + keyboardLook[1]
        camera.pitch = camera.pitch + keyboardLook[2]
        keyboardLook = { 0, 0 }
        -- The gyro's tilt, in aim mode: added to the stick's aim, bounded, easing back.
        local tilt = camera.tilt
        if state.aiming and i.gyro then
            local rates = { i.gyro[GYRO_YAW_AXIS] * GYRO_YAW_SIGN, i.gyro[GYRO_PITCH_AXIS] * GYRO_PITCH_SIGN }
            for a = 1, 2 do
                if math.abs(rates[a]) > GYRO_DEADBAND then
                    tilt[a] = tilt[a] + rates[a] * GYRO_RATE * GYRO_TILT_GAIN * dt
                end
            end
        end
        local settle = approach(state.aiming and GYRO_TILT_RETURN or 10, dt)
        for a = 1, 2 do
            tilt[a] = clamp(tilt[a] * (1 - settle), -GYRO_TILT_MAX[a], GYRO_TILT_MAX[a])
        end
        camera.pitch = clamp(camera.pitch, -0.75, 1.15)

        -- Swinging behind the character on its own: when the player runs and leaves the
        -- camera alone for a moment, it eases round to look the way the character goes.
        camera.idle = looking and 0 or camera.idle + dt
        local speed = math.sqrt(state.velocity[1] ^ 2 + state.velocity[2] ^ 2)
        if camera.recenter then
            local delta = wrapAngle(state.yaw - camera.yaw)
            camera.yaw = camera.yaw + delta * approach(10, dt)
            camera.pitch = lerp(camera.pitch, 0.3, approach(10, dt))
            if math.abs(delta) < 0.02 then camera.recenter = false end
        elseif not state.aiming and camera.idle > 0.7 and speed > 1.5 and state.grounded then
            local delta = wrapAngle(state.yaw - camera.yaw)
            -- Only when running across or away: running at the camera doesn't spin it round.
            if math.abs(delta) < 2.2 then
                camera.yaw = camera.yaw + delta * approach(0.9 * speed / RUN_SPEED, dt)
            end
            camera.pitch = lerp(camera.pitch, 0.3, approach(0.6, dt))
        end

        -- Aim mode blends the camera over the right shoulder.
        camera.aim = lerp(camera.aim, state.aiming and 1 or 0, approach(12, dt))
        local forward = lookDirection(camera.yaw + tilt[1], camera.pitch + tilt[2])
        local right = normalize({ forward[3], 0, -forward[1] })
        local distance = lerp(camera.distance, 2.7, camera.aim)
        local wanted = add(add(feet, { 0, lerp(1.5, 1.65, camera.aim), 0 }), scale(right, 0.8 * camera.aim))

        -- The pivot trails the character: closely sideways, loosely up and down, so jumps
        -- don't bob the view.
        if not camera.pivot then camera.pivot = wanted end
        local side = approach(lerp(14, 30, camera.aim), dt)
        local up = approach(lerp(state.grounded and 8 or 3, 30, camera.aim), dt)
        camera.pivot = {
            lerp(camera.pivot[1], wanted[1], side),
            lerp(camera.pivot[2], wanted[2], up),
            lerp(camera.pivot[3], wanted[3], side),
        }
        -- Not below the character's hips, even when it falls fast.
        camera.pivot[2] = math.max(camera.pivot[2], feet[2] + 0.9)

        -- Pulled in in front of whatever is between the character and the camera; eased
        -- back out.
        local back = scale(forward, -1)
        local hit = world:raycast(camera.pivot, back, distance + 0.3)
        local allowed = hit and math.max(0.5, hit - 0.3) or distance
        camera.pullIn = allowed < camera.pullIn and allowed or lerp(camera.pullIn, allowed, approach(3, dt))

        -- Shake, after hits; decays fast.
        camera.shake = math.max(0, camera.shake - dt * 1.6)
        local s = camera.shake * camera.shake * 0.25
        local shake = { (math.random() - 0.5) * s, (math.random() - 0.5) * s, (math.random() - 0.5) * s }

        camera.eye = add(add(camera.pivot, scale(back, camera.pullIn)), shake)
        camera.forward = forward
        camera.fovY = math.rad(lerp(55, 42, camera.aim))

        -- The crosshair turns hot over things that can move.
        if state.aiming then
            local d, _, _, moving = world:raycast(camera.eye, forward, 120)
            camera.hot = (d and moving) and 1 or 0
        end
        camera.spread = math.max(0, camera.spread - dt * 50)
    end

    -- ------------------------------------------------------------------------------------
    -- Each frame
    -- ------------------------------------------------------------------------------------

    function player.update(dt)
        dt = math.min(dt, 1 / 20)
        camera.lastDt = dt
        state.time = state.time + dt
        local i = readInput()
        local feet = character.position
        local velocity = character.velocity
        state.fallSpeed = velocity[2]

        -- On the ground? Not right after a jump, whatever the last physics step says.
        state.jumpLock = math.max(0, state.jumpLock - dt)
        local wasGrounded = state.grounded
        state.grounded = character.on_ground and state.jumpLock == 0
        if state.grounded then
            state.lastGround = state.time
            state.jumps = 0
            state.gliding = false
            if not wasGrounded and state.lastFall and state.lastFall < -4 then state.land = 0.18 end
        end
        state.lastFall = velocity[2]
        state.land = math.max(0, state.land - dt)

        -- Fell off the world: back to the start.
        if feet[2] < -15 then player.reset() return end

        -- Presses, in the order of importance.
        if pressed.aim then state.aiming = not state.aiming end
        if pressed.recenter then camera.recenter = true end
        if pressed.dodge and not state.dodge and state.grounded then
            local dir
            if i.moveX ~= 0 or i.moveY ~= 0 then
                local f = { math.sin(camera.yaw), 0, math.cos(camera.yaw) }
                local r = { f[3], 0, -f[1] }
                dir = normalize(add(scale(r, i.moveX), scale(f, i.moveY)))
            else
                dir = { math.sin(state.yaw), 0, math.cos(state.yaw) }
            end
            state.dodge = { t = 0, dir = dir }
            state.attack = nil
            state.aiming = false
            state.yaw = math.atan(dir[1], dir[3])
        end
        if pressed.jump and not state.dodge then
            local coyote = state.time - state.lastGround < 0.12
            if state.grounded or (coyote and state.jumps == 0) then
                character:jump(JUMP_SPEED)
                state.jumps = 1
                state.jumpLock = 0.15
                state.grounded = false
            elseif state.jumps < 2 then
                character:jump(DOUBLE_JUMP_SPEED)
                state.jumps = 2
                state.jumpLock = 0.15
                state.flip = 0
            end
            if state.attack and state.attack.kind ~= "plunge" then state.attack = nil end
        end
        if pressed.combo and not state.dodge and not state.aiming then comboPress() end
        if pressed.launch and not state.dodge and not state.aiming and state.grounded and not state.attack then
            startAttack("launch")
        end
        state.throwCooldown = math.max(0, state.throwCooldown - dt)
        local wantThrow = pressed.throw or (state.aiming and i.throwHeld and state.throwCooldown == 0)
        if wantThrow and not state.dodge and not state.attack and state.throwCooldown == 0 then throw(feet) end
        pressed = {}

        -- Gliding: holding jump while falling after a double jump.
        state.gliding = not state.grounded and state.jumps >= 2 and i.jumpHeld and velocity[2] < 0
            and not state.attack and not state.flip
        character.max_fall_speed = state.gliding and GLIDE_FALL_SPEED or 0

        -- Movement, relative to the camera.
        local f = { math.sin(camera.yaw), 0, math.cos(camera.yaw) }
        local r = { f[3], 0, -f[1] }
        local wish = add(scale(r, i.moveX), scale(f, i.moveY))
        local amount = math.min(1, length(wish))
        local topSpeed = state.aiming and AIM_SPEED or RUN_SPEED * (state.gliding and 1.15 or 1)
        local target = scale(amount > 0 and normalize(wish) or { 0, 0, 0 }, topSpeed * amount)

        local a = state.attack
        if a then
            a.t = a.t + dt
            local forward = { math.sin(state.yaw), 0, math.cos(state.yaw) }
            if a.kind == "plunge" then
                target = { 0, 0, 0 }
                if state.grounded and not a.landed then
                    a.landed = a.t
                    strike("plunge", feet)
                end
                if a.landed and a.t - a.landed > 0.35 then state.attack = nil end
            else
                -- A short lunge into each swing; little steering during it.
                local p = a.t / a.duration
                local lunge = (p > 0.2 and p < 0.45) and a.lunge or 0
                target = add(scale(target, 0.15), scale(forward, lunge))
                if not a.hit and p >= 0.4 then
                    a.hit = true
                    strike(a.kind, feet)
                end
                if p >= 1 or (a.queued and p >= 0.62) then
                    local nextKind = a.queued
                    state.attack = nil
                    if nextKind then
                        -- Turn to where the stick points, between swings.
                        if amount > 0.3 then state.yaw = math.atan(wish[1], wish[3]) end
                        startAttack(nextKind)
                    end
                end
            end
        end

        if state.dodge then
            state.dodge.t = state.dodge.t + dt
            local p = state.dodge.t / DODGE_TIME
            target = scale(state.dodge.dir, DODGE_SPEED * (1 - 0.6 * p))
            if p >= 1 then state.dodge = nil end
        end
        if state.flip then
            state.flip = state.flip + dt
            if state.flip > 0.42 then state.flip = nil end
        end

        -- Steering: quick on the ground, sluggish in the air.
        local accel = state.dodge and 80 or (state.grounded and 45 or 14)
        local dv = { target[1] - state.velocity[1], target[3] - state.velocity[2] }
        local dl = math.sqrt(dv[1] ^ 2 + dv[2] ^ 2)
        local step = accel * dt
        if dl > step then dv = { dv[1] / dl * step, dv[2] / dl * step } end
        state.velocity = { state.velocity[1] + dv[1], state.velocity[2] + dv[2] }
        character.move = state.velocity

        -- Facing: where it runs, or where the camera aims.
        local wantYaw
        if state.aiming then
            wantYaw = camera.yaw
        elseif not state.attack and not state.dodge and amount > 0.1 then
            wantYaw = math.atan(wish[1], wish[3])
        end
        if wantYaw then
            local delta = wrapAngle(wantYaw - state.yaw)
            local turn = (state.aiming and 20 or 13) * dt
            state.yaw = wrapAngle(state.yaw + clamp(delta, -turn, turn))
        end

        state.throwAnim = math.max(0, state.throwAnim - dt)
        updateCamera(feet, i, dt)
        pose(feet, dt)
    end

    -- The camera, for the scene's camera block: { eye, target, fovY }.
    function player.camera()
        return { eye = camera.eye, target = add(camera.eye, camera.forward), fovY = camera.fovY }
    end

    function player.aiming() return state.aiming end
    function player.position() return character.position end
    function player.crosshair() return camera.hot, camera.spread end

    function player.describe()
        local where = state.dodge and "dodging" or state.gliding and "gliding" or state.grounded and "on the ground" or "in the air"
        return string.format("%s%s, %s", state.aiming and "AIMING, " or "", where,
            controller.connected and "Steam Controller" or "no controller: keyboard")
    end

    -- ------------------------------------------------------------------------------------
    -- Setup and events
    -- ------------------------------------------------------------------------------------

    function player.init()
        character = world:character { radius = 0.35, height = 1.85, position = spawn, mass = 110, strength = 900 }
        createFigure()
        pose(spawn, 0)
        player.reset()
    end

    function player.reset()
        character.position = spawn
        character.velocity = { 0, 0, 0 }
        character.move = { 0, 0 }
        character.max_fall_speed = 0
        character.gravity_scale = GRAVITY_SCALE
        pressed = {}
        state.yaw, state.velocity = 0, { 0, 0 }
        state.attack, state.dodge, state.flip, state.aiming, state.gliding = nil, nil, nil, false, false
        camera.yaw, camera.pitch, camera.pivot, camera.recenter = 0, 0.3, nil, false
        camera.eye, camera.forward = add(spawn, { 0, 3, -5 }), normalize({ 0, -0.4, 1 })
        pose(spawn, 0)
    end

    local BUTTONS = {
        [buttons.A] = "jump", [buttons.B] = "dodge", [buttons.X] = "combo", [buttons.Y] = "launch",
        [buttons.R3] = "aim",
    }
    -- Returns true if the button was the player's.
    function player.on_controller_button(slot, button, pressedNow)
        local action = BUTTONS[button]
        if action and pressedNow then pressed[action] = true end
        return action ~= nil
    end

    local KEYS = {
        [keys.SPACE] = "jump", [keys.LEFT_SHIFT] = "dodge", [keys.F] = "combo", [keys.G] = "launch",
        [keys.Q] = "aim", [keys.E] = "throw", [keys.C] = "recenter",
    }
    function player.on_key(key, action)
        local name = KEYS[key]
        if name and action == input.PRESS then pressed[name] = true end
        return name ~= nil
    end

    -- Forgets presses not acted on yet (e.g. while the scene wasn't showing).
    function player.clear_input()
        pressed = {}
        triggers.left, triggers.right = false, false
    end

    function player.look(dx, dy)
        keyboardLook = { keyboardLook[1] + dx, keyboardLook[2] + dy }
    end

    function player.zoom(steps)
        camera.distance = clamp(camera.distance - steps * 0.5, 2.5, 10)
    end

    return player
end
