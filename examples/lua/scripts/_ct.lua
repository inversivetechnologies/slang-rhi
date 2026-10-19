config = { title = "compile times" }
local list = {
    { "gi/gbuffer.slang", "gbufferMain" }, { "gi/global-sdf-bake.slang", "bodiesMain" },
    { "gi/global-sdf-bake.slang", "compositionMain" }, { "gi/ddgi-update.slang", "traceMain" },
    { "gi/ddgi-update.slang", "irradianceMain" }, { "gi/rc.slang", "cascadeMain" }, { "gi/rc.slang", "integrateMain" },
    { "post/taa.slang", "taaMain" }, { "post/ssao.slang", "effectsMain" },
}
function init()
    for _, e in ipairs(list) do
        local t0 = rhi.time()
        local p = rhi.compute_pipeline(e[1], e[2])
        print(string.format("%-28s %-16s %6.1f s  built=%s", e[1], e[2], rhi.time() - t0, tostring(p.built)))
    end
    rhi.quit()
end
