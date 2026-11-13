// Lua configuration loader: hm_config_load_file / hm_config_load_string.
//
// The user's init.lua runs in a sandboxed Lua 5.4 state:
//   * custom allocator capped at kMemLimit bytes;
//   * only base, string, math and table libraries;
//   * dofile/loadfile/load/require/collectgarbage removed, print is a no-op;
//   * a LUA_MASKCOUNT hook aborts after ~kInstrLimit VM instructions, and
//     pcall/xpcall are wrapped so the abort cannot be swallowed by the script.
//
// After the chunk runs, the global `config` table is checked against a strict
// schema (unknown keys and wrong types are errors) using raw accesses only, so
// no script code (metamethods) runs during the walk. Finally hypr::validate.
//
// Lua is compiled as C and reports errors with longjmp. Every C function that
// Lua may unwind through (hook, pcall wrappers, setup) therefore keeps only
// trivially destructible locals.
#include "hypr/config.hpp"
#include "hypr/hypr_core.h"
#include "hypr/keyspec.hpp"
#include "hypr/rules.hpp"

#include "lua.hpp"

#include <sys/stat.h>

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace {

constexpr size_t kMemLimit = 8u * 1024u * 1024u;        // 8 MB
constexpr long kInstrLimit = 10'000'000;                // ~10M VM instructions
constexpr int kHookEvery = 1000;                        // hook granularity
constexpr size_t kMaxSourceBytes = 256u * 1024u;        // 256 KB
constexpr const char *kChunkTag = "@@hyprcfg@@";        // replaced by the path in messages
constexpr const char *kTimeoutMsg = "configuration took too long";

struct Sandbox {
    size_t used = 0;
    size_t limit = kMemLimit;
    bool alloc_refused = false;
    long instructions = 0;
    bool tripped = false;          // time limit hit: every hook / pcall rethrows
    char timeout_msg[160] = {0};   // "<tag>:<line>: configuration took too long"
};

void *sandbox_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    auto *sb = static_cast<Sandbox *>(ud);
    if (ptr == nullptr) osize = 0;  // osize encodes the object type when ptr is NULL
    if (nsize == 0) {
        std::free(ptr);
        sb->used -= osize;
        return nullptr;
    }
    if (nsize > osize && sb->used - osize + nsize > sb->limit) {
        sb->alloc_refused = true;
        return nullptr;  // Lua raises "not enough memory"
    }
    void *p = std::realloc(ptr, nsize);
    if (p == nullptr) {
        sb->alloc_refused = true;
        return nullptr;
    }
    sb->used = sb->used - osize + nsize;
    return p;
}

Sandbox *sandbox_of(lua_State *L) {
    void *ud = nullptr;
    lua_getallocf(L, &ud);
    return static_cast<Sandbox *>(ud);
}

[[noreturn]] void throw_timeout(lua_State *L, Sandbox *sb) {
    lua_pushstring(L, sb->timeout_msg[0] ? sb->timeout_msg : kTimeoutMsg);
    lua_error(L);
    std::abort();  // unreachable: lua_error never returns
}

void count_hook(lua_State *L, lua_Debug *ar) {
    Sandbox *sb = sandbox_of(L);
    sb->instructions += kHookEvery;
    if (!sb->tripped && sb->instructions < kInstrLimit) return;
    if (!sb->tripped) {
        sb->tripped = true;
        int line = -1;
        if (lua_getinfo(L, "Sl", ar) && ar->currentline > 0) line = ar->currentline;
        if (line > 0)
            std::snprintf(sb->timeout_msg, sizeof sb->timeout_msg, "%s:%d: %s", ar->short_src, line,
                          kTimeoutMsg);
        else
            std::snprintf(sb->timeout_msg, sizeof sb->timeout_msg, "%s", kTimeoutMsg);
    }
    throw_timeout(L, sb);
}

int noop_print(lua_State *) { return 0; }

// pcall/xpcall wrapper: upvalue 1 is the original function. If the time limit
// tripped while the protected call ran, re-raise instead of returning false.
int guarded_pcall(lua_State *L) {
    int n = lua_gettop(L);
    lua_pushvalue(L, lua_upvalueindex(1));
    lua_insert(L, 1);
    lua_call(L, n, LUA_MULTRET);
    Sandbox *sb = sandbox_of(L);
    if (sb->tripped) throw_timeout(L, sb);
    return lua_gettop(L);
}

