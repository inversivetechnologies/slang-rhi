config = { title = "fx", features = { "rasterization" } }
local scenes = rhi.include("lib/scene/scene.lua")
scenes.renderer.taa = true
scenes.renderer.effects = { ao = true, aoMethod = "GTAO", gi = true, giMethod = "Cascades", quality = "Half" }
local sc
function init() sc = scenes.load("scenes/composite.scene") sc:enter() end
local n = 0
function update(t, dt) if n == 2 then rhi.set_display { width = 1600, height = 900 } end sc:update(dt) sc:frame() n = n + 1 if n == 300 then local g = sc.ctx.gi local probes = 0 for _, node in ipairs({}) do end print("COST", "Half", sc:describe():match("GI: [^|]*"), sc:describe():match("raymarched in [%d.]+ ms")) rhi.quit() end end
function on_resize(w, h) sc:layout(w, h) end
