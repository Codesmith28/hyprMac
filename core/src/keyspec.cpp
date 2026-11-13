// Key-binding grammar, cross-field validation and the extras JSON.
#include "hypr/keyspec.hpp"

#include <cctype>
#include <cstdio>

namespace hypr {
namespace {

std::string lower_ascii(std::string_view s) {
    std::string out(s);
    for (char &c : out) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return out;
}

unsigned modifier_bit(const std::string &t, bool allow_single_letter = false) {
    if (t == "alt" || t == "opt" || t == "option" || t == "meta") return kModAlt;
    if (t == "shift") return kModShift;
    if (t == "ctrl" || t == "control") return kModCtrl;
    if (t == "cmd" || t == "command" || t == "super") return kModCmd;
    if (allow_single_letter) {
        if (t == "m" || t == "a") return kModAlt;
        if (t == "s") return kModShift;
        if (t == "c") return kModCtrl;
        if (t == "d") return kModCmd;
    }
    return 0;
}

const char *const kNamedKeys[] = {"space", "tab", "return", "escape", "grave", "minus", "equal", "comma", "period", "slash", "left", "right", "up", "down"};

std::string quote(const std::string &s) { return "'" + s + "'"; }

void json_string(std::string &out, const std::string &s) {
    out += '"';
    for (unsigned char c : s) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char buf[8];
                std::snprintf(buf, sizeof buf, "\\u%04x", c);
                out += buf;
            } else {
                out += static_cast<char>(c);
            }
        }
    }
    out += '"';
}

void json_list(std::string &out, const std::vector<std::string> &v) {
    out += '[';
    for (size_t i = 0; i < v.size(); ++i) {
        if (i) out += ',';
        json_string(out, v[i]);
    }
    out += ']';
}

}  // namespace

bool is_key_name(std::string_view name) {
    if (name.size() == 1) return std::isalnum(static_cast<unsigned char>(name[0])) && !std::isupper(static_cast<unsigned char>(name[0]));
    if (name.size() >= 2 && name.size() <= 3 && name[0] == 'f') {
        int n = 0;
        for (size_t i = 1; i < name.size(); ++i) {
            if (!std::isdigit(static_cast<unsigned char>(name[i]))) return false;
            n = n * 10 + (name[i] - '0');
        }
        return name[1] != '0' && n >= 1 && n <= 12;
    }
    for (const char *k : kNamedKeys)
        if (name == k) return true;
    return false;
}

std::string parse_chord(std::string_view text, bool key_required, Chord &out) {
    out = Chord{};
    if (text.empty()) return "must not be empty";
    bool is_bracketed = (text.size() >= 3 && text.front() == '<' && text.back() == '>');
    std::string_view inner = is_bracketed ? text.substr(1, text.size() - 2) : text;
    std::vector<std::string> tokens;
    size_t start = 0;
    for (size_t i = 0; i <= inner.size(); ++i) {
        if (i == inner.size() || inner[i] == '+' || (is_bracketed && inner[i] == '-') || (!is_bracketed && inner[i] == ' ')) {
            std::string tok = lower_ascii(inner.substr(start, i - start));
            if (!tok.empty() || i == inner.size() || inner[i] == '+') {
                tokens.push_back(std::move(tok));
            }
            start = i + 1;
        }
    }
    int keys = 0;
    for (size_t i = 0; i < tokens.size(); ++i) {
        const std::string &t = tokens[i];
        if (t.empty()) {
            std::string stray = is_bracketed ? "'-'" : "'+'";
            return "empty element in " + quote(std::string(text)) + " (stray " + stray + ")";
        }
        bool allow_single = is_bracketed && (!key_required || i + 1 < tokens.size());
        if (unsigned bit = modifier_bit(t, allow_single)) {
            if (out.mods & bit) return "duplicate modifier " + quote(t);
            out.mods |= bit;
            continue;
        }
        if (is_key_name(t)) {
            if (!key_required) return quote(t) + " is a key; this binding takes modifiers only";
            if (++keys > 1) return "more than one key in " + quote(std::string(text));
            out.key = t;
            continue;
        }
        if (key_required && i + 1 == tokens.size()) return "unknown key " + quote(t);
        return "unknown modifier " + quote(t);
    }
    if (out.mods == 0) return "needs at least one modifier";
    if (key_required && keys == 0) return "needs exactly one key (for example 'alt+shift+f' or '<M-S-f>')";
    return "";
}

