#include "quaternion.slang"

// 2D Homogenous Transform Matrices

float3x3 Translate(float2 p)
{
    return float3x3(
        1, 0, p.x,
        0, 1, p.y,
        0, 1, 1
    );
}

float3x3 Rotate(float angle)
{
    float s = sin(angle);
    float c = cos(angle);

    return float3x3(
        c, -s, 0,
        s, c, 0,
        0, 0, 1
    );
}

float3x3 Scale(float2 s)
{
    return float3x3(
        s.x, 0, 0,
        0, s.y, 0,
        0, 0, 1
    );
}

float3x3 TranslateInv(float2 p)
{
    return Translate(-p);
}

float3x3 RotateInv(float angle)
{
    return Rotate(-angle);
}

float3x3 ScaleInv(float2 s)
{
    return Scale(1.0 / s);
}


// 3D Homogenous Transform Matrices

float4x4 Translate(float3 p)
{
    return float4x4(
        1, 0, 0, p.x,
        0, 1, 0, p.y,
        0, 0, 1, p.z,
        0, 0, 0, 1
    );
}

float4x4 Rotate(Quaternion q)
{
    return q.toMatrix4x4();
}

float4x4 Scale(float3 s)
{
    return float4x4(
        s.x, 0, 0, 0,
        0, s.y, 0, 0,
        0, 0, s.z, 0,
        0, 0, 0, 1
    );
}

float4x4 TranslateInv(float3 p)
{
    return Translate(-p);
}

float4x4 RotateInv(Quaternion q)
{
    return Rotate(q.inverse());
}

float4x4 ScaleInv(float3 s)
{
    return Scale(1.0 / s);
}

