#pragma once

// Defences against the desktop behaviours Steam's controller layout triggers.
//
// Three of them, all here so the guesswork in each lives in one place:
// SteamKeyboardGuard shuts the on-screen keyboard that B opens, StartMenuGuard
// swallows the Windows key that L5 types before the shell can open Start, and
// CursorMotionGuard drops the pointer motion the pad injects.
//
// Steam reads the controller's HID stream alongside the examples and applies its
// desktop layout, which puts the on-screen keyboard on B. The keyboard lands on top
// of whatever example is running and takes focus with it. Nothing on the device side
// stops it: this hardware ignores the old "lizard mode" commands, and the keyboard is
// Steam's own window, opened by Steam, not something the pad sends.
//
// So the only lever is to shut that window again as it opens. A WinEvent hook beats
// polling for it: EVENT_OBJECT_SHOW fires before the window has painted, so the
// keyboard mostly never becomes visible. Out-of-context hooks are delivered through
// the installing thread's message queue, which glfwPollEvents() already services, so
// the callback runs on the main thread and needs no locking.
//
// The match is deliberately loose -- a visible, Steam-owned, always-on-top top-level
// window -- because Steam's window class and title for the keyboard move between
// client builds. The topmost test is what spares the main client window and its
// dialogs, which aren't topmost. lastHidden() and lastSeen() report what it caught
// and what it passed over, so a miss on some future client build can be diagnosed and
// looksLikeKeyboard() tightened to the real class/title.
//
// Nothing is suppressed unless setArmed(true); the examples arm this only while one of
// their windows has focus, so a keyboard opened over any other application is left
// alone. Off Windows every entry point compiles to a no-op.

#include <slang.h>

#include <string>

#if SLANG_WINDOWS_FAMILY
#define SLANG_RHI_HAS_STEAM_KEYBOARD_GUARD 1
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <algorithm>
#include <cctype>
#include <unordered_map>
#else
#define SLANG_RHI_HAS_STEAM_KEYBOARD_GUARD 0
#endif

namespace rhi {

#if SLANG_RHI_HAS_STEAM_KEYBOARD_GUARD

namespace steam_keyboard_detail {

// Image name for a pid ("steam.exe"), or "?" if it can't be read.
inline std::string exeName(DWORD pid)
{
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process)
    {
        return "?";
    }
    char path[MAX_PATH] = {};
    DWORD length = MAX_PATH;
    std::string name = "?";
    if (QueryFullProcessImageNameA(process, 0, path, &length))
    {
        std::string full(path, length);
        size_t slash = full.find_last_of("\\/");
        name = (slash == std::string::npos) ? full : full.substr(slash + 1);
    }
    CloseHandle(process);
    return name;
}

inline bool equalsNoCase(const std::string& a, const std::string& b)
{
    return a.size() == b.size() && std::equal(
                                       a.begin(),
                                       a.end(),
                                       b.begin(),
                                       [](char x, char y)
                                       {
                                           return std::tolower((unsigned char)x) ==
                                                  std::tolower((unsigned char)y);
                                       }
                                   );
}

inline bool containsNoCase(const std::string& haystack, const std::string& needle)
{
    return std::search(
               haystack.begin(),
               haystack.end(),
               needle.begin(),
               needle.end(),
               [](char a, char b)
               { return std::tolower((unsigned char)a) == std::tolower((unsigned char)b); }
           ) != haystack.end();
}

inline bool isSteamPid(DWORD pid)
{
    // pids get recycled, so bound the map rather than letting a long session grow it.
    static std::unordered_map<DWORD, bool> cache;
    if (cache.size() > 256)
    {
        cache.clear();
    }
    auto it = cache.find(pid);
    if (it != cache.end())
    {
        return it->second;
    }
    std::string exe = exeName(pid);
    bool isSteam = equalsNoCase(exe, "steam.exe") || equalsNoCase(exe, "steamwebhelper.exe") ||
                   equalsNoCase(exe, "gameoverlayui.exe");
    cache[pid] = isSteam;
    return isSteam;
}

} // namespace steam_keyboard_detail

class SteamKeyboardGuard
{
public:
    ~SteamKeyboardGuard() { uninstall(); }

    // Install on the thread that pumps messages; the callback arrives there.
    void install()
    {
        if (m_hook)
        {
            return;
        }
        s_active = this;
        m_hook = SetWinEventHook(
            EVENT_OBJECT_SHOW,
            EVENT_OBJECT_SHOW,
            nullptr,
            &SteamKeyboardGuard::winEventProc,
            0,
            0,
            WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS
        );
    }

