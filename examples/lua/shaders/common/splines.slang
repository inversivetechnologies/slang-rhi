
float2 CubicBezier(float t, float2 p0, float2 p1, float2 p2, float2 p3)
{
    float u = 1.0 - t;
    float uu = u * u;
    float uuu = uu * u;
    float tt = t * t;
    float ttt = tt * t;

    return uuu * p0
         + 3.0 * uu * t * p1
         + 3.0 * u * tt * p2
         + ttt * p3;
}

float2 CubicBezierDerivative(float t, float2 p0, float2 p1, float2 p2, float2 p3)
{
    float u = 1.0 - t;
    return 3.0 * u * u * (p1 - p0)
         + 6.0 * u * t * (p2 - p1)
         + 3.0 * t * t * (p3 - p2);
}

float2 CubicBezierSecondDerivative(float t, float2 p0, float2 p1, float2 p2, float2 p3)
{
    float u = 1.0 - t;
    return 6.0 * u * (p2 - 2.0 * p1 + p0)
         + 6.0 * t * (p3 - 2.0 * p2 + p1);
}

float CubicBezierInv(float2 uv, float2 p0, float2 p1, float2 p2, float2 p3)
{
    static const int SAMPLES = 8;
    static const int ITERATIONS = 6;

    float bestT = 0.0;
    float bestDist = dot(p0 - uv, p0 - uv);

    for (int i = 1; i <= SAMPLES; i++)
    {
        float t = (float)i / (float)SAMPLES;
        float2 p = CubicBezier(t, p0, p1, p2, p3);
        float d = dot(p - uv, p - uv);
        if (d < bestDist)
        {
            bestDist = d;
            bestT = t;
        }
    }

    float t = bestT;
    for (int i = 0; i < ITERATIONS; i++)
    {
        float2 p = CubicBezier(t, p0, p1, p2, p3);
        float2 d1 = CubicBezierDerivative(t, p0, p1, p2, p3);
        float2 d2 = CubicBezierSecondDerivative(t, p0, p1, p2, p3);
        float2 diff = p - uv;

        float denom = dot(d1, d1) + dot(diff, d2);
        if (abs(denom) < 1e-6) break;

        t = saturate(t - dot(diff, d1) / denom);
    }

    return t;
}

float3 CubicBezier(float t, float3 p0, float3 p1, float3 p2, float3 p3)
{
    float u = 1.0 - t;
    float uu = u * u;
    float uuu = uu * u;
    float tt = t * t;
    float ttt = tt * t;

    return uuu * p0
         + 3.0 * uu * t * p1
         + 3.0 * u * tt * p2
         + ttt * p3;
}

float3 CubicBezierDerivative(float t, float3 p0, float3 p1, float3 p2, float3 p3)
{
    float u = 1.0 - t;
    return 3.0 * u * u * (p1 - p0)
         + 6.0 * u * t * (p2 - p1)
         + 3.0 * t * t * (p3 - p2);
}

float3 CubicBezierSecondDerivative(float t, float3 p0, float3 p1, float3 p2, float3 p3)
{
    float u = 1.0 - t;
    return 6.0 * u * (p2 - 2.0 * p1 + p0)
         + 6.0 * t * (p3 - 2.0 * p2 + p1);
}

float CubicBezierInv(float3 pos, float3 p0, float3 p1, float3 p2, float3 p3)
{
    static const int SAMPLES = 8;
    static const int ITERATIONS = 6;

    float bestT = 0.0;
    float bestDist = dot(p0 - pos, p0 - pos);

    [unroll]
    for (int i = 1; i <= SAMPLES; i++)
    {
        float t = (float)i / (float)SAMPLES;
        float3 p = CubicBezier(t, p0, p1, p2, p3);
        float d = dot(p - pos, p - pos);
        if (d < bestDist)
        {
            bestDist = d;
            bestT = t;
        }
    }

    float t = bestT;
    [unroll]
    for (int i = 0; i < ITERATIONS; i++)
    {
        float3 p = CubicBezier(t, p0, p1, p2, p3);
        float3 d1 = CubicBezierDerivative(t, p0, p1, p2, p3);
        float3 d2 = CubicBezierSecondDerivative(t, p0, p1, p2, p3);
        float3 diff = p - pos;

        float denom = dot(d1, d1) + dot(diff, d2);
        if (abs(denom) < 1e-6) break;

        t = saturate(t - dot(diff, d1) / denom);
    }

    return t;
}

