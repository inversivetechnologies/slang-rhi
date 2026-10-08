// Seconds since start; provided by the host to every draw and dispatch that declares it.
// Its own file, so that shaders including several headers that animate declare it once.

#pragma once

uniform float time;
