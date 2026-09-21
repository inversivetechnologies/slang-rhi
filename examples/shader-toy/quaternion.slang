struct Quaternion
{
    float x, y, z, w;

    __init(float x, float y, float z, float w)
    {
        this.x = x; this.y = y; this.z = z; this.w = w;
    }

    __init(float3 v, float w)
    {
        this.x = v.x; this.y = v.y; this.z = v.z; this.w = w;
    }

    static Quaternion identity()
    {
        return Quaternion(0.0, 0.0, 0.0, 1.0);
    }

    static Quaternion fromAxisAngle(float3 axis, float angle)
    {
        float halfAngle = angle * 0.5;
        float s = sin(halfAngle);
        return Quaternion(axis * s, cos(halfAngle));
    }

    static Quaternion fromEuler(float3 eulerXYZ)
    {
        float3 c = cos(eulerXYZ * 0.5);
        float3 s = sin(eulerXYZ * 0.5);

        return Quaternion(
            s.x * c.y * c.z - c.x * s.y * s.z,
            c.x * s.y * c.z + s.x * c.y * s.z,
            c.x * c.y * s.z - s.x * s.y * c.z,
            c.x * c.y * c.z + s.x * s.y * s.z
        );
    }

    float3 xyz() { return float3(x, y, z); }

    float lengthSq() { return x * x + y * y + z * z + w * w; }
    float length()   { return sqrt(lengthSq()); }

    Quaternion normalized()
    {
        float invLen = 1.0 / length();
        return Quaternion(x * invLen, y * invLen, z * invLen, w * invLen);
    }

    Quaternion conjugate()
    {
        return Quaternion(-x, -y, -z, w);
    }

    Quaternion inverse()
    {
        float invLenSq = 1.0 / lengthSq();
        Quaternion c = conjugate();
        return Quaternion(c.x * invLenSq, c.y * invLenSq, c.z * invLenSq, c.w * invLenSq);
    }

    float dot(Quaternion rhs)
    {
        return x * rhs.x + y * rhs.y + z * rhs.z + w * rhs.w;
    }

    float3 rotate(float3 v)
    {
        float3 qv = xyz();
        float3 t = 2.0 * cross(qv, v);
        return v + w * t + cross(qv, t);
    }

    float3x3 toMatrix3x3()
    {
        float xx = x * x, yy = y * y, zz = z * z;
        float xy = x * y, xz = x * z, yz = y * z;
        float wx = w * x, wy = w * y, wz = w * z;

        return float3x3(
            1.0 - 2.0 * (yy + zz), 2.0 * (xy - wz),       2.0 * (xz + wy),
            2.0 * (xy + wz),       1.0 - 2.0 * (xx + zz), 2.0 * (yz - wx),
            2.0 * (xz - wy),       2.0 * (yz + wx),       1.0 - 2.0 * (xx + yy)
        );
    }

    float4x4 toMatrix4x4()
    {
        float3x3 m = toMatrix3x3();
        return float4x4(
            float4(m[0], 0.0),
            float4(m[1], 0.0),
            float4(m[2], 0.0),
            float4(0.0, 0.0, 0.0, 1.0)
        );
    }
};

// ---------------- Operator overloads (free functions) ----------------

Quaternion operator +(Quaternion a, Quaternion b)
{
    return Quaternion(a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w);
}

Quaternion operator -(Quaternion a, Quaternion b)
{
    return Quaternion(a.x - b.x, a.y - b.y, a.z - b.z, a.w - b.w);
}

__prefix Quaternion operator -(Quaternion a)
{
    return Quaternion(-a.x, -a.y, -a.z, -a.w);
}

// Hamilton product: composes rotations.
Quaternion operator *(Quaternion a, Quaternion b)
{
    return Quaternion(
        a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                      a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
    );
}

Quaternion operator *(Quaternion q, float s)
{
    return Quaternion(q.x * s, q.y * s, q.z * s, q.w * s);
}

Quaternion operator *(float s, Quaternion q)
{
    return q * s;
}


// ---------------- Free functions ----------------

Quaternion slerp(Quaternion a, Quaternion b, float t)
{
    float cosHalfTheta = a.dot(b);

    if (cosHalfTheta < 0.0)
    {
        b = -b;
        cosHalfTheta = -cosHalfTheta;
    }

    if (cosHalfTheta > 0.9995)
    {
        Quaternion result = a + (b - a) * t;
        return result.normalized();
    }

    float halfTheta = acos(cosHalfTheta);
    float sinHalfTheta = sqrt(1.0 - cosHalfTheta * cosHalfTheta);

    float wa = sin((1.0 - t) * halfTheta) / sinHalfTheta;
    float wb = sin(t * halfTheta) / sinHalfTheta;

    return a * wa + b * wb;
}