// ============================================================================
// nurbs.hlsl
//
// Bicubic (degree-3) B-spline surface evaluation + closest-point inversion.
//
// ASSUMPTIONS (since the requested signatures take only positions, no
// per-point weights and no explicit grid-size argument):
//   - Non-rational B-spline surface (all weights = 1). This is the common
//     case in practice; see the RATIONAL EXTENSION note at the bottom if you
//     need true NURBS weighting.
//   - The control point array p[] is a row-major flattened CTRL_U x CTRL_V
//     grid:  p[i * CTRL_V + j]  ->  control point at (u-index i, v-index j)
//   - Degree 3 in both directions, clamped ("open uniform") knot vectors,
//     so uv = (0,0) hits the first corner and uv = (1,1) hits the last
//     corner of the control grid exactly.
//   - CTRL_U / CTRL_V are compile-time constants below. Change them (and
//     rebuild) to match the number of control points you actually pass in.
//
// If your engine's array-of-struct binding differs (StructuredBuffer,
// fixed-size array, etc.), just adapt the p[] indexing — the math is
// otherwise self-contained.
// ============================================================================

// ---- Grid configuration ---------------------------------------------------
#define CTRL_U 4 // number of control points along u
#define CTRL_V 4 // number of control points along v
#define DEGREE 3 // cubic

#define KNOTS_U (CTRL_U + DEGREE + 1)
#define KNOTS_V (CTRL_V + DEGREE + 1)

// ---- Clamped uniform knot vector ------------------------------------------
// knots[0..DEGREE] = 0, knots[n..n+DEGREE] = 1, interior knots uniform.
void BuildClampedKnots(int n, int degree, out float knots[16])
{
    int m = n + degree + 1;        // total knot count
    int interior = n - degree - 1; // number of interior knots (>=0)

    for (int k = 0; k < m; k++)
    {
        if (k <= degree)
        {
            knots[k] = 0.0;
        }
        else if (k >= n)
        {
            knots[k] = 1.0;
        }
        else
        {
            int idx = k - degree; // 1..interior
            knots[k] = (float)idx / (float)(interior + 1);
        }
    }
}

// ---- Basis functions + derivatives (Cox-de Boor, full vector) -------------
// Computes N[0..n-1] and dN[0..n-1] (dN/dt) at parameter t, for a clamped
// knot vector of length n+degree+1.
void BasisAndDeriv(float knots[16], int n, int degree, float t,
                    out float N[8], out float dN[8])
{
    float table[8][4]; // table[i][k] = N_i,k(t), k = 0..degree

    // clamp t into the valid domain (avoids the "t == last knot" edge issue)
    float tc = clamp(t, 0.0, 0.999999);

    // degree 0
    for (int i = 0; i < n + degree; i++)
    {
        if (i < 8)
        {
            bool inSpan = (tc >= knots[i] && tc < knots[i + 1]);
            table[i][0] = inSpan ? 1.0 : 0.0;
        }
    }

    // handle t landing exactly on the final knot (u = 1)
    if (t >= 1.0)
    {
        table[n - 1][0] = 1.0;
        for (int i = 0; i < n - 1; i++) table[i][0] = 0.0;
    }

    // build up degrees 1..degree
    for (int k = 1; k <= degree; k++)
    {
        for (int i = 0; i < n; i++)
        {
            float denom1 = knots[i + k] - knots[i];
            float term1 = 0.0;
            if (denom1 > 1e-8)
                term1 = (tc - knots[i]) / denom1 * table[i][k - 1];

            float denom2 = knots[i + k + 1] - knots[i + 1];
            float term2 = 0.0;
            if (denom2 > 1e-8)
                term2 = (knots[i + k + 1] - tc) / denom2 * table[i + 1][k - 1];

            table[i][k] = term1 + term2;
        }
    }

    // basis values at requested degree
    for (int i = 0; i < n; i++)
        N[i] = table[i][degree];

    // derivative: d/dt N_i,p = p/(k[i+p]-k[i]) * N_i,p-1 - p/(k[i+p+1]-k[i+1]) * N_i+1,p-1
    for (int i = 0; i < n; i++)
    {
        float denom1 = knots[i + degree] - knots[i];
        float termA = 0.0;
        if (denom1 > 1e-8)
            termA = (float)degree / denom1 * table[i][degree - 1];

        float denom2 = knots[i + degree + 1] - knots[i + 1];
        float termB = 0.0;
        if (denom2 > 1e-8)
            termB = (float)degree / denom2 * table[i + 1][degree - 1];

        dN[i] = termA - termB;
    }
}

// ============================================================================
// 1) Surface evaluation
// ============================================================================
float3 Nurbs(float3 p[CTRL_U * CTRL_V], float2 uv)
{
    float knotsU[16]; BuildClampedKnots(CTRL_U, DEGREE, knotsU);
    float knotsV[16]; BuildClampedKnots(CTRL_V, DEGREE, knotsV);

    float Nu[8]; float dNu[8];
    float Nv[8]; float dNv[8];
    BasisAndDeriv(knotsU, CTRL_U, DEGREE, uv.x, Nu, dNu);
    BasisAndDeriv(knotsV, CTRL_V, DEGREE, uv.y, Nv, dNv);

    float3 result = float3(0, 0, 0);
    for (int i = 0; i < CTRL_U; i++)
    {
        for (int j = 0; j < CTRL_V; j++)
        {
            float w = Nu[i] * Nv[j];
            result += w * p[i * CTRL_V + j];
        }
    }
    return result;
}

