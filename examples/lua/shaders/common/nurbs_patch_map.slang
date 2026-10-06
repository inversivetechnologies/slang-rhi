// ============================================================================
// nurbs_patch_map.slang
//
// Forward and inverse mapping for a single rational bicubic Bezier patch
// (i.e. one Bezier span of a NURBS surface after knot insertion / Bezier
// extraction -- do that decomposition once on the CPU and upload the spans).
//
//   float3 map(float2 uv,  float4 points[16])   parameter space -> world space
//   float2 map(float3 xyz, float4 points[16])   world space -> parameter space
//
// Control points are HOMOGENEOUS: Pw = float4(x*w, y*w, z*w, w).
// Layout is row-major: points[i * 4 + j], i indexes u, j indexes v.
// Parameter domain is [0,1] x [0,1].
// ============================================================================

static const int PATCH_DEG = 3;
static const int PATCH_N   = PATCH_DEG + 1;      // 4
static const int PATCH_CP  = PATCH_N * PATCH_N;  // 16

// Inverse-map tuning ---------------------------------------------------------
static const int   INV_SEED_RES  = 8;      // (N+1)^2 seed samples
static const int   INV_MAX_ITER  = 12;
static const float INV_EPS_POINT = 1e-6f;  // point coincidence
static const float INV_EPS_COS   = 1e-6f;  // orthogonality (cosine)
static const float INV_EPS_PARAM = 1e-7f;  // parameter step
static const float INV_MAX_STEP  = 0.25f;  // Newton damping clamp

// ---------------------------------------------------------------------------
// Cubic Bernstein basis and its first two derivatives.
// ---------------------------------------------------------------------------
float4 bernstein3(float t)
{
    float s = 1.0f - t;
    return float4(s * s * s,
                  3.0f * s * s * t,
                  3.0f * s * t * t,
                  t * t * t);
}

float4 bernstein3_d1(float t)
{
    float s = 1.0f - t;
    return float4(-3.0f * s * s,
                   3.0f * s * (s - 2.0f * t),
                   3.0f * t * (2.0f * s - t),
                   3.0f * t * t);
}

float4 bernstein3_d2(float t)
{
    float s = 1.0f - t;
    return float4( 6.0f * s,
                   6.0f * (3.0f * t - 2.0f),
                   6.0f * (1.0f - 3.0f * t),
                   6.0f * t);
}

// ---------------------------------------------------------------------------
// Homogeneous point evaluation (shared by both maps).
// ---------------------------------------------------------------------------
float4 evalHomogeneous(float2 uv, float4 points[PATCH_CP])
{
    float4 Bu = bernstein3(uv.x);
    float4 Bv = bernstein3(uv.y);

    float4 A = float4(0.0f);
    [ForceUnroll]
    for (int i = 0; i < PATCH_N; ++i)
    {
        [ForceUnroll]
        for (int j = 0; j < PATCH_N; ++j)
            A += (Bu[i] * Bv[j]) * points[i * PATCH_N + j];
    }
    return A;
}

// ===========================================================================
// 1.  map(uv, points) -> xyz
// ===========================================================================
float3 map(float2 uv, float4 points[PATCH_CP])
{
    float4 A = evalHomogeneous(saturate(uv), points);
    return A.xyz / A.w;
}

// ---------------------------------------------------------------------------
// Position + first and second derivatives, with rational quotient rule applied.
// Needed for the Newton iteration in the inverse map.
// ---------------------------------------------------------------------------
struct SurfaceJet
{
    float3 S;
    float3 Su,  Sv;
    float3 Suu, Suv, Svv;
};