// setmetatable wrapper: Lua runs __gc finalizers with debug hooks disabled,
// so a looping finalizer would escape the instruction limit. Lua 5.4 only
// marks an object for finalization when its metatable has __gc at the moment
// setmetatable is called, and debug.setmetatable is not available, so
// rejecting __gc here is sufficient.
int guarded_setmetatable(lua_State *L) {
    if (lua_type(L, 2) == LUA_TTABLE) {
        lua_pushliteral(L, "__gc");
        int t = lua_rawget(L, 2);
        lua_pop(L, 1);
        if (t != LUA_TNIL) return luaL_error(L, "__gc metamethods are not allowed in the configuration");
    }
    int n = lua_gettop(L);
    lua_pushvalue(L, lua_upvalueindex(1));
    lua_insert(L, 1);
    lua_call(L, n, LUA_MULTRET);
    return lua_gettop(L);
}

void wrap_global(lua_State *L, const char *name, lua_CFunction wrapper) {
    lua_getglobal(L, name);
    lua_pushcclosure(L, wrapper, 1);
    lua_setglobal(L, name);
}

// Runs under lua_pcall so that allocation failures are reported, not fatal.
int setup_state(lua_State *L) {
    luaL_requiref(L, LUA_GNAME, luaopen_base, 1);
    luaL_requiref(L, LUA_STRLIBNAME, luaopen_string, 1);
    luaL_requiref(L, LUA_MATHLIBNAME, luaopen_math, 1);
    luaL_requiref(L, LUA_TABLIBNAME, luaopen_table, 1);
    lua_settop(L, 0);
    static const char *const removed[] = {"dofile", "loadfile", "load", "require", "collectgarbage"};
    for (const char *name : removed) {
        lua_pushnil(L);
        lua_setglobal(L, name);
    }
    lua_pushcfunction(L, noop_print);
    lua_setglobal(L, "print");
    wrap_global(L, "pcall", guarded_pcall);
    wrap_global(L, "xpcall", guarded_pcall);
    wrap_global(L, "setmetatable", guarded_setmetatable);
    return 0;
}

// ---------- error helpers ----------

void write_err(char *err, size_t cap, const std::string &msg) {
    if (err == nullptr || cap == 0) return;
    size_t n = std::min(msg.size(), cap - 1);
    std::memcpy(err, msg.data(), n);
    err[n] = '\0';
}

std::string replace_all(std::string s, std::string_view from, std::string_view to) {
    size_t pos = 0;
    while ((pos = s.find(from, pos)) != std::string::npos) {
        s.replace(pos, from.size(), to);
        pos += to.size();
    }
    return s;
}

// Turn a Lua error message (which uses kChunkTag as its chunk name) into
// "<path>:<line>: msg", or "<path>: msg" when Lua did not attach a position.
std::string format_lua_message(std::string msg, const std::string &path) {
    msg = replace_all(std::move(msg), kChunkTag, path);
    if (msg.compare(0, path.size() + 1, path + ":") == 0) return msg;
    return path + ": " + msg;
}

// Reads the error object at the top of the stack without calling any API
// that could allocate (lua_tostring would convert numbers in place).
std::string error_object_text(lua_State *L) {
    switch (lua_type(L, -1)) {
    case LUA_TSTRING: {
        size_t len = 0;
        const char *s = lua_tolstring(L, -1, &len);
        return std::string(s, len);
    }
    case LUA_TNUMBER:
        if (lua_isinteger(L, -1)) return std::to_string(lua_tointeger(L, -1));
        {
            char buf[64];
            std::snprintf(buf, sizeof buf, "%.14g", static_cast<double>(lua_tonumber(L, -1)));
            return buf;
        }
    default:
        return std::string("(error object is a ") + luaL_typename(L, -1) + " value)";
    }
}

// ---------- schema ----------

size_t edit_distance(std::string_view a, std::string_view b) {
    std::vector<size_t> prev(b.size() + 1), cur(b.size() + 1);
    for (size_t j = 0; j <= b.size(); ++j) prev[j] = j;
    for (size_t i = 1; i <= a.size(); ++i) {
        cur[0] = i;
        for (size_t j = 1; j <= b.size(); ++j) {
            size_t sub = prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1);
            cur[j] = std::min({prev[j] + 1, cur[j - 1] + 1, sub});
        }
        std::swap(prev, cur);
    }
    return prev[b.size()];
}

