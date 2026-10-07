// Jolt Physics behind physics.h. Follows Jolt's HelloWorld sample for the setup: two object
// layers (things that move, and things that don't), mapped one to one onto broad phase
// layers, and a job system for the simulation's threads.

#include "physics.h"

#include <Jolt/Jolt.h>

#include <Jolt/Core/Factory.h>
#include <Jolt/Core/JobSystemThreadPool.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Physics/Body/BodyActivationListener.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Body/BodyLock.h>
#include <Jolt/Physics/Character/CharacterVirtual.h>
#include <Jolt/Physics/Collision/CastResult.h>
#include <Jolt/Physics/Collision/RayCast.h>
#include <Jolt/Physics/Collision/Shape/CapsuleShape.h>
#include <Jolt/Physics/Collision/Shape/RotatedTranslatedShape.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/PhysicsSettings.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/RegisterTypes.h>

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <mutex>
#include <thread>
#include <vector>

namespace physics {

namespace {

namespace Layers {
static constexpr JPH::ObjectLayer kNonMoving = 0;
static constexpr JPH::ObjectLayer kMoving = 1;
static constexpr JPH::ObjectLayer kCount = 2;
} // namespace Layers

namespace BroadPhaseLayers {
static constexpr JPH::BroadPhaseLayer kNonMoving(0);
static constexpr JPH::BroadPhaseLayer kMoving(1);
static constexpr uint32_t kCount = 2;
} // namespace BroadPhaseLayers

// Things that don't move never collide with each other.
class ObjectLayerPairFilter final : public JPH::ObjectLayerPairFilter
{
public:
    bool ShouldCollide(JPH::ObjectLayer a, JPH::ObjectLayer b) const override
    {
        return a == Layers::kMoving || b == Layers::kMoving;
    }
};

class BroadPhaseLayerInterface final : public JPH::BroadPhaseLayerInterface
{
public:
    uint32_t GetNumBroadPhaseLayers() const override { return BroadPhaseLayers::kCount; }
    JPH::BroadPhaseLayer GetBroadPhaseLayer(JPH::ObjectLayer layer) const override
    {
        return layer == Layers::kNonMoving ? BroadPhaseLayers::kNonMoving : BroadPhaseLayers::kMoving;
    }
#if defined(JPH_EXTERNAL_PROFILE) || defined(JPH_PROFILE_ENABLED)
    const char* GetBroadPhaseLayerName(JPH::BroadPhaseLayer layer) const override
    {
        return layer == BroadPhaseLayers::kNonMoving ? "non moving" : "moving";
    }
#endif
};

class ObjectVsBroadPhaseLayerFilter final : public JPH::ObjectVsBroadPhaseLayerFilter
{
public:
    bool ShouldCollide(JPH::ObjectLayer layer, JPH::BroadPhaseLayer broadPhaseLayer) const override
    {
        return layer == Layers::kMoving || broadPhaseLayer == BroadPhaseLayers::kMoving;
    }
};

void trace(const char* format, ...)
{
    va_list args;
    va_start(args, format);
    char buffer[1024];
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    printf("[jolt] %s\n", buffer);
    fflush(stdout);
}

#ifdef JPH_ENABLE_ASSERTS
bool assertFailed(const char* expression, const char* message, const char* file, uint32_t line)
{
    printf("[jolt] assert failed: %s (%s) at %s:%u\n", expression, message ? message : "", file, line);
    fflush(stdout);
    return true; // break into the debugger
}
#endif

// Jolt's process-wide state: set up once, by the first world.
void initializeJolt()
{
    static std::once_flag once;
    std::call_once(
        once,
        []()
        {
            JPH::RegisterDefaultAllocator();
            JPH::Trace = trace;
            JPH_IF_ENABLE_ASSERTS(JPH::AssertFailed = assertFailed;)
            JPH::Factory::sInstance = new JPH::Factory();
            JPH::RegisterTypes();
        }
    );
}

constexpr double kStep = 1.0 / 60.0;
constexpr int kMaxStepsPerCall = 4;

// Ignores a list of bodies (the characters' inner bodies, for ray casts).
class IgnoreBodiesFilter final : public JPH::BodyFilter
{
public:
    explicit IgnoreBodiesFilter(const std::vector<JPH::BodyID>& ids)
        : m_ids(ids)
    {
    }
    bool ShouldCollide(const JPH::BodyID& id) const override
    {
        return std::find(m_ids.begin(), m_ids.end(), id) == m_ids.end();
    }

private:
    const std::vector<JPH::BodyID>& m_ids;
};

struct Character
{
    JPH::Ref<JPH::CharacterVirtual> character;
    float move[2] = {0, 0};
    float pendingJump = -1.0f; // < 0: none
    float gravityScale = 1.0f;
    float maxFallSpeed = 0.0f;
};

} // namespace

struct World::Impl
{
    ObjectLayerPairFilter objectLayerPairFilter;
    BroadPhaseLayerInterface broadPhaseLayers;
    ObjectVsBroadPhaseLayerFilter objectVsBroadPhaseLayerFilter;
    std::unique_ptr<JPH::TempAllocatorImpl> tempAllocator;
    std::unique_ptr<JPH::JobSystemThreadPool> jobSystem;
    JPH::PhysicsSystem system;
    double accumulated = 0.0;
    bool broadPhaseDirty = false;
    std::vector<Character> characters;
    std::vector<JPH::BodyID> characterBodies; // their inner bodies

