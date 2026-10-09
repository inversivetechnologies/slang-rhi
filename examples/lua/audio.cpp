// miniaudio behind audio.h: one engine (ma_engine) on the default output device, shared by
// every sound, and a streamed ma_sound per sound.

#include "audio.h"

#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_ENCODING // only playback is needed
#define MA_NO_GENERATION
#include <miniaudio.h>

#include <algorithm>
#include <mutex>

namespace audio {

namespace {

// The engine, started by the first sound and stopped after the last one is gone.
struct Engine
{
    ma_engine engine;
    bool started = false;

    Engine()
    {
        started = ma_engine_init(nullptr, &engine) == MA_SUCCESS;
    }
    ~Engine()
    {
        if (started)
            ma_engine_uninit(&engine);
    }
};

std::shared_ptr<Engine> sharedEngine()
{
    static std::mutex mutex;
    static std::weak_ptr<Engine> current;
    std::lock_guard<std::mutex> lock(mutex);
    std::shared_ptr<Engine> engine = current.lock();
    if (!engine)
    {
        engine = std::make_shared<Engine>();
        current = engine;
    }
    return engine;
}

} // namespace

struct Sound::Impl
{
    std::shared_ptr<Engine> engine; // keeps the engine alive while the sound is
    ma_sound sound;
    bool initialized = false;
    // Without a device: what the sound would be doing.
    bool silentPlaying = false;
    bool silentLooping = false;
    float silentVolume = 1.0f;

    ~Impl()
    {
        if (initialized)
            ma_sound_uninit(&sound);
    }
};

Sound::Sound(std::unique_ptr<Impl> impl)
    : m_impl(std::move(impl))
{
}

Sound::~Sound() = default;

std::unique_ptr<Sound> Sound::load(const std::filesystem::path& path, std::string& error, bool& silent)
{
    std::error_code ec;
    if (!std::filesystem::is_regular_file(path, ec))
    {
        error = "no such file";
        return nullptr;
    }
    auto impl = std::make_unique<Impl>();
    impl->engine = sharedEngine();
    silent = !impl->engine->started;
    if (silent)
    {
        // Still a sound, for the script; it just isn't heard.
        return std::unique_ptr<Sound>(new Sound(std::move(impl)));
    }
    ma_uint32 flags = MA_SOUND_FLAG_STREAM | MA_SOUND_FLAG_NO_SPATIALIZATION;
#ifdef _WIN32
    ma_result result =
        ma_sound_init_from_file_w(&impl->engine->engine, path.wstring().c_str(), flags, nullptr, nullptr, &impl->sound);
#else
    ma_result result = ma_sound_init_from_file(&impl->engine->engine, path.string().c_str(), flags, nullptr, nullptr, &impl->sound);
#endif
    if (result != MA_SUCCESS)
    {
        error = std::string("can't play it: ") + ma_result_description(result);
        return nullptr;
    }
    impl->initialized = true;
    return std::unique_ptr<Sound>(new Sound(std::move(impl)));
}

void Sound::play()
{
    if (m_impl->initialized)
        ma_sound_start(&m_impl->sound);
    m_impl->silentPlaying = true;
}

void Sound::pause()
{
    if (m_impl->initialized)
        ma_sound_stop(&m_impl->sound);
    m_impl->silentPlaying = false;
}

void Sound::seek(double seconds)
{
    if (!m_impl->initialized)
        return;
    ma_uint32 rate = ma_engine_get_sample_rate(&m_impl->engine->engine);
    ma_sound_seek_to_pcm_frame(&m_impl->sound, ma_uint64(std::max(seconds, 0.0) * rate));
}

bool Sound::playing() const
{
    return m_impl->initialized ? ma_sound_is_playing(&m_impl->sound) != 0 : m_impl->silentPlaying;
}

double Sound::position() const
{
    float seconds = 0.0f;
    if (m_impl->initialized)
        ma_sound_get_cursor_in_seconds(&m_impl->sound, &seconds);
    return seconds;
}

double Sound::length() const
{
    float seconds = 0.0f;
    if (m_impl->initialized)
        ma_sound_get_length_in_seconds(&m_impl->sound, &seconds);
    return seconds;
}

void Sound::setVolume(float volume)
{
    if (m_impl->initialized)
        ma_sound_set_volume(&m_impl->sound, volume);
    m_impl->silentVolume = volume;
}

float Sound::volume() const
{
    return m_impl->initialized ? ma_sound_get_volume(&m_impl->sound) : m_impl->silentVolume;
}

void Sound::setLooping(bool looping)
{
    if (m_impl->initialized)
        ma_sound_set_looping(&m_impl->sound, looping ? MA_TRUE : MA_FALSE);
    m_impl->silentLooping = looping;
}

bool Sound::looping() const
{
    return m_impl->initialized ? ma_sound_is_looping(&m_impl->sound) != 0 : m_impl->silentLooping;
}

} // namespace audio