std::string lower(std::string_view s) {
    std::string out(s);
    for (char &c : out) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return out;
}

std::string suggest(std::string_view key, const std::vector<std::string_view> &known) {
    std::string lk = lower(key);
    std::string best;
    size_t best_d = SIZE_MAX;
    for (auto k : known) {
        std::string lkn = lower(k);
        size_t d = edit_distance(lk, lkn);
        bool close = d <= 2 && d < lk.size();
        bool contains = lk.size() >= 3 && (lkn.find(lk) != std::string::npos || lk.find(lkn) != std::string::npos);
        if ((close || contains) && d < best_d) {
            best_d = d;
            best = std::string(k);
        }
    }
    return best;
}

std::string describe_key(lua_State *L, int idx) {
    switch (lua_type(L, idx)) {
    case LUA_TSTRING: {
        size_t len = 0;
        const char *s = lua_tolstring(L, idx, &len);
        return "'" + std::string(s, len) + "'";
    }
    case LUA_TNUMBER:
        // No lua_tostring here: it would allocate/convert in place during lua_next.
        return lua_isinteger(L, idx) ? "[" + std::to_string(lua_tointeger(L, idx)) + "]"
                                     : "[" + std::to_string(lua_tonumber(L, idx)) + "]";
    default:
        return std::string("of type ") + luaL_typename(L, idx);
    }
}

struct Field {
    std::string_view name;
    enum Kind { Number, Table, String, StringList, Boolean, DesktopMap, DisplayMap } kind;
    double *target;                          // Number
    std::vector<Field> children;             // Table
    std::optional<std::string> *str;         // String
    std::vector<std::string> *list;          // StringList
    bool *boolean;                           // Boolean
    std::vector<std::pair<std::string, int>> *desktop;  // DesktopMap
    std::vector<hypr::DisplayGaps> *displays;           // DisplayMap
    bool *seen;                              // Number: set when the key is present (optional)
};

Field num_field(std::string_view n, double *t) { return {n, Field::Number, t, {}, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr}; }
Field opt_num_field(std::string_view n, double *t, bool *seen) { return {n, Field::Number, t, {}, nullptr, nullptr, nullptr, nullptr, nullptr, seen}; }
Field table_field(std::string_view n, std::vector<Field> c) { return {n, Field::Table, nullptr, std::move(c), nullptr, nullptr, nullptr, nullptr, nullptr, nullptr}; }
Field str_field(std::string_view n, std::optional<std::string> *t) { return {n, Field::String, nullptr, {}, t, nullptr, nullptr, nullptr, nullptr, nullptr}; }
Field list_field(std::string_view n, std::vector<std::string> *t) { return {n, Field::StringList, nullptr, {}, nullptr, t, nullptr, nullptr, nullptr, nullptr}; }
Field bool_field(std::string_view n, bool *t) { return {n, Field::Boolean, nullptr, {}, nullptr, nullptr, t, nullptr, nullptr, nullptr}; }
Field desktop_field(std::string_view n, std::vector<std::pair<std::string, int>> *t) { return {n, Field::DesktopMap, nullptr, {}, nullptr, nullptr, nullptr, t, nullptr, nullptr}; }
Field displays_field(std::string_view n, std::vector<hypr::DisplayGaps> *t) { return {n, Field::DisplayMap, nullptr, {}, nullptr, nullptr, nullptr, nullptr, t, nullptr}; }

std::string check_table(lua_State *L, const std::string &where, const std::vector<Field> &fields);

// rules.desktop: { ["bundle.id"] = N }. The map is at the top of the stack. Raw API only.
std::string read_desktop_map(lua_State *L, const std::string &path, std::vector<std::pair<std::string, int>> *out) {
    const int t = lua_gettop(L);
    std::vector<std::pair<std::string, double>> items;
    std::string error;
    lua_pushnil(L);
    while (lua_next(L, t) != 0) {
        if (error.empty()) {
            if (lua_type(L, -2) != LUA_TSTRING) {
                error = path + " must map bundle ids to Desktop numbers (found key " + describe_key(L, -2) + ")";
            } else if (items.size() >= hypr::kMaxRuleEntries) {
                error = path + " has too many entries (max " + std::to_string(hypr::kMaxRuleEntries) + ")";
            } else if (lua_type(L, -1) != LUA_TNUMBER) {
                error = path + "[" + describe_key(L, -2) + "] must be a number, got " + luaL_typename(L, -1);
            } else {
                size_t len = 0;
                const char *k = lua_tolstring(L, -2, &len);
                items.emplace_back(std::string(k, len), static_cast<double>(lua_tonumber(L, -1)));
            }
        }
        lua_pop(L, 1);
    }
    if (!error.empty()) return error;
    std::sort(items.begin(), items.end());
    out->clear();
    for (const auto &it : items) {
        if (std::string e = hypr::validate_desktop_entry(it.first, it.second); !e.empty()) return path + ": " + e;
        out->emplace_back(it.first, static_cast<int>(it.second));
    }
    return "";
}