    void uninstall()
    {
        m_armed = false;
        if (m_hook)
        {
            UnhookWinEvent(m_hook);
        }
        m_hook = nullptr;
        if (s_active == this)
        {
            s_active = nullptr;
        }
    }

    void setArmed(bool armed) { m_armed = armed; }

    // True once after a keyboard was hidden: the caller should re-focus its own window,
    // since focus went with the keyboard.
    bool takeFocusRequest()
    {
        bool request = m_refocus;
        m_refocus = false;
        return request;
    }

    int hiddenCount() const { return m_hidden; }
    const std::string& lastHidden() const { return m_lastHidden; }
    const std::string& lastSeen() const { return m_lastSeen; }

private:
    static bool looksLikeKeyboard(HWND window, const std::string& title)
    {
        if (steam_keyboard_detail::containsNoCase(title, "keyboard"))
        {
            return true;
        }
        // The keyboard is a borderless always-on-top overlay; the main client window
        // and its dialogs aren't topmost, so they survive this.
        return (GetWindowLongW(window, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
    }

    void onWindowShown(HWND window)
    {
        if (!m_armed || !IsWindowVisible(window) || GetAncestor(window, GA_ROOT) != window)
        {
            return;
        }

        DWORD pid = 0;
        GetWindowThreadProcessId(window, &pid);
        if (!pid || pid == GetCurrentProcessId() || !steam_keyboard_detail::isSteamPid(pid))
        {
            return;
        }

        char className[128] = {};
        char title[192] = {};
        GetClassNameA(window, className, sizeof(className));
        GetWindowTextA(window, title, sizeof(title));
        std::string description = std::string(className) + " / \"" + title + "\"";

        if (!looksLikeKeyboard(window, title))
        {
            m_lastSeen = description;
            return;
        }

        ShowWindowAsync(window, SW_HIDE);
        ++m_hidden;
        m_lastHidden = description;
        m_refocus = true;
    }

    static void CALLBACK winEventProc(
        HWINEVENTHOOK,
        DWORD,
        HWND window,
        LONG object,
        LONG child,
        DWORD,
        DWORD
    )
    {
        if (!window || object != OBJID_WINDOW || child != CHILDID_SELF || !s_active)
        {
            return;
        }
        s_active->onWindowShown(window);
    }

    HWINEVENTHOOK m_hook = nullptr;
    bool m_armed = false;
    bool m_refocus = false;
    int m_hidden = 0;
    std::string m_lastHidden;
    std::string m_lastSeen;

    inline static SteamKeyboardGuard* s_active = nullptr;
};

// Swallows the Windows key, which is what Steam's desktop layout types for L5.
//
// Unlike the keyboard above, this can't be cleaned up after the fact: the shell opens
// Start itself, in response to the keystroke, before any of our code runs. The only
// place to stop it is ahead of the shell, which is what a WH_KEYBOARD_LL hook is --
// it sees keys before they are dispatched anywhere, and returning non-zero drops them.
//
// Only VK_LWIN and VK_RWIN are ever dropped, and only while armed, so every other key
// (and every key at all once focus leaves) is passed straight through untouched. The
// hook procedure stays trivial on purpose: Windows silently unhooks a low-level hook
// that takes too long to answer. It also fails safe, since Windows removes the hook
// when the process dies.
//
// Note this takes Win+L, Win+Tab and the rest with it while an example has focus --
// that is the same keystroke, and there's no way to drop the pad's copy while keeping
// yours.
class StartMenuGuard
{
public:
    ~StartMenuGuard() { uninstall(); }

    // Install on the thread that pumps messages; the callback arrives there.
    void install()
    {
        if (m_hook)
        {
            return;
        }
        m_hook = SetWindowsHookExW(
            WH_KEYBOARD_LL,
            &StartMenuGuard::keyboardProc,
            GetModuleHandleW(nullptr),
            0
        );
    }

    void uninstall()
    {
        s_armed = false;
        if (m_hook)
        {
            UnhookWindowsHookEx(m_hook);
        }
        m_hook = nullptr;
    }

    void setArmed(bool armed) { s_armed = armed; }

    // How many Windows-key presses have been dropped. If L5 still opens Start while
    // this stays at zero, the layout is typing something else for it (Ctrl+Esc also
    // opens Start) and this guard is looking for the wrong key.
    int suppressedCount() const { return s_suppressed; }

private:
    static LRESULT CALLBACK keyboardProc(int code, WPARAM wparam, LPARAM lparam)
    {
        // Keep this trivial -- see the note about the low-level hook timeout above.
        if (code == HC_ACTION && s_armed)
        {
            const KBDLLHOOKSTRUCT* event = (const KBDLLHOOKSTRUCT*)lparam;
            if (event->vkCode == VK_LWIN || event->vkCode == VK_RWIN)
            {
                if (wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN)
                {
                    ++s_suppressed;
                }
                return 1; // swallow both the press and the release
            }
        }
        return CallNextHookEx(nullptr, code, wparam, lparam);
    }

    HHOOK m_hook = nullptr;

    // Read from the hook procedure, which runs on the installing thread, so these need
    // no synchronization -- but they must be reachable from a static function.
    inline static bool s_armed = false;
    inline static int s_suppressed = 0;
};

// Drops the pointer motion Steam Input injects for the pad's stick and trackpads.
//
// The pad doesn't move the pointer -- Steam does, on its behalf, by calling SendInput.
// That is the thing worth knowing here: input that arrives through SendInput is flagged
// LLMHF_INJECTED, so a WH_MOUSE_LL hook can tell it apart from a hand on a real mouse
// and drop only the synthetic half. Blocking WM_MOUSEMOVE outright would work too, and
// would take your actual mouse with it.
//
// Only motion is dropped. Injected buttons still go through, so anything bound to a
// click keeps working, and so does the click that re-arms cursor hiding.
//
// The same caveats as StartMenuGuard apply: the hook procedure stays trivial because
// Windows unhooks a slow one, and Windows removes the hook if the process dies. Note
// that anything else injecting motion -- remote desktop, pointer-automation utilities,
// some vendor mouse software -- is dropped too while an example has focus, since
// "injected" is all the flag tells us.
class CursorMotionGuard
{
public:
    ~CursorMotionGuard() { uninstall(); }

    // Install on the thread that pumps messages; the callback arrives there.
    void install()
    {
        if (m_hook)
        {
            return;
        }
        m_hook = SetWindowsHookExW(
            WH_MOUSE_LL,
            &CursorMotionGuard::mouseProc,
            GetModuleHandleW(nullptr),
            0
        );
    }

    void uninstall()
    {
        s_armed = false;
        if (m_hook)
        {
            UnhookWindowsHookEx(m_hook);
        }
        m_hook = nullptr;
    }

    void setArmed(bool armed) { s_armed = armed; }

    // How many injected moves have been dropped. Zero while the pad is visibly dragging
    // the pointer would mean the motion isn't arriving injected, and this is the wrong
    // lever for it.
    int suppressedCount() const { return s_suppressed; }

private:
    static LRESULT CALLBACK mouseProc(int code, WPARAM wparam, LPARAM lparam)
    {
        // Keep this trivial -- see the note about the low-level hook timeout above.
        if (code == HC_ACTION && s_armed && wparam == WM_MOUSEMOVE)
        {
            const MSLLHOOKSTRUCT* event = (const MSLLHOOKSTRUCT*)lparam;
            if (event->flags & (LLMHF_INJECTED | LLMHF_LOWER_IL_INJECTED))
            {
                ++s_suppressed;
                return 1; // swallow it
            }
        }
        return CallNextHookEx(nullptr, code, wparam, lparam);
    }

    HHOOK m_hook = nullptr;

    // Read from the hook procedure, which runs on the installing thread, so these need
    // no synchronization -- but they must be reachable from a static function.
    inline static bool s_armed = false;
    inline static int s_suppressed = 0;
};

#else // nothing here to suppress

class SteamKeyboardGuard
{
public:
    void install() {}
    void uninstall() {}
    void setArmed(bool) {}
    bool takeFocusRequest() { return false; }
    int hiddenCount() const { return 0; }
    const std::string& lastHidden() const { return m_empty; }
    const std::string& lastSeen() const { return m_empty; }

private:
    std::string m_empty;
};

class StartMenuGuard
{
public:
    void install() {}
    void uninstall() {}
    void setArmed(bool) {}
    int suppressedCount() const { return 0; }
};

class CursorMotionGuard
{
public:
    void install() {}
    void uninstall() {}
    void setArmed(bool) {}
    int suppressedCount() const { return 0; }
};

#endif

} // namespace rhi