SurfaceJet evalJet(float2 uv, float4 points[PATCH_CP])
{
    float4 Bu = bernstein3(uv.x),    Bv = bernstein3(uv.y);
    float4 Du = bernstein3_d1(uv.x), Dv = bernstein3_d1(uv.y);
    float4 Eu = bernstein3_d2(uv.x), Ev = bernstein3_d2(uv.y);

    float4 A   = float4(0.0f), Au  = float4(0.0f), Av  = float4(0.0f);
    float4 Auu = float4(0.0f), Auv = float4(0.0f), Avv = float4(0.0f);

    [ForceUnroll]
    for (int i = 0; i < PATCH_N; ++i)
    {
        [ForceUnroll]
        for (int j = 0; j < PATCH_N; ++j)
        {
            float4 P = points[i * PATCH_N + j];
            A   += (Bu[i] * Bv[j]) * P;
            Au  += (Du[i] * Bv[j]) * P;
            Av  += (Bu[i] * Dv[j]) * P;
            Auu += (Eu[i] * Bv[j]) * P;
            Auv += (Du[i] * Dv[j]) * P;
            Avv += (Bu[i] * Ev[j]) * P;
        }
    }

    // Rational quotient rule: S = A/w, differentiate through the weight.
    float w   = A.w;
    float wu  = Au.w,  wv  = Av.w;
    float wuu = Auu.w, wuv = Auv.w, wvv = Avv.w;
    float iw  = 1.0f / w;

    SurfaceJet J;
    J.S   =  A.xyz * iw;
    J.Su  = (Au.xyz  - wu * J.S) * iw;
    J.Sv  = (Av.xyz  - wv * J.S) * iw;
    J.Suu = (Auu.xyz - 2.0f * wu * J.Su - wuu * J.S) * iw;
    J.Suv = (Auv.xyz - wu * J.Sv - wv * J.Su - wuv * J.S) * iw;
    J.Svv = (Avv.xyz - 2.0f * wv * J.Sv - wvv * J.S) * iw;
    return J;
}

// ===========================================================================
// 2.  map(xyz, points) -> uv
//
// Closest point on the patch, solved as a 2x2 root-finding problem:
//     f(u,v) = (S - P) . Su = 0
//     g(u,v) = (S - P) . Sv = 0
// Seeded by a coarse grid sample, refined by damped Newton-Raphson.
// ===========================================================================
float2 map(float3 xyz, float4 points[PATCH_CP])
{
    // ---- 1. coarse grid seed (kills most local-minimum failures) ----------
    float2 seed   = float2(0.5f);
    float  seedD2 = 1e30f;

    for (int i = 0; i <= INV_SEED_RES; ++i)
    {
        for (int j = 0; j <= INV_SEED_RES; ++j)
        {
            float2 t = float2(float(i), float(j)) / float(INV_SEED_RES);
            float4 A = evalHomogeneous(t, points);
            float3 d = A.xyz / A.w - xyz;
            float  d2 = dot(d, d);
            if (d2 < seedD2) { seedD2 = d2; seed = t; }
        }
    }

    // ---- 2. damped Newton refinement --------------------------------------
    float2 uv = seed;

    for (int it = 0; it < INV_MAX_ITER; ++it)
    {
        SurfaceJet J = evalJet(uv, points);
        float3 r  = J.S - xyz;
        float  rl = length(r);

        // Criterion A: point coincidence.
        if (rl < INV_EPS_POINT)
            break;

        float f = dot(r, J.Su);
        float g = dot(r, J.Sv);

        // Criterion B: zero cosine (residual orthogonal to both tangents).
        float lu = length(J.Su);
        float lv = length(J.Sv);
        bool okU = (lu < 1e-12f) || (abs(f) / (lu * rl) < INV_EPS_COS);
        bool okV = (lv < 1e-12f) || (abs(g) / (lv * rl) < INV_EPS_COS);
        if (okU && okV)
            break;

        // Jacobian of (f,g) -- symmetric, includes the curvature terms.
        float a   = dot(J.Su, J.Su) + dot(r, J.Suu);
        float b   = dot(J.Su, J.Sv) + dot(r, J.Suv);
        float c   = dot(J.Sv, J.Sv) + dot(r, J.Svv);
        float det = a * c - b * b;

        float2 step;
        if (abs(det) < 1e-12f)
        {
            // Near-degenerate (flat spot / singular param): steepest descent.
            float2 grad = float2(f, g);
            if (dot(grad, grad) < 1e-24f)
                break;
            step = -normalize(grad) * 0.01f;
        }
        else
        {
            // Solve J * step = -(f, g).
            step = float2(b * g - c * f,
                          b * f - a * g) / det;
        }

        // Damping: cap the step so Newton can't fling us across the domain.
        float sl = length(step);
        if (sl > INV_MAX_STEP)
            step *= INV_MAX_STEP / sl;

        float2 next = saturate(uv + step);   // clamp to the patch domain

        // Criterion C: parameters stopped moving.
        if (length(next - uv) < INV_EPS_PARAM)
        {
            uv = next;
            break;
        }
        uv = next;
    }

    // ---- 3. safety net: never return worse than the seed -------------------
    float3 dFinal = map(uv, points) - xyz;
    return (dot(dFinal, dFinal) <= seedD2) ? uv : seed;
}