// config.displays: { ["Display Name"] = { inner = 4, outer = 8 } }. The map is at the top of the stack.
std::string read_display_map(lua_State *L, const std::string &path, std::vector<hypr::DisplayGaps> *out) {
    const int t = lua_gettop(L);
    std::vector<hypr::DisplayGaps> items;
    std::string error;
    lua_pushnil(L);
    while (lua_next(L, t) != 0) {
        if (error.empty()) {
            if (lua_type(L, -2) != LUA_TSTRING) {
                error = path + " must map display names to gap tables (found key " + describe_key(L, -2) + ")";
            } else if (items.size() >= hypr::kMaxDisplayEntries) {
                error = path + " has too many entries (max " + std::to_string(hypr::kMaxDisplayEntries) + ")";
            } else {
                size_t len = 0;
                const char *k = lua_tolstring(L, -2, &len);
                hypr::DisplayGaps d;
                d.name.assign(k, len);
                const std::string where = path + "[" + describe_key(L, -2) + "]";
                if (std::string e = hypr::validate_display_name(d.name); !e.empty()) {
                    error = path + ": " + e;
                } else if (lua_type(L, -1) != LUA_TTABLE) {
                    error = where + " must be a table, got " + luaL_typename(L, -1);
                } else {
                    double inner = 0, outer = 0;
                    bool has_inner = false, has_outer = false;
                    error = check_table(L, where, {opt_num_field("inner", &inner, &has_inner),
                                                   opt_num_field("outer", &outer, &has_outer)});
                    if (error.empty() && has_inner) {
                        error = hypr::validate_display_gap("inner", inner);
                        if (!error.empty()) error = where + "." + error;
                        d.inner = inner;
                    }
                    if (error.empty() && has_outer) {
                        error = hypr::validate_display_gap("outer", outer);
                        if (!error.empty()) error = where + "." + error;
                        d.outer = outer;
                    }
                    if (error.empty()) items.push_back(std::move(d));
                }
            }
        }
        lua_pop(L, 1);
    }
    if (!error.empty()) return error;
    std::sort(items.begin(), items.end(), [](const hypr::DisplayGaps &a, const hypr::DisplayGaps &b) { return a.name < b.name; });
    *out = std::move(items);
    return "";
}

// Reads the list at the top of the stack into `out`: a Lua sequence of non-empty strings,
// at most hypr::kMaxRuleEntries. Raw, non-allocating API only. Returns an error or "".
std::string read_string_list(lua_State *L, const std::string &path, std::vector<std::string> *out) {
    const int t = lua_gettop(L);
    std::vector<std::pair<lua_Integer, std::string>> items;
    std::string error;
    lua_pushnil(L);
    while (lua_next(L, t) != 0) {
        if (error.empty()) {
            if (!lua_isinteger(L, -2) || lua_tointeger(L, -2) < 1) {
                error = path + " must be a list of strings (found key " + describe_key(L, -2) + ")";
            } else if (items.size() >= hypr::kMaxRuleEntries) {
                error = path + " has too many entries (max " + std::to_string(hypr::kMaxRuleEntries) + ")";
            } else {
                lua_Integer idx = lua_tointeger(L, -2);
                std::string elem = path + "[" + std::to_string(idx) + "]";
                if (lua_type(L, -1) != LUA_TSTRING) {
                    error = elem + " must be a string, got " + luaL_typename(L, -1);
                } else {
                    size_t len = 0;
                    const char *v = lua_tolstring(L, -1, &len);
                    if (len == 0) error = elem + " must not be empty";
                    else items.emplace_back(idx, std::string(v, len));
                }
            }
        }
        lua_pop(L, 1);
    }
    if (!error.empty()) return error;
    std::sort(items.begin(), items.end());
    for (size_t i = 0; i < items.size(); ++i)
        if (items[i].first != static_cast<lua_Integer>(i + 1)) return path + " must be a list without holes";
    out->clear();
    for (auto &it : items) out->push_back(std::move(it.second));
    return "";
}

