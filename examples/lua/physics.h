#pragma once

// Rigid body physics for the example host, on Jolt Physics (github.com/jrouwe/JoltPhysics).
//
// A small interface over Jolt, so that example-lua.cpp needs none of Jolt's headers: a
// world of bodies, each a box or a sphere, static, dynamic or kinematic, that steps itself
// at a fixed rate however long the frames are.

#include <cstdint>
#include <memory>

namespace physics {

enum class Shape
{
    Box,    // halfExtents
    Sphere, // radius
};

enum class Motion
{
    Static,    // never moves
    Dynamic,   // moved by forces and collisions
    Kinematic, // moved by setting its velocity; pushes dynamic bodies, isn't pushed
};

struct BodyDesc
{
    Shape shape = Shape::Box;
    float halfExtents[3] = {0.5f, 0.5f, 0.5f};
    float radius = 0.5f;
    Motion motion = Motion::Dynamic;
    float position[3] = {0, 0, 0};
    float rotation[4] = {0, 0, 0, 1}; // quaternion x, y, z, w
    float linearVelocity[3] = {0, 0, 0};
    float angularVelocity[3] = {0, 0, 0};
    float friction = 0.5f;
    float restitution = 0.0f;
    float density = 1000.0f; // kg/m^3; with the shape's volume, gives the mass
};

class World
{
public:
    World(const float gravity[3], uint32_t maxBodies);
    ~World();

    // Adds a body and returns its id, or UINT32_MAX if the world is full.
    uint32_t addBody(const BodyDesc& desc);
    void removeBody(uint32_t id);

    // Advances the simulation by `seconds` of real time, in fixed 1/60 s steps (at most a
    // few per call, so a long frame slows the simulation down rather than stalling it).
    void step(double seconds);

    void getTransform(uint32_t id, float position[3], float rotation[4]) const;
    void setLinearVelocity(uint32_t id, const float velocity[3]);
    void addImpulse(uint32_t id, const float impulse[3]);

    void setGravity(const float gravity[3]);

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace physics
