#pragma once

// Sound for the example host, on miniaudio (github.com/mackron/miniaudio).
//
// A small interface over it, so that example-lua.cpp needs none of miniaudio's headers:
// sounds loaded from files (WAV, FLAC, MP3, by their contents, whatever their extension),
// streamed from disk as they play, mixed by one engine on the default output device. The
// engine starts with the first sound and stops after the last one is gone.
//
// Without an audio device (or if it fails to start), sounds still load and answer, but
// stay silent: a script runs the same everywhere.

#include <filesystem>
#include <memory>
#include <string>

namespace audio {

class Sound
{
public:
    // Opens `path` for streaming; nullptr and `error` if the file can't be read or decoded.
    // `silent` is set if there is no audio device to play it on.
    static std::unique_ptr<Sound> load(const std::filesystem::path& path, std::string& error, bool& silent);
    ~Sound();

    void play();               // from where it is
    void pause();              // stays where it is
    void seek(double seconds); // from the start
    bool playing() const;
    double position() const;   // seconds from the start
    double length() const;     // seconds

    void setVolume(float volume); // 1: as recorded
    float volume() const;
    void setLooping(bool looping);
    bool looping() const;

private:
    struct Impl;
    explicit Sound(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> m_impl;
};

} // namespace audio