// Walks the table at the top of the stack. Only raw, non-allocating API calls
// are used, so no Lua code runs and nothing can raise.
std::string check_table(lua_State *L, const std::string &where, const std::vector<Field> &fields) {
    std::vector<std::string_view> known;
    for (const auto &f : fields) known.push_back(f.name);

    std::vector<std::string> unknown;  // sorted later for deterministic reports
    std::string type_error;
    const int t = lua_gettop(L);
    lua_pushnil(L);
    while (lua_next(L, t) != 0) {
        const Field *match = nullptr;
        if (lua_type(L, -2) == LUA_TSTRING) {
            size_t len = 0;
            const char *k = lua_tolstring(L, -2, &len);
            std::string_view key(k, len);
            for (const auto &f : fields)
                if (f.name == key) match = &f;
        }
        if (match == nullptr) {
            unknown.push_back(describe_key(L, -2));
        } else if (type_error.empty()) {
            std::string path = where + "." + std::string(match->name);
            if (match->kind == Field::Number) {
                if (lua_type(L, -1) == LUA_TNUMBER) {
                    *match->target = static_cast<double>(lua_tonumber(L, -1));
                    if (match->seen != nullptr) *match->seen = true;
                } else
                    type_error = path + " must be a number, got " + luaL_typename(L, -1);
            } else if (match->kind == Field::String) {
                if (lua_type(L, -1) == LUA_TSTRING) {
                    size_t len = 0;
                    const char *v = lua_tolstring(L, -1, &len);
                    *match->str = std::string(v, len);
                } else {
                    type_error = path + " must be a string, got " + luaL_typename(L, -1);
                }
            } else if (match->kind == Field::StringList) {
                if (lua_type(L, -1) == LUA_TTABLE)
                    type_error = read_string_list(L, path, match->list);
                else
                    type_error = path + " must be a list of strings, got " + luaL_typename(L, -1);
            } else if (match->kind == Field::DesktopMap) {
                if (lua_type(L, -1) == LUA_TTABLE)
                    type_error = read_desktop_map(L, path, match->desktop);
                else
                    type_error = path + " must be a table, got " + luaL_typename(L, -1);
            } else if (match->kind == Field::DisplayMap) {
                if (lua_type(L, -1) == LUA_TTABLE)
                    type_error = read_display_map(L, path, match->displays);
                else
                    type_error = path + " must be a table, got " + luaL_typename(L, -1);
            } else if (match->kind == Field::Boolean) {
                if (lua_type(L, -1) == LUA_TBOOLEAN) {
                    if (match->boolean != nullptr) *match->boolean = (lua_toboolean(L, -1) != 0);
                } else {
                    type_error = path + " must be a boolean, got " + luaL_typename(L, -1);
                }
            } else if (lua_type(L, -1) == LUA_TTABLE) {
                type_error = check_table(L, path, match->children);
            } else {
                type_error = path + " must be a table, got " + luaL_typename(L, -1);
            }
        }
        lua_pop(L, 1);
    }
    if (!unknown.empty()) {
        std::sort(unknown.begin(), unknown.end());
        const std::string &key = unknown.front();
        std::string msg = "unknown key " + key + " in " + where;
        if (key.size() >= 2 && key.front() == '\'') {
            std::string s = suggest(std::string_view(key).substr(1, key.size() - 2), known);
            if (!s.empty()) msg += " (did you mean '" + s + "'?)";
        }
        return msg;
    }
    return type_error;
}

// Protected part of the schema read: lua_pushstring may allocate, so the
// global lookup runs under pcall; the result table is left for the C++ walk.
int fetch_config(lua_State *L) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
    lua_pushliteral(L, "config");
    lua_rawget(L, -2);
    return 1;
}

