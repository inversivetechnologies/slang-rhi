-- Gaussian splats: a PLY file of 3D Gaussians (lib/splat-mode.lua's renderer: levels of
-- detail held to a budget, lighting and shadows both ways, clipping), drawn in every view.
--
--   "splat": { "file": "skull.ply",
--              "fit": 0 (as the file has it) or a radius to scale the splats to,
--              "grid": [nx, nz], "spacing": 4, "turn": 0 (degrees per copy) -- copies,
--              "clip": { "mode": "carve" | "keep",
--                        "shapes": [ { "sphere": r } or { "box": [w, h, d] },
--                                    with "position", "move" ([x, y, z]: to either side),
--                                    "speed" (radians per second), "spin" (a box's) ] } }
--
-- The entity's position is where the splats' center goes, its yaw turns them about it
-- (splats only turn about the vertical), its scale scales them. Entities with the same file
-- share one renderer and draw as its instances, in one set of passes.

local T = rhi.include("lib/scene/transform.lua")

local system = {
    name = "splat",
    components = {
        splat = {
            file = { "string", nil, true },
            fit = { "number", 0 },
            grid = { "vec2", { 1, 1 } },
            spacing = { "number", 4 },
            turn = { "number", 0 },
            clip = { "object" },
        },
    },
}

-- A clip component's shapes in clip.slang's layout.
local function clipShapes(clip, where)
    local shapes = {}
    for i, s in ipairs(clip.shapes or {}) do
        local p, m = s.position or { 0, 0, 0 }, s.move or { 0, 0, 0 }
        local kind, size
        if s.sphere then
            kind, size = 0, { s.sphere, 0, 0 }
        elseif s.box then
            kind, size = 1, { s.box[1] / 2, s.box[2] / 2, s.box[3] / 2 }
        else
            error(string.format("%s.clip.shapes[%d]: \"sphere\" or \"box\"", where, i), 0)
        end
        shapes[#shapes + 1] = { p[1], p[2], p[3], kind, size[1], size[2], size[3], s.spin or 0, m[1], m[2], m[3], s.speed or 0 }
    end
    return shapes
end

function system.load(ctx)
    local files, order = {}, {}
    for id, splat, transform in ctx.world:query("splat", "transform") do
        local f = files[splat.file]
        if not f then
            f = { file = splat.file, entities = {} }
            files[splat.file] = f
            order[#order + 1] = f
        end
        f.entities[#f.entities + 1] = { id = id, splat = splat, transform = transform }
    end
    if #order == 0 then return end

    for _, f in ipairs(order) do
        f.module = rhi.include("lib/splat-mode.lua")(function() end, f.file)
        f.module.createResources()
        if ctx.settings.splatBudget then f.module.setBudget(ctx.settings.splatBudget) end
        local bounds = f.module.bounds()
        local c = bounds.center
        local list = {}
        for _, e in ipairs(f.entities) do
            local s = e.splat
            local scale = e.transform.scale * (s.fit > 0 and s.fit / bounds.radius or 1)
            local yaw = T.yawOf(e.transform.rotation)
            local nx, nz = math.max(1, math.floor(s.grid[1])), math.max(1, math.floor(s.grid[2]))
            for iz = 0, nz - 1 do
                for ix = 0, nx - 1 do
                    local turn = yaw + math.rad(s.turn) * (iz * nx + ix)
                    local at = T.apply({ position = e.transform.position, rotation = e.transform.rotation, scale = 1 },
                        { (ix - (nx - 1) / 2) * s.spacing, 0, (iz - (nz - 1) / 2) * s.spacing })
                    -- position = where its center goes - its center, scaled and turned.
                    local cy, sy = math.cos(turn), math.sin(turn)
                    local sc = { c[1] * scale, c[2] * scale, c[3] * scale }
                    local turned = { cy * sc[1] + sy * sc[3], sc[2], -sy * sc[1] + cy * sc[3] }
                    list[#list + 1] = { position = { at[1] - turned[1], at[2] - turned[2], at[3] - turned[3] }, yaw = turn, scale = scale }
                end
            end
            if s.clip and not f.clip then
                local mode = s.clip.mode == "keep" and 2 or 1
                f.clip = f.module.clipBlock(mode, clipShapes(s.clip, ctx.world:name(e.id) .. ".splat"))
            end
        end
        f.instances, f.instanceCount = f.module.instanceBlock(list)
    end
    ctx.splats = order
end

function system.shadowFields(ctx)
    if ctx.splats then return { splatShadows = 1 } end
end

-- Shadows: every file's splats, into the light's translucent shadow maps.
function system.addShadowPasses(ctx, graph)
    for i, f in ipairs(ctx.splats or {}) do
        f.module.addShadowPasses(graph, {
            name = "splats " .. f.file,
            light = ctx.light,
            atlas = ctx.shadow.splatAtlas,
            layers = ctx.shadow.splatLayers,
            faceSize = ctx.shadow.faceSize,
            instances = f.instances,
            instanceCount = f.instanceCount,
            clip = f.clip,
            clearMaps = i == 1,
        })
    end
end

-- Into the view's splat targets: lit by the light, shadowed by everything.
function system.addSurfaces(ctx, graph, view)
    for i, f in ipairs(ctx.splats or {}) do
        f.module.addPasses(graph, {
            name = view.name .. ": splats " .. f.file,
            view = { view.block },
            instances = f.instances,
            instanceCount = f.instanceCount,
            clip = f.clip,
            lighting = { ctx.light, ctx.shadowBlock },
            target = view.targets.splatColor,
            clear = i == 1 and { 0, 0, 0, 0 } or nil,
            depthTarget = view.targets.splatDepth,
            depthClear = i == 1,
            budgetScale = view.budgetScale,
        })
    end
end

function system.describe(ctx)
    if not ctx.splats then return nil end
    local n = 0
    for _, f in ipairs(ctx.splats) do n = n + f.instanceCount end
    return string.format("%d splat instances", n)
end

return system
