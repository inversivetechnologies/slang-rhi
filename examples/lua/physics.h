#pragma once

// Rigid body physics for the example host, on Jolt Physics (github.com/jrouwe/JoltPhysics).
//
// A small interface over Jolt, so that example-lua.cpp needs none of Jolt's headers: a
// world of bodies, each a box or a sphere, static, dynamic or kinematic, that steps itself
// at a fixed rate however long the frames are; characters (capsules a player steers,
// which walk on and push the bodies); and ray casts.

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

struct CharacterDesc
{
    float radius = 0.35f;
    float height = 1.8f;           // feet to top of the head, radius included
    float position[3] = {0, 0, 0}; // the feet
    float maxSlopeDegrees = 50.0f;
    float mass = 90.0f;         // kg: how hard it pushes what it walks into
    float maxStrength = 600.0f; // N: the most force it pushes with
};

enum class Ground
{
    OnGround,
    OnSteepGround, // touching a slope too steep to stand on
    NotSupported,  // touching something, but not standing on it
    InAir,
};

struct CharacterState
{
    float position[3]; // the feet
    float velocity[3];
    Ground ground;
};

struct RayHit
{
    float distance;
    float point[3];
    float normal[3];
    bool moving; // the body hit can move (dynamic or kinematic)
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

    // Characters: moved once per fixed step, before the bodies. Each step, a character's
    // velocity is its horizontal `move`, plus its vertical velocity under gravity (times
    // its gravity scale, falling no faster than its max fall speed if that is > 0), plus
    // the velocity of the ground it stands on. A jump replaces the vertical velocity on the
    // next step, on the ground or not. Returns its index.
    uint32_t addCharacter(const CharacterDesc& desc);
    uint32_t characterCount() const;
    void setCharacterMove(uint32_t index, float x, float z);
    void jumpCharacter(uint32_t index, float speed);
    void setCharacterGravity(uint32_t index, float scale, float maxFallSpeed);
    void setCharacterPosition(uint32_t index, const float position[3]);
    void setCharacterVelocity(uint32_t index, const float velocity[3]);
    void getCharacter(uint32_t index, CharacterState& state) const;

    // The nearest hit along `direction` (normalized here) within `maxDistance`, ignoring
    // the characters. False if nothing is hit.
    bool castRay(const float origin[3], const float direction[3], float maxDistance, RayHit& hit) const;

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace physics