// Grammar + cross-field validation of config.keys. Messages carry their "keys.<name>:" prefix.
std::string parse_keys(const std::optional<std::string> &t, const std::optional<std::string> &tf,
                       const std::optional<std::string> &sw,
                       const std::optional<std::string> &pref, const std::optional<std::string> &cw,
                       const std::optional<std::string> &fl, const std::optional<std::string> &fd,
                       const std::optional<std::string> &fu, const std::optional<std::string> &fr,
                       const std::optional<std::string> &ml, const std::optional<std::string> &md,
                       const std::optional<std::string> &mu, const std::optional<std::string> &mr,
                       hypr::Keys *out) {
    struct Item { const char *name; const std::optional<std::string> *text; bool key; hypr::Chord *dst; };
    const Item items[] = {{"throw", &t, false, &out->throw_to},
                          {"toggle_float", &tf, true, &out->toggle_float},
                          {"switch", &sw, false, &out->switch_to},
                          {"prefix", &pref, false, &out->prefix},
                          {"center_window", &cw, true, &out->center_window},
                          {"focus_left", &fl, true, &out->focus_left},
                          {"focus_down", &fd, true, &out->focus_down},
                          {"focus_up", &fu, true, &out->focus_up},
                          {"focus_right", &fr, true, &out->focus_right},
                          {"move_left", &ml, true, &out->move_left},
                          {"move_down", &md, true, &out->move_down},
                          {"move_up", &mu, true, &out->move_up},
                          {"move_right", &mr, true, &out->move_right}};
    for (const Item &it : items) {
        if (!it.text->has_value()) continue;
        hypr::Chord c;
        std::string e = hypr::parse_chord(**it.text, it.key, c);
        if (!e.empty()) return std::string("keys.") + it.name + ": " + e;
        *it.dst = c;
    }
    if (out->prefix.mods != 0) {
        if (out->prefix.mods != (hypr::kModAlt | hypr::kModShift)) {
            return "keys.prefix: prefix is hardcoded to Option+Shift ('opt shift' / 'alt+shift') for native macOS safety and cannot be changed";
        }
    }
    return hypr::validate_keys(*out);
}

// Checks every title pattern. On failure `needle` is the offending pattern (for the line lookup).
std::string validate_title_rules(const hypr::Rules &rules, std::string *needle) {
    const struct { const char *name; const std::vector<std::string> *list; } sets[] = {
        {"float_title", &rules.float_title}, {"ignore_title", &rules.ignore_title}};
    for (const auto &set : sets) {
        for (size_t i = 0; i < set.list->size(); ++i) {
            std::string e = hypr::validate_title_pattern((*set.list)[i]);
            if (e.empty()) continue;
            *needle = (*set.list)[i];
            return std::string("config.rules.") + set.name + "[" + std::to_string(i + 1) + "]: " + e;
        }
    }
    return "";
}

// 1-based line of the first source line containing `needle` as written (or with doubled backslashes,
// as in a Lua string literal), else of the key name when `needle` is a rule key, else 0.
int find_line(const char *src, size_t len, const std::string &needle) {
    const std::string text(src, len);
    std::vector<std::string> candidates = {needle, replace_all(needle, "\\", "\\\\")};
    for (const std::string &c : candidates) {
        size_t at = text.find(c);
        if (at != std::string::npos) return 1 + static_cast<int>(std::count(text.begin(), text.begin() + static_cast<std::ptrdiff_t>(at), '\n'));
    }
    for (const char *key : {"float_title", "ignore_title"}) {
        size_t at = text.find(key);
        if (at != std::string::npos) return 1 + static_cast<int>(std::count(text.begin(), text.begin() + static_cast<std::ptrdiff_t>(at), '\n'));
    }
    return 0;
}