std::string format_chord(const Chord &c) {
    std::string s;
    auto add = [&](const char *n) { if (!s.empty()) s += '+'; s += n; };
    if (c.mods & kModCtrl) add("ctrl");
    if (c.mods & kModAlt) add("alt");
    if (c.mods & kModShift) add("shift");
    if (c.mods & kModCmd) add("cmd");
    if (!c.key.empty()) add(c.key.c_str());
    return s;
}

std::string validate_keys(const Keys &k) {
    if (k.throw_to.mods == k.switch_to.mods)
        return "keys.throw: must differ from keys.switch (both are '" + format_chord(k.throw_to) + "')";
    if (k.toggle_float.mods == k.throw_to.mods && k.toggle_float.key.size() == 1 && k.toggle_float.key[0] >= '1' &&
        k.toggle_float.key[0] <= '9')
        return "keys.toggle_float: conflicts with the throw shortcut for Desktop " + k.toggle_float.key;

    // The unbound-by-default actions must not shadow ⌥⇧1-9 / ⌥1-9 (Desktop throw and switch).
    for (const ActionKey &a : kActionKeys) {
        const Chord &c = k.*(a.chord);
        if (c.key.empty()) continue;
        const bool digit = c.key.size() == 1 && c.key[0] >= '1' && c.key[0] <= '9';
        if (digit && c.mods == k.throw_to.mods)
            return std::string("keys.") + a.name + ": conflicts with the throw shortcut for Desktop " + c.key;
        if (digit && c.mods == k.switch_to.mods)
            return std::string("keys.") + a.name + ": conflicts with the Desktop switch shortcut for Desktop " + c.key;
    }

    // Duplicates that involve at least one of the new actions. The default focus/move/center
    // shortcuts count while they are in effect (focus_* / move_* replace them as soon as one is set).
    struct Entry {
        std::string name;
        Chord chord;
        bool is_new;
    };
    std::vector<Entry> all;
    all.push_back({"keys.toggle_float", k.toggle_float, false});
    const Chord prefix{kModAlt | kModShift, ""};
    const Chord moves{kModAlt | kModShift | kModCmd, ""};
    all.push_back({k.center_window.key.empty() ? "the default center_window shortcut" : "keys.center_window",
                   k.center_window.key.empty() ? Chord{prefix.mods, "c"} : k.center_window, false});
    const struct { const char *name; const Chord *set; Chord base; } groups[] = {
        {"focus", &k.focus_left, prefix}, {"move", &k.move_left, moves}};
    for (const auto &g : groups) {
        const Chord *first = g.set; // four consecutive members: left, down, up, right
        const char *dirs[] = {"left", "down", "up", "right"};
        const char *keys_hjkl[] = {"h", "j", "k", "l"};
        const char *keys_arrow[] = {"left", "down", "up", "right"};
        bool any = false;
        for (int i = 0; i < 4; ++i) any = any || !first[i].key.empty();
        for (int i = 0; i < 4; ++i) {
            const std::string name = std::string(g.name) + "_" + dirs[i];
            if (any) {
                if (!first[i].key.empty()) all.push_back({"keys." + name, first[i], false});
            } else {
                all.push_back({"the default " + name + " shortcut", Chord{g.base.mods, keys_hjkl[i]}, false});
                all.push_back({"the default " + name + " shortcut", Chord{g.base.mods, keys_arrow[i]}, false});
            }
        }
    }
    for (const ActionKey &a : kActionKeys)
        if (!(k.*(a.chord)).key.empty()) all.push_back({std::string("keys.") + a.name, k.*(a.chord), true});
    for (size_t j = 0; j < all.size(); ++j) {
        if (!all[j].is_new) continue;
        for (size_t i = 0; i < all.size(); ++i) {
            if (i == j || (all[i].is_new && i > j)) continue;
            if (all[i].chord.mods == all[j].chord.mods && all[i].chord.key == all[j].chord.key)
                return all[j].name + ": '" + format_chord(all[j].chord) + "' is already used by " + all[i].name;
        }
    }
    return "";
}

