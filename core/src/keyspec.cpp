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

unsigned modifier_bit(const std::string &t) {
    if (t == "alt" || t == "opt" || t == "option") return kModAlt;
    if (t == "shift") return kModShift;
    if (t == "ctrl" || t == "control") return kModCtrl;
    if (t == "cmd" || t == "command") return kModCmd;
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
    std::vector<std::string> tokens;
    size_t start = 0;
    for (size_t i = 0; i <= text.size(); ++i) {
        if (i == text.size() || text[i] == '+') {
            tokens.push_back(lower_ascii(text.substr(start, i - start)));
            start = i + 1;
        }
    }
    int keys = 0;
    for (size_t i = 0; i < tokens.size(); ++i) {
        const std::string &t = tokens[i];
        if (t.empty()) return "empty element in " + quote(std::string(text)) + " (stray '+')";
        if (unsigned bit = modifier_bit(t)) {
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
    if (key_required && keys == 0) return "needs exactly one key (for example 'alt+shift+f')";
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
    return "";
}

std::string extras_to_json(const Extras &e) {
    std::string out = "{\"keys\":{\"throw\":";
    json_string(out, format_chord(e.keys.throw_to));
    out += ",\"toggle_float\":";
    json_string(out, format_chord(e.keys.toggle_float));
    out += ",\"switch\":";
    json_string(out, format_chord(e.keys.switch_to));
    out += "},\"rules\":{\"ignore\":";
    json_list(out, e.rules.ignore);
    out += ",\"float\":";
    json_list(out, e.rules.float_);
    out += "}}";
    return out;
}

}  // namespace hypr