hm_status run(const char *src, size_t len, const std::string &path, hm_config *inout, hypr::Extras *extras_out,
              char *err, size_t err_cap) {
    if (len > kMaxSourceBytes) {
        write_err(err, err_cap,
                  path + ": config file too large (" + std::to_string(len) + " bytes, max " +
                      std::to_string(kMaxSourceBytes) + ")");
        return HM_ERR_CONFIG;
    }

    Sandbox sb;
    lua_State *L = lua_newstate(sandbox_alloc, &sb);
    if (L == nullptr) {
        write_err(err, err_cap, path + ": cannot create Lua state");
        return HM_ERR_CONFIG;
    }
    struct Closer {
        lua_State *L;
        Sandbox *sb;
        ~Closer() {
            // __gc is refused by setmetatable, so lua_close runs no script code;
            // keep the hook armed anyway as a second line of defence.
            sb->tripped = true;
            lua_sethook(L, count_hook, LUA_MASKCOUNT, kHookEvery);
            lua_close(L);
        }
    } closer{L, &sb};

    std::string message;
    hm_status status = HM_OK;
    hypr::Config cfg;  // missing keys take built-in defaults
    hypr::Extras extras;
    std::optional<std::string> key_throw, key_toggle, key_switch, key_prefix, key_center;
    std::optional<std::string> key_focus_left, key_focus_down, key_focus_up, key_focus_right;
    std::optional<std::string> key_move_left, key_move_down, key_move_up, key_move_right;

    lua_pushcfunction(L, setup_state);
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
        write_err(err, err_cap, path + ": cannot initialise Lua sandbox");
        return HM_ERR_CONFIG;
    }
    lua_sethook(L, count_hook, LUA_MASKCOUNT, kHookEvery);

    std::string chunkname = std::string("=") + kChunkTag;
    int rc = luaL_loadbufferx(L, src, len, chunkname.c_str(), "t");
    if (rc == LUA_OK) rc = lua_pcall(L, 0, 0, 0);
    // The hook stays armed: fetch_config below may trigger a GC step.
    if (rc != LUA_OK) {
        if (sb.tripped) {
            write_err(err, err_cap,
                      format_lua_message(sb.timeout_msg[0] ? sb.timeout_msg : kTimeoutMsg, path));
            return HM_ERR_CONFIG;
        }
        std::string text = error_object_text(L);
        if ((rc == LUA_ERRMEM || sb.alloc_refused) && text.find("not enough memory") != std::string::npos) {
            write_err(err, err_cap,
                      path + ": configuration used too much memory (limit " +
                          std::to_string(kMemLimit / (1024 * 1024)) + " MB)");
            return HM_ERR_CONFIG;
        }
        write_err(err, err_cap, format_lua_message(std::move(text), path));
        return HM_ERR_CONFIG;
    }

    // Give the walk some headroom in case the script exhausted the budget.
    sb.limit = kMemLimit + 256 * 1024;
    lua_settop(L, 0);
    lua_pushcfunction(L, fetch_config);
    if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
        write_err(err, err_cap, path + ": configuration used too much memory");
        return HM_ERR_CONFIG;
    }
    if (!lua_isnil(L, -1)) {
        if (lua_type(L, -1) != LUA_TTABLE) {
            message = std::string("config must be a table, got ") + luaL_typename(L, -1);
        } else {
            std::vector<Field> schema = {
                table_field("gaps", {num_field("inner", &cfg.inner_gap), num_field("outer", &cfg.outer_gap)}),
                num_field("split_ratio", &cfg.split_ratio),
                table_field("float", {num_field("min_width", &cfg.float_min_w), num_field("min_height", &cfg.float_min_h)}),
                table_field("keys", {str_field("throw", &key_throw), str_field("toggle_float", &key_toggle),
                                     str_field("switch", &key_switch),
                                     str_field("prefix", &key_prefix), str_field("center_window", &key_center),
                                     str_field("focus_left", &key_focus_left), str_field("focus_down", &key_focus_down),
                                     str_field("focus_up", &key_focus_up), str_field("focus_right", &key_focus_right),
                                     str_field("move_left", &key_move_left), str_field("move_down", &key_move_down),
                                     str_field("move_up", &key_move_up), str_field("move_right", &key_move_right)}),
                table_field("rules", {list_field("ignore", &extras.rules.ignore), list_field("float", &extras.rules.float_),
                                      list_field("float_title", &extras.rules.float_title),
                                      list_field("ignore_title", &extras.rules.ignore_title),
                                      desktop_field("desktop", &extras.rules.desktop)}),
                bool_field("osd_popup", &extras.osd_popup),
                bool_field("smart_gaps", &extras.smart_gaps),
                bool_field("focus_follows_mouse", &extras.focus_follows_mouse),
                displays_field("displays", &extras.displays),
            };
            message = check_table(L, "config", schema);
        }
    }
    if (message.empty())
        message = parse_keys(key_throw, key_toggle, key_switch, key_prefix, key_center, key_focus_left,
                             key_focus_down, key_focus_up, key_focus_right, key_move_left, key_move_down,
                             key_move_up, key_move_right, &extras.keys);
    if (message.empty()) message = hypr::validate(cfg);
    std::string needle;  // text to locate in the source for a "<path>:<line>:" prefix
    if (message.empty()) message = validate_title_rules(extras.rules, &needle);
    if (!message.empty()) {
        const int line = needle.empty() ? 0 : find_line(src, len, needle);
        write_err(err, err_cap, path + (line > 0 ? ":" + std::to_string(line) : std::string()) + ": " + message);
        status = HM_ERR_CONFIG;
    } else {
        *inout = cfg.to_c();
        if (extras_out != nullptr) *extras_out = std::move(extras);
    }
    return status;
}

}  // namespace