// Internal helper: position + partial derivatives (tangents) at uv.
// Needed by the Newton solver in NurbsInv.
void NurbsEvalWithTangents(float3 p[CTRL_U * CTRL_V], float2 uv,
                            out float3 S, out float3 Su, out float3 Sv)
{
    float knotsU[16]; BuildClampedKnots(CTRL_U, DEGREE, knotsU);
    float knotsV[16]; BuildClampedKnots(CTRL_V, DEGREE, knotsV);

    float Nu[8]; float dNu[8];
    float Nv[8]; float dNv[8];
    BasisAndDeriv(knotsU, CTRL_U, DEGREE, uv.x, Nu, dNu);
    BasisAndDeriv(knotsV, CTRL_V, DEGREE, uv.y, Nv, dNv);

    S = float3(0, 0, 0);
    Su = float3(0, 0, 0);
    Sv = float3(0, 0, 0);

    for (int i = 0; i < CTRL_U; i++)
    {
        for (int j = 0; j < CTRL_V; j++)
        {
            float3 cp = p[i * CTRL_V + j];
            S += Nu[i] * Nv[j] * cp;
            Su += dNu[i] * Nv[j] * cp;
            Sv += Nu[i] * dNv[j] * cp;
        }
    }
}

// ============================================================================
// 2) Closest-point inversion
//    Returns uv in [0,1]^2 minimizing |Nurbs(p,uv) - xyz|.
//    Method: coarse grid search for a good starting point, then
//    Gauss-Newton refinement using the surface tangents.
// ============================================================================
#define INV_GRID_RES 8    // coarse search resolution (per axis)
#define INV_ITERATIONS 20 // Newton refinement iterations
#define INV_EPS 1e-6

float2 NurbsInv(float3 p[CTRL_U * CTRL_V], float3 xyz)
{
    // ---- 1. Coarse search for a starting guess -----------------------
    float2 bestUV = float2(0.0, 0.0);
    float bestDist = 1e30;

    for (int a = 0; a <= INV_GRID_RES; a++)
    {
        for (int b = 0; b <= INV_GRID_RES; b++)
        {
            float2 uv = float2((float)a / INV_GRID_RES, (float)b / INV_GRID_RES);
            float3 s = Nurbs(p, uv);
            float d = dot(s - xyz, s - xyz);
            if (d < bestDist)
            {
                bestDist = d;
                bestUV = uv;
            }
        }
    }

    // ---- 2. Newton / Gauss-Newton refinement --------------------------
    float2 uv = bestUV;

    for (int iter = 0; iter < INV_ITERATIONS; iter++)
    {
        float3 S, Su, Sv;
        NurbsEvalWithTangents(p, uv, S, Su, Sv);

        float3 diff = S - xyz;

        // Minimize f(u,v) = |S(u,v) - xyz|^2
        // Gradient: g = [dot(diff,Su), dot(diff,Sv)]
        // Gauss-Newton Hessian approx:
        //   H = [ Su.Su   Su.Sv ]
        //       [ Su.Sv   Sv.Sv ]
        float Huu = dot(Su, Su);
        float Hvv = dot(Sv, Sv);
        float Huv = dot(Su, Sv);

        float gu = dot(diff, Su);
        float gv = dot(diff, Sv);

        float det = Huu * Hvv - Huv * Huv;
        if (abs(det) < 1e-12)
            break; // degenerate (e.g. surface flat/singular here)

        float du = (gu * Hvv - gv * Huv) / det;
        float dv = (gv * Huu - gu * Huv) / det;

        uv.x -= du;
        uv.y -= dv;

        // clamp to valid parameter domain
        uv.x = clamp(uv.x, 0.0, 1.0);
        uv.y = clamp(uv.y, 0.0, 1.0);

        if (du * du + dv * dv < INV_EPS * INV_EPS)
            break;
    }

    return uv;
}

// ============================================================================
// RATIONAL EXTENSION (true NURBS, if you later add a weight per control point)
// ----------------------------------------------------------------------------
// Add a parallel array float w[CTRL_U*CTRL_V], then in Nurbs():
//
//   float3 numer = float3(0,0,0);
//   float  denom = 0.0;
//   for (i,j) {
//       float b = Nu[i]*Nv[j]*w[i*CTRL_V+j];
//       numer += b * p[i*CTRL_V+j];
//       denom += b;
//   }
//   result = numer / denom;
//
// and adjust NurbsEvalWithTangents()'s Su/Sv with the quotient rule
// (S = A/W  =>  S' = (A' - S*W') / W). The closest-point Newton loop in
// NurbsInv() is unchanged otherwise.
// ============================================================================
