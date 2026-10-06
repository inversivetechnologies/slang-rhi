
// Maps for Barycentric Coordinates for Trianlges   //////////////////////////////////////

float2 BaryToEuclid(float2 tri[3], float3 b)
{
    return tri[0] * b.x + tri[1] * b.y + tri[2] * b.z;
}

float3 BaryToEuclid(float3 tri[3], float3 b)
{
    return tri[0] * b.x + tri[1] * b.y + tri[2] * b.z;
}

float3 EuclidToBary(float2 tri[3], float2 p)
{
    float2 v0 = tri[1] - tri[0];
    float2 v1 = tri[2] - tri[0];
    float2 v2 = p - tri[0];

    float d00 = dot(v0, v0);
    float d01 = dot(v0, v1);
    float d11 = dot(v1, v1);
    float d20 = dot(v2, v0);
    float d21 = dot(v2, v1);

    float denom = d00 * d11 - d01 * d01;   // zero for degenerate triangles
    float v = (d11 * d20 - d01 * d21) / denom;
    float w = (d00 * d21 - d01 * d20) / denom;
    return float3(1.0 - v - w, v, w);
}

float3 EuclidToBary(float3 tri[3], float3 p)
{
    float3 v0 = tri[1] - tri[0];
    float3 v1 = tri[2] - tri[0];
    float3 v2 = p - tri[0];

    float d00 = dot(v0, v0);
    float d01 = dot(v0, v1);
    float d11 = dot(v1, v1);
    float d20 = dot(v2, v0);
    float d21 = dot(v2, v1);

    float denom = d00 * d11 - d01 * d01;   // zero for degenerate triangles
    float v = (d11 * d20 - d01 * d21) / denom;
    float w = (d00 * d21 - d01 * d20) / denom;
    return float3(1.0 - v - w, v, w);
}

vector<float, 3> EuclidToBary<let D : int>(vector<float, D> tri[3], vector<float, D> p)
{
    let v0 = tri[1] - tri[0];
    let v1 = tri[2] - tri[0];
    let v2 = p - tri[0];

    float d00 = dot(v0, v0);
    float d01 = dot(v0, v1);
    float d11 = dot(v1, v1);
    float d20 = dot(v2, v0);
    float d21 = dot(v2, v1);

    float denom = d00 * d11 - d01 * d01;
    float v = (d11 * d20 - d01 * d21) / denom;
    float w = (d00 * d21 - d01 * d20) / denom;
    return float3(1.0 - v - w, v, w);
}


// Barycentric coordinates for Tetrahedrons  ////////////////////////////////////////////////////

float3 BaryToEuclid(float3 tetrah[4], float4 b)
{
    return b.x * tetrah[0] + b.y * tetrah[1] + b.z * tetrah[2] + b.w * tetrah[3];
}

float4 EuclidToBary(float3 tetrah[4], float3 p)
{
    float3 e1 = tetrah[1] - tetrah[0];
    float3 e2 = tetrah[2] - tetrah[0];
    float3 e3 = tetrah[3] - tetrah[0];
    float3 q  = p - tetrah[0];

    // Cramer's rule for solving [e1 e2 e3] * (b1, b2, b3) = q
    float3 c23 = cross(e2, e3);
    float3 c31 = cross(e3, e1);
    float3 c12 = cross(e1, e2);

    float invDet = 1.0 / dot(e1, c23);   // 6x signed volume, zero for degenerate tetrahedra

    float b1 = dot(q, c23) * invDet;
    float b2 = dot(q, c31) * invDet;
    float b3 = dot(q, c12) * invDet;

    return float4(1.0 - b1 - b2 - b3, b1, b2, b3);
}

vector<float, D> BaryToEuclid<let D : int>(vector<float, D> tetrah[4], vector<float, 4> b)
{
    return tetrah[0] * b.x + tetrah[1] * b.y + tetrah[2] * b.z + tetrah[3] * b.w;
}

vector<float, 4> EuclidToBary<let D : int>(vector<float, D> tetrah[4], vector<float, D> p)
{
    static_assert(D >= 3, "A tetrahedron needs at least 3 dimensions");

    vector<float, D> e1 = tetrah[1] - tetrah[0];
    vector<float, D> e2 = tetrah[2] - tetrah[0];
    vector<float, D> e3 = tetrah[3] - tetrah[0];
    vector<float, D> q  = p - tetrah[0];

    // Gram matrix G = E^T E (symmetric 3x3) and right-hand side r = E^T q
    float g11 = dot(e1, e1), g12 = dot(e1, e2), g13 = dot(e1, e3);
    float g22 = dot(e2, e2), g23 = dot(e2, e3), g33 = dot(e3, e3);
    float r1 = dot(e1, q), r2 = dot(e2, q), r3 = dot(e3, q);

    // Cofactors of G (G is symmetric, so the adjugate equals the cofactor matrix)
    float c11 = g22 * g33 - g23 * g23;
    float c12 = g13 * g23 - g12 * g33;
    float c13 = g12 * g23 - g13 * g22;
    float c22 = g11 * g33 - g13 * g13;
    float c23 = g12 * g13 - g11 * g23;
    float c33 = g11 * g22 - g12 * g12;

    float invDet = 1.0 / (g11 * c11 + g12 * c12 + g13 * c13);   // zero for degenerate tetrahedra

    // Solve G * (b1, b2, b3) = r
    float b1 = (c11 * r1 + c12 * r2 + c13 * r3) * invDet;
    float b2 = (c12 * r1 + c22 * r2 + c23 * r3) * invDet;
    float b3 = (c13 * r1 + c23 * r2 + c33 * r3) * invDet;

    return vector<float, 4>(1.0 - b1 - b2 - b3, b1, b2, b3);
}