extern "C" hm_status hm_config_load_string(const char *lua_source, const char *chunk_name, hm_config *inout,
                                           char *err, size_t err_cap) {
    if (lua_source == nullptr || inout == nullptr) {
        write_err(err, err_cap, "invalid argument: null source or config");
        return HM_ERR_INVALID_ARGUMENT;
    }
    try {
        std::string path = (chunk_name != nullptr && *chunk_name) ? chunk_name : "<string>";
        return run(lua_source, std::strlen(lua_source), path, inout, nullptr, err, err_cap);
    } catch (...) {
        write_err(err, err_cap, "internal error while loading configuration");
        return HM_ERR_INTERNAL;
    }
}

namespace {

hm_status load_file_impl(const char *path, hm_config *inout, hypr::Extras *extras_out, char *err, size_t err_cap) {
    if (path == nullptr || inout == nullptr) {
        write_err(err, err_cap, "invalid argument: null path or config");
        return HM_ERR_INVALID_ARGUMENT;
    }
    try {
        std::string p = path;
        struct stat st {};
        if (::stat(path, &st) != 0) {
            if (errno == ENOENT || errno == ENOTDIR)
                write_err(err, err_cap, p + ": config file not found");
            else
                write_err(err, err_cap, p + ": cannot read config file: " + std::strerror(errno));
            return HM_ERR_CONFIG;
        }
        if (S_ISDIR(st.st_mode)) {
            write_err(err, err_cap, p + ": is a directory, not a config file");
            return HM_ERR_CONFIG;
        }
        if (!S_ISREG(st.st_mode)) {
            write_err(err, err_cap, p + ": not a regular file");
            return HM_ERR_CONFIG;
        }
        if (static_cast<size_t>(st.st_size) > kMaxSourceBytes) {
            write_err(err, err_cap,
                      p + ": config file too large (" + std::to_string(st.st_size) + " bytes, max " +
                          std::to_string(kMaxSourceBytes) + ")");
            return HM_ERR_CONFIG;
        }
        FILE *f = std::fopen(path, "rb");
        if (f == nullptr) {
            if (errno == ENOENT)
                write_err(err, err_cap, p + ": config file not found");
            else
                write_err(err, err_cap, p + ": cannot open config file: " + std::strerror(errno));
            return HM_ERR_CONFIG;
        }
        // Read at most one byte past the limit so a file that grew after stat is still caught.
        std::string buf(kMaxSourceBytes + 1, '\0');
        size_t n = std::fread(buf.data(), 1, buf.size(), f);
        bool read_error = std::ferror(f) != 0;
        std::fclose(f);
        if (read_error) {
            write_err(err, err_cap, p + ": cannot read config file");
            return HM_ERR_CONFIG;
        }
        buf.resize(n);
        return run(buf.data(), buf.size(), p, inout, extras_out, err, err_cap);
    } catch (...) {
        write_err(err, err_cap, "internal error while loading configuration");
        return HM_ERR_INTERNAL;
    }
}

}  // namespace

extern "C" hm_status hm_config_load_file(const char *path, hm_config *inout, char *err, size_t err_cap) {
    return load_file_impl(path, inout, nullptr, err, err_cap);
}

extern "C" hm_status hm_config_load_extras(const char *path, char *json, size_t json_cap, char *err,
                                           size_t err_cap) {
    if (json == nullptr || json_cap == 0) {
        write_err(err, err_cap, "invalid argument: null or empty json buffer");
        return HM_ERR_INVALID_ARGUMENT;
    }
    json[0] = '\0';
    hm_config scratch{};
    hm_config_default(&scratch);
    hypr::Extras extras;
    hm_status st = load_file_impl(path, &scratch, &extras, err, err_cap);
    if (st != HM_OK) return st;
    try {
        std::string text = hypr::extras_to_json(extras);
        if (text.size() + 1 > json_cap) {
            write_err(err, err_cap, std::string(path) + ": keys/rules JSON does not fit the buffer");
            return HM_ERR_INVALID_ARGUMENT;
        }
        std::memcpy(json, text.c_str(), text.size() + 1);
    } catch (...) {
        write_err(err, err_cap, "internal error while loading configuration");
        return HM_ERR_INTERNAL;
    }
    return HM_OK;
}
