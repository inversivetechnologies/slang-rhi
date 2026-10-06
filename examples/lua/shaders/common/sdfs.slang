#include "base-ops.slang"
#include "transform.slang"


// Signed Distance Fields
interface IPrim2D {}

interface IPrim3D {}

interface ISDF3D 
{
    float f(float3 p);
}

interface ISDF2D
{
    float f(float2 p);
}

// Boxes

struct Square {
    float s = 1;
}

float SDF(Square obj, float2 p) {
    float dx = abs(p.x) - obj.s;
    float dy = abs(p.y) - obj.s;
    return max(dx, dy);
}

struct Cube {
    float s;
}

float SDF(Cube obj, float3 p) {
    float dx = abs(p.x) - obj.s;
    float dy = abs(p.y) - obj.s;
    float dz = abs(p.z) - obj.s;
    return max(dx, max(dy, dz));
}

struct Box2D {
    float2 size = float2(1, 1);
}

float SDF(Box2D obj, float3 p)
{
    float dx = abs(p.x) - obj.size.x;
    float dy = abs(p.y) - obj.size.y;
    return max(dx, dy);
}

struct Box3D
{
    float3 size = float3(1, 1, 1);
}

float SDF(Box3D obj, float3 p)
{
    float dx = abs(p.x) - obj.size.x;
    float dy = abs(p.y) - obj.size.y;
    float dz = abs(p.z) - obj.size.z;
    return max(dx, max(dy, dz));
}

// Circular

struct Circle {
    float r = 1;
}

float SDF(Circle obj, float2 p) {
    return length(p) - obj.r;
}

struct Sphere {
    float r = 1;
}

float SDF(Sphere obj, float3 p) {
    return length(p) - obj.r;
}


struct Elipse2D : IPrim2D {
    float2 size = float2(1, 1);
}

float SDF(Elipse2D obj, float2 p) {
    float2 ab = obj.size;
    float k0 = length(p / ab);
    float k1 = length(p / (ab * ab));
    return k0 * (k0 - 1.0) / k1;
}

struct Elipse3D : IPrim3D {
    float3 size = float3(1, 1, 1);
}

float SDF(Elipse3D obj, float3 p) {
    float3 ab = obj.size;
    float k0 = length(p / ab);
    float k1 = length(p / (ab * ab));
    return k0 * (k0 - 1.0) / k1;
}

struct Capsule2D {
    float radius = 1;
    float2 a;
    float2 b;
}

float SDF (Capsule2D obj, float2 p)
{
    float2 pa = p - obj.a;
    float2 ba = obj.b - obj.a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - obj.radius;
}

struct Capsule3D {
    float radius;
    float3 a;
    float3 b;
}

// Planes

float SDF (Capsule3D obj, float3 p)
{
    float3 pa = p - obj.a;
    float3 ba = obj.b - obj.a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - obj.radius;
}


struct Plane2D {
    float2 center;
    float2 normal;
}

float SDF (Plane2D obj, float2 p)
{        
    return dot(p - obj.center, obj.normal);
}

struct Plane3D {
    float3 center;
    float3 normal;
}

float SDF (Plane3D obj, float3 p)
{        
    return dot(p - obj.center, obj.normal);
}

// Polygons

struct Polygon {
    int n;
}

float SDF (Polygon obj, float2 p)
{
    int n = obj.n;
    n = max(3,n);
    float t = Radial(p);
    int k = int(t*float(n));
    float t0 = float(k) / float(n);
    float t1 = float((k+1)%n) / float(n);
    float2 p0 = float2(cos(t0*PI2),sin(t0*PI2));
    float2 p1 = float2(cos(t1*PI2),sin(t1*PI2));
    float2 v = p1-p0;
    float2 x = p0 + 0.5 * v;
    float2 normal = normalize(mul(float3(v,1),Rotate(PI*.5)).xy);
    float d = SDF(Plane2D(x,normal),p);
    return d;
}

// Cylindrical

struct Prism {
    int n;
    float height = 1;
}

float SDF (Prism obj, float3 p)
{
    float3 up = float3(0, 1, 0);
    float3 down = float3(0, -1, 0);
    float top = SDF(Plane3D(up, up), p);
    float bottom = SDF(Plane3D(down, down), p);
    Polygon pg = Polygon(obj.n);
    float sect = SDF(pg, p.xz);
    return min(top, min(bottom, sect));
}

struct Cylinder {
    float r;
    float h;
}

float SDF(Cylinder obj, float3 p)
{
    float3 up = float3(0, 0.5 * obj.h, 0);
    float3 down = float3(0, -.5 * obj.h, 0);
    float top = SDF(Plane3D(up, up), p);
    float bottom = SDF(Plane3D(down, down), p);
    float sect = SDF(Circle(obj.r), p.xz);
    return min(top, min(bottom, sect));
}

// Simplicies

struct Tri2D {
    float2 a;
    float2 b;
    float2 c;
}

float SDF (Tri2D obj, float2 p)
{
    float2 ab = obj.b - obj.a;
    float2 centerAB = obj.a + 0.5 * ab;
    float2 normalAB = normalize(mul(float3(ab, 1), Rotate(PI * .5)).xy);
    float dAB = SDF(Plane2D(centerAB, normalAB), p);

    float2 bc = obj.c - obj.b;
    float2 centerBC = obj.b + 0.5 * bc;
    float2 normalBC = normalize(mul(float3(bc, 1), Rotate(PI * .5)).xy);
    float dBC = SDF(Plane2D(centerBC, normalBC), p);

    float2 ca = obj.a - obj.c;
    float2 centerCA = obj.c + 0.5 * ca;
    float2 normalCA = normalize(mul(float3(ca, 1), Rotate(PI * .5)).xy);
    float dCA = SDF(Plane2D(centerCA, normalCA), p);

    return min(dAB, min(dBC, dCA));
}

struct Tri3D {
    float3 a;
    float3 b;
    float3 c;
}

float SDF (Tri3D obj, float3 p)
{
    float3 center = (obj.a + obj.b + obj.c) / 3;
    float3 tangent = normalize(obj.b - obj.a);
    float3 cotangent = normalize(obj.c - obj.a);
    float3 normal = cross(tangent, cotangent);
    return SDF(Plane3D(center, normal), p);
}

struct Tetrah : IPrim3D {
    float3 a;
    float3 b;
    float3 c;
    float3 d;
}

float SDF (Tetrah obj, float3 p)
{
    float dABD = SDF(Tri3D(obj.a, obj.b, obj.d), p);
    float dBCD = SDF(Tri3D(obj.b, obj.c, obj.d), p);
    float dCAD = SDF(Tri3D(obj.c, obj.a, obj.d), p);
    float dABC = SDF(Tri3D(obj.a, obj.b, obj.c), p);
    return min(dABD, min (dBCD, min (dCAD, dABC)));
}


// Parametric Primitives

float2 LineSegment(float2 a, float2 b, float t)
{
    return lerp(a, b, t);
}

float3 LineSegment(float3 a, float3 b, float t)
{
    return lerp(a, b, t);
}


float LineSegmentInv(float3 a, float3 b, float3 p)
{
}