std::string extras_to_json(const Extras &e) {
    std::string out = "{\"keys\":{\"throw\":";
    json_string(out, format_chord(e.keys.throw_to));
    out += ",\"toggle_float\":";
    json_string(out, format_chord(e.keys.toggle_float));
    out += ",\"switch\":";
    json_string(out, format_chord(e.keys.switch_to));
    if (e.keys.prefix.mods != 0) {
        out += ",\"prefix\":";
        json_string(out, format_chord(e.keys.prefix));
    }
    if (!e.keys.center_window.key.empty()) {
        out += ",\"center_window\":";
        json_string(out, format_chord(e.keys.center_window));
    }
    if (!e.keys.focus_left.key.empty()) {
        out += ",\"focus_left\":";
        json_string(out, format_chord(e.keys.focus_left));
    }
    if (!e.keys.focus_down.key.empty()) {
        out += ",\"focus_down\":";
        json_string(out, format_chord(e.keys.focus_down));
    }
    if (!e.keys.focus_up.key.empty()) {
        out += ",\"focus_up\":";
        json_string(out, format_chord(e.keys.focus_up));
    }
    if (!e.keys.focus_right.key.empty()) {
        out += ",\"focus_right\":";
        json_string(out, format_chord(e.keys.focus_right));
    }
    if (!e.keys.move_left.key.empty()) {
        out += ",\"move_left\":";
        json_string(out, format_chord(e.keys.move_left));
    }
    if (!e.keys.move_down.key.empty()) {
        out += ",\"move_down\":";
        json_string(out, format_chord(e.keys.move_down));
    }
    if (!e.keys.move_up.key.empty()) {
        out += ",\"move_up\":";
        json_string(out, format_chord(e.keys.move_up));
    }
    if (!e.keys.move_right.key.empty()) {
        out += ",\"move_right\":";
        json_string(out, format_chord(e.keys.move_right));
    }
    for (const ActionKey &a : kActionKeys) {
        const Chord &c = e.keys.*(a.chord);
        if (c.key.empty()) continue;
        out += ",\"";
        out += a.name;
        out += "\":";
        json_string(out, format_chord(c));
    }
    out += "},\"rules\":{\"ignore\":";
    json_list(out, e.rules.ignore);
    out += ",\"float\":";
    json_list(out, e.rules.float_);
    if (!e.rules.float_title.empty()) {
        out += ",\"float_title\":";
        json_list(out, e.rules.float_title);
    }
    if (!e.rules.ignore_title.empty()) {
        out += ",\"ignore_title\":";
        json_list(out, e.rules.ignore_title);
    }
    if (!e.rules.desktop.empty()) {
        out += ",\"desktop\":{";
        for (size_t i = 0; i < e.rules.desktop.size(); ++i) {
            if (i) out += ',';
            json_string(out, e.rules.desktop[i].first);
            out += ":" + std::to_string(e.rules.desktop[i].second);
        }
        out += "}";
    }
    out += "},\"osd_popup\":";
    out += e.osd_popup ? "true" : "false";
    if (e.smart_gaps) out += ",\"smart_gaps\":true";
    if (e.focus_follows_mouse) out += ",\"focus_follows_mouse\":true";
    if (!e.displays.empty()) {
        out += ",\"displays\":{";
        for (size_t i = 0; i < e.displays.size(); ++i) {
            if (i) out += ',';
            json_string(out, e.displays[i].name);
            out += ":{";
            bool first = true;
            char buf[32];
            if (e.displays[i].inner >= 0) {
                std::snprintf(buf, sizeof buf, "%.10g", e.displays[i].inner);
                out += std::string("\"inner\":") + buf;
                first = false;
            }
            if (e.displays[i].outer >= 0) {
                std::snprintf(buf, sizeof buf, "%.10g", e.displays[i].outer);
                out += std::string(first ? "" : ",") + "\"outer\":" + buf;
            }
            out += "}";
        }
        out += "}";
    }
    out += "}";
    return out;
}

}  // namespace hypr
