#pragma once
// Key-binding grammar and the "extras" (keys + rules) of the Lua configuration.
// Pure C++ so doctest covers it; Swift maps the canonical names to key codes.
#include "hypr/rules.hpp"

#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace hypr {

inline constexpr unsigned kModCtrl = 1u;
inline constexpr unsigned kModAlt = 2u;
inline constexpr unsigned kModShift = 4u;
inline constexpr unsigned kModCmd = 8u;
inline constexpr size_t kMaxRuleEntries = 200;

struct Chord {
    unsigned mods = 0;
    std::string key;  // canonical lower-case key name; empty for modifier-only chords
};

// Parses "alt+shift+f" (case-insensitive, '+'-separated).
// `key_required`: exactly one key plus at least one modifier; otherwise modifiers only
// (at least one). Returns "" on success, else a message without any "keys.<name>:" prefix.
std::string parse_chord(std::string_view text, bool key_required, Chord &out);

// Canonical text: modifiers in the order ctrl, alt, shift, cmd, then the key.
std::string format_chord(const Chord &c);

// True when `name` is a canonical key name (a–z, 0–9, f1–f12, space, tab, return, escape, grave,
// minus, equal, comma, period, slash).
bool is_key_name(std::string_view name);

struct Keys {
    Chord throw_to{kModAlt | kModShift, ""};
    Chord toggle_float{kModAlt | kModShift, "f"};
    Chord switch_to{kModAlt, ""};
    Chord prefix{0, ""};
    Chord center_window{0, ""};
    Chord focus_left{0, ""};
    Chord focus_down{0, ""};
    Chord focus_up{0, ""};
    Chord focus_right{0, ""};
    Chord move_left{0, ""};
    Chord move_down{0, ""};
    Chord move_up{0, ""};
    Chord move_right{0, ""};
};

struct Rules {
    std::vector<std::string> ignore;
    std::vector<std::string> float_;
    std::vector<std::string> float_title;   // title regexes (see rules.hpp)
    std::vector<std::string> ignore_title;
    std::vector<std::pair<std::string, int>> desktop;  // bundle id -> Desktop N, sorted by bundle id
};

struct Extras {
    Keys keys;
    Rules rules;
    bool osd_popup = true;
    bool smart_gaps = false;
    bool focus_follows_mouse = false;
    std::vector<DisplayGaps> displays;  // sorted by name
};

// Cross-field checks (throw vs switch, toggle_float vs throw digits). "" when fine, else a
// message that already carries its "keys.<name>:" prefix.
std::string validate_keys(const Keys &keys);

// Compact JSON: {"keys":{"throw":"alt+shift","toggle_float":"alt+shift+f","switch":"alt"},
//                "rules":{"ignore":[...],"float":[...]}}
// v0.3.0 options appear only when set (default = absent): rules.float_title / ignore_title (lists),
// rules.desktop ({"bundle.id":3}), and top-level "smart_gaps", "focus_follows_mouse" (true) and
// "displays" ({"Name":{"inner":4,"outer":8}}, unset gaps omitted).
std::string extras_to_json(const Extras &extras);

}  // namespace hypr