    void stepCharacters(float dt);
};

// As in Jolt's CharacterVirtual sample: keep the ground's velocity while standing on it,
// else keep the vertical velocity; add gravity, the player's horizontal move, and a jump.
void World::Impl::stepCharacters(float dt)
{
    JPH::Vec3 gravity = system.GetGravity();
    JPH::Vec3 up = JPH::Vec3::sAxisY();
    JPH::CharacterVirtual::ExtendedUpdateSettings updateSettings;
    for (Character& c : characters)
    {
        JPH::CharacterVirtual& ch = *c.character;
        ch.UpdateGroundVelocity();
        JPH::Vec3 ground = ch.GetGroundVelocity();
        float vertical = ch.GetLinearVelocity().GetY();
        bool onGround = ch.GetGroundState() == JPH::CharacterBase::EGroundState::OnGround;
        bool towardGround = vertical - ground.GetY() < 0.1f;

        JPH::Vec3 velocity = onGround && towardGround ? ground : vertical * up;
        if (c.pendingJump >= 0.0f)
        {
            velocity.SetY(c.pendingJump);
            c.pendingJump = -1.0f;
        }
        velocity += gravity * c.gravityScale * dt;
        if (c.maxFallSpeed > 0.0f && velocity.GetY() < -c.maxFallSpeed)
            velocity.SetY(-c.maxFallSpeed);
        velocity += JPH::Vec3(c.move[0], 0, c.move[1]);
        // Don't climb slopes that are too steep by walking into them.
        velocity = ch.CancelVelocityTowardsSteepSlopes(velocity);
        ch.SetLinearVelocity(velocity);

        ch.ExtendedUpdate(
            dt,
            gravity,
            updateSettings,
            system.GetDefaultBroadPhaseLayerFilter(Layers::kMoving),
            system.GetDefaultLayerFilter(Layers::kMoving),
            {},
            {},
            *tempAllocator
        );
    }
}

World::World(const float gravity[3], uint32_t maxBodies)
    : m_impl(std::make_unique<Impl>())
{
    initializeJolt();
    m_impl->tempAllocator = std::make_unique<JPH::TempAllocatorImpl>(16 * 1024 * 1024);
    int threads = std::max(1, int(std::thread::hardware_concurrency()) - 1);
    m_impl->jobSystem =
        std::make_unique<JPH::JobSystemThreadPool>(JPH::cMaxPhysicsJobs, JPH::cMaxPhysicsBarriers, threads);
    m_impl->system.Init(
        maxBodies,
        0, // body mutexes: the default
        maxBodies, // max body pairs
        maxBodies, // max contact constraints
        m_impl->broadPhaseLayers,
        m_impl->objectVsBroadPhaseLayerFilter,
        m_impl->objectLayerPairFilter
    );
    setGravity(gravity);
}

World::~World()
{
    m_impl->characters.clear(); // removes their inner bodies
    JPH::BodyInterface& bodies = m_impl->system.GetBodyInterface();
    JPH::BodyIDVector ids;
    m_impl->system.GetBodies(ids);
    for (JPH::BodyID id : ids)
    {
        bodies.RemoveBody(id);
        bodies.DestroyBody(id);
    }
}

uint32_t World::addBody(const BodyDesc& desc)
{
    JPH::RefConst<JPH::Shape> shape;
    if (desc.shape == Shape::Sphere)
    {
        shape = new JPH::SphereShape(std::max(desc.radius, 0.001f));
    }
    else
    {
        JPH::Vec3 halfExtents(
            std::max(desc.halfExtents[0], 0.001f),
            std::max(desc.halfExtents[1], 0.001f),
            std::max(desc.halfExtents[2], 0.001f)
        );
        // The rounding of the box's edges can't be more than its thinnest half extent.
        float convexRadius = std::min(JPH::cDefaultConvexRadius, 0.5f * halfExtents.ReduceMin());
        shape = new JPH::BoxShape(halfExtents, convexRadius);
    }

    bool moves = desc.motion != Motion::Static;
    JPH::EMotionType motion = desc.motion == Motion::Static    ? JPH::EMotionType::Static
                              : desc.motion == Motion::Dynamic ? JPH::EMotionType::Dynamic
                                                               : JPH::EMotionType::Kinematic;
    JPH::BodyCreationSettings settings(
        shape,
        JPH::RVec3(desc.position[0], desc.position[1], desc.position[2]),
        JPH::Quat(desc.rotation[0], desc.rotation[1], desc.rotation[2], desc.rotation[3]).Normalized(),
        motion,
        moves ? Layers::kMoving : Layers::kNonMoving
    );
    settings.mFriction = desc.friction;
    settings.mRestitution = desc.restitution;
    settings.mLinearVelocity = JPH::Vec3(desc.linearVelocity[0], desc.linearVelocity[1], desc.linearVelocity[2]);
    settings.mAngularVelocity = JPH::Vec3(desc.angularVelocity[0], desc.angularVelocity[1], desc.angularVelocity[2]);
    if (desc.motion == Motion::Dynamic && desc.density > 0)
    {
        settings.mOverrideMassProperties = JPH::EOverrideMassProperties::CalculateInertia;
        settings.mMassPropertiesOverride.mMass = desc.density * shape->GetVolume();
    }

    JPH::BodyID id = m_impl->system.GetBodyInterface().CreateAndAddBody(
        settings,
        moves ? JPH::EActivation::Activate : JPH::EActivation::DontActivate
    );
    if (id.IsInvalid())
    {
        return UINT32_MAX; // out of bodies
    }
    m_impl->broadPhaseDirty = true;
    return id.GetIndexAndSequenceNumber();
}

void World::removeBody(uint32_t id)
{
    JPH::BodyInterface& bodies = m_impl->system.GetBodyInterface();
    JPH::BodyID bodyId(id);
    bodies.RemoveBody(bodyId);
    bodies.DestroyBody(bodyId);
}

void World::step(double seconds)
{
    // After adding bodies in bulk, rebuild the broad phase once, as Jolt recommends.
    if (m_impl->broadPhaseDirty)
    {
        m_impl->system.OptimizeBroadPhase();
        m_impl->broadPhaseDirty = false;
    }
    m_impl->accumulated = std::min(m_impl->accumulated + seconds, kStep * kMaxStepsPerCall);
    while (m_impl->accumulated >= kStep)
    {
        m_impl->stepCharacters(float(kStep));
        m_impl->system.Update(float(kStep), 1, m_impl->tempAllocator.get(), m_impl->jobSystem.get());
        m_impl->accumulated -= kStep;
    }
}

void World::getTransform(uint32_t id, float position[3], float rotation[4]) const
{
    JPH::RVec3 p;
    JPH::Quat q;
    m_impl->system.GetBodyInterfaceNoLock().GetPositionAndRotation(JPH::BodyID(id), p, q);
    position[0] = float(p.GetX());
    position[1] = float(p.GetY());
    position[2] = float(p.GetZ());
    rotation[0] = q.GetX();
    rotation[1] = q.GetY();
    rotation[2] = q.GetZ();
    rotation[3] = q.GetW();
}

void World::setLinearVelocity(uint32_t id, const float velocity[3])
{
    m_impl->system.GetBodyInterface().SetLinearVelocity(JPH::BodyID(id), JPH::Vec3(velocity[0], velocity[1], velocity[2]));
}

void World::addImpulse(uint32_t id, const float impulse[3])
{
    m_impl->system.GetBodyInterface().AddImpulse(JPH::BodyID(id), JPH::Vec3(impulse[0], impulse[1], impulse[2]));
}

void World::setGravity(const float gravity[3])
{
    m_impl->system.SetGravity(JPH::Vec3(gravity[0], gravity[1], gravity[2]));
}

uint32_t World::addCharacter(const CharacterDesc& desc)
{
    float radius = std::max(desc.radius, 0.05f);
    float halfCylinder = std::max(0.5f * desc.height - radius, 0.01f);
    // A capsule standing on the origin, so that the character's position is its feet.
    JPH::RefConst<JPH::Shape> capsule = new JPH::CapsuleShape(halfCylinder, radius);
    JPH::RefConst<JPH::Shape> shape =
        JPH::RotatedTranslatedShapeSettings(JPH::Vec3(0, halfCylinder + radius, 0), JPH::Quat::sIdentity(), capsule)
            .Create()
            .Get();

    JPH::Ref<JPH::CharacterVirtualSettings> settings = new JPH::CharacterVirtualSettings();
    settings->mShape = shape;
    settings->mMaxSlopeAngle = JPH::DegreesToRadians(desc.maxSlopeDegrees);
    settings->mMass = desc.mass;
    settings->mMaxStrength = desc.maxStrength;
    // Only contacts with the bottom sphere support it.
    settings->mSupportingVolume = JPH::Plane(JPH::Vec3::sAxisY(), -radius);
    // An inner rigid body, so that the bodies collide with the character too (thrown
    // balls bounce off it, boxes land on it).
    settings->mInnerBodyShape = shape;
    settings->mInnerBodyLayer = Layers::kMoving;

    Character c;
    c.character = new JPH::CharacterVirtual(
        settings,
        JPH::RVec3(desc.position[0], desc.position[1], desc.position[2]),
        JPH::Quat::sIdentity(),
        0,
        &m_impl->system
    );
    m_impl->characterBodies.push_back(c.character->GetInnerBodyID());
    m_impl->characters.push_back(c);
    return uint32_t(m_impl->characters.size() - 1);
}

uint32_t World::characterCount() const
{
    return uint32_t(m_impl->characters.size());
}

void World::setCharacterMove(uint32_t index, float x, float z)
{
    m_impl->characters[index].move[0] = x;
    m_impl->characters[index].move[1] = z;
}

void World::jumpCharacter(uint32_t index, float speed)
{
    m_impl->characters[index].pendingJump = std::max(speed, 0.0f);
}

void World::setCharacterGravity(uint32_t index, float scale, float maxFallSpeed)
{
    m_impl->characters[index].gravityScale = scale;
    m_impl->characters[index].maxFallSpeed = maxFallSpeed;
}

void World::setCharacterPosition(uint32_t index, const float position[3])
{
    m_impl->characters[index].character->SetPosition(JPH::RVec3(position[0], position[1], position[2]));
}

void World::setCharacterVelocity(uint32_t index, const float velocity[3])
{
    m_impl->characters[index].character->SetLinearVelocity(JPH::Vec3(velocity[0], velocity[1], velocity[2]));
}

void World::getCharacter(uint32_t index, CharacterState& state) const
{
    const JPH::CharacterVirtual& ch = *m_impl->characters[index].character;
    JPH::RVec3 p = ch.GetPosition();
    JPH::Vec3 v = ch.GetLinearVelocity();
    state.position[0] = float(p.GetX());
    state.position[1] = float(p.GetY());
    state.position[2] = float(p.GetZ());
    state.velocity[0] = v.GetX();
    state.velocity[1] = v.GetY();
    state.velocity[2] = v.GetZ();
    switch (ch.GetGroundState())
    {
    case JPH::CharacterBase::EGroundState::OnGround:
        state.ground = Ground::OnGround;
        break;
    case JPH::CharacterBase::EGroundState::OnSteepGround:
        state.ground = Ground::OnSteepGround;
        break;
    case JPH::CharacterBase::EGroundState::NotSupported:
        state.ground = Ground::NotSupported;
        break;
    default:
        state.ground = Ground::InAir;
        break;
    }
}

bool World::castRay(const float origin[3], const float direction[3], float maxDistance, RayHit& hit) const
{
    JPH::Vec3 dir(direction[0], direction[1], direction[2]);
    if (dir.LengthSq() < 1e-12f || maxDistance <= 0.0f)
        return false;
    dir = dir.Normalized() * maxDistance;
    JPH::RRayCast ray(JPH::RVec3(origin[0], origin[1], origin[2]), dir);
    JPH::RayCastResult result;
    IgnoreBodiesFilter bodyFilter(m_impl->characterBodies);
    if (!m_impl->system.GetNarrowPhaseQuery().CastRay(ray, result, {}, {}, bodyFilter))
        return false;
    JPH::RVec3 point = ray.GetPointOnRay(result.mFraction);
    hit.distance = result.mFraction * maxDistance;
    hit.point[0] = float(point.GetX());
    hit.point[1] = float(point.GetY());
    hit.point[2] = float(point.GetZ());
    hit.normal[0] = 0;
    hit.normal[1] = 1;
    hit.normal[2] = 0;
    hit.moving = false;
    JPH::BodyLockRead lock(m_impl->system.GetBodyLockInterface(), result.mBodyID);
    if (lock.Succeeded())
    {
        const JPH::Body& body = lock.GetBody();
        JPH::Vec3 normal = body.GetWorldSpaceSurfaceNormal(result.mSubShapeID2, point);
        hit.normal[0] = normal.GetX();
        hit.normal[1] = normal.GetY();
        hit.normal[2] = normal.GetZ();
        hit.moving = !body.IsStatic();
    }
    return true;
}

} // namespace physics
