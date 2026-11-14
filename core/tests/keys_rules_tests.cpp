// Tests for config.keys / config.rules: the grammar (keyspec.cpp), validation through the Lua
// loader and the hm_config_load_extras JSON.
#include "doctest.h"
#include "hypr/hypr_core.h"
#include "hypr/keyspec.hpp"

#include <unistd.h>

#include <cstdlib>
#include <fstream>
#include <cstring>
#include <string>

#ifndef HYPR_SOURCE_DIR
#define HYPR_SOURCE_DIR "."
#endif

namespace {

struct TempFile {
    std::string dir, path;
    explicit TempFile(const std::string &content) {
        const char *tmp = std::getenv("TMPDIR");
        std::string tmpl = std::string(tmp && *tmp ? tmp : "/tmp") + "/hypr-keys-XXXXXX";
        dir = mkdtemp(tmpl.data()) ? tmpl : std::string();
        path = dir + "/init.lua";
        std::ofstream(path, std::ios::binary) << content;
    }
    ~TempFile() { if (!dir.empty()) std::system(("rm -rf '" + dir + "'").c_str()); }
};

struct Extras {
    hm_status status;
    std::string json, err;
};

Extras extras_of_file(const std::string &path) {
    Extras e{HM_OK, {}, {}};
    static char json[65536];
    char err[512];
    e.status = hm_config_load_extras(path.c_str(), json, sizeof json, err, sizeof err);
    e.json = json;
    e.err = err;
    return e;
}

Extras extras(const std::string &lua) {
    TempFile f(lua);
    Extras e = extras_of_file(f.path);
    // Errors carry the file path; make them stable for assertions.
    size_t at;
    while ((at = e.err.find(f.path)) != std::string::npos) e.err.replace(at, f.path.size(), "<path>");
    return e;
}

bool has(const std::string &hay, const std::string &needle) { return hay.find(needle) != std::string::npos; }

const char *kDefaultJson =
    R"({"keys":{"throw":"alt+shift","toggle_float":"alt+shift+f","switch":"alt","rotate_split":"alt+shift+r"},"rules":{"ignore":[],"float":[]},"osd_popup":true})";

const char *kShippedExampleJson =
    R"({"keys":{"throw":"alt+shift","toggle_float":"alt+shift+f","switch":"alt","center_window":"alt+shift+c","focus_left":"alt+shift+h","focus_down":"alt+shift+j","focus_up":"alt+shift+k","focus_right":"alt+shift+l","move_left":"alt+shift+cmd+h","move_down":"alt+shift+cmd+j","move_up":"alt+shift+cmd+k","move_right":"alt+shift+cmd+l","rotate_split":"alt+shift+r"},"rules":{"ignore":["com.docker.docker","com.mongodb.compass"],"float":["com.apple.systempreferences","com.apple.calculator"]},"osd_popup":true})";

std::string parse_err(const char *text, bool key) {
    hypr::Chord c;
    return hypr::parse_chord(text, key, c);
}

}  // namespace

// ---------- grammar ----------

TEST_CASE("chord grammar: modifiers, aliases and case") {
    hypr::Chord c;
    CHECK(hypr::parse_chord("alt+shift", false, c).empty());
    CHECK(c.mods == (hypr::kModAlt | hypr::kModShift));
    CHECK(c.key.empty());
    CHECK(hypr::parse_chord("OPT", false, c).empty());
    CHECK(c.mods == hypr::kModAlt);
    CHECK(hypr::parse_chord("Option+Control", false, c).empty());
    CHECK(c.mods == (hypr::kModAlt | hypr::kModCtrl));
    CHECK(hypr::parse_chord("command+ctrl+Shift+alt", false, c).empty());
    CHECK(c.mods == (hypr::kModCmd | hypr::kModCtrl | hypr::kModShift | hypr::kModAlt));
    CHECK(hypr::format_chord(c) == "ctrl+alt+shift+cmd");  // canonical order
}

TEST_CASE("chord grammar: keys") {
    hypr::Chord c;
    CHECK(hypr::parse_chord("Ctrl+Alt+T", true, c).empty());
    CHECK(c.mods == (hypr::kModCtrl | hypr::kModAlt));
    CHECK(c.key == "t");
    CHECK(hypr::format_chord(c) == "ctrl+alt+t");

    // Neovim notation and space separation:
    CHECK(hypr::parse_chord("<M-S-f>", true, c).empty());
    CHECK(c.mods == (hypr::kModAlt | hypr::kModShift));
    CHECK(c.key == "f");

    CHECK(hypr::parse_chord("<A-S-c>", true, c).empty());
    CHECK(c.mods == (hypr::kModAlt | hypr::kModShift));
    CHECK(c.key == "c");

    CHECK(hypr::parse_chord("<M-S-D-h>", true, c).empty());
    CHECK(c.mods == (hypr::kModAlt | hypr::kModShift | hypr::kModCmd));
    CHECK(c.key == "h");

    CHECK(hypr::parse_chord("<C-c>", true, c).empty());
    CHECK(c.mods == hypr::kModCtrl);
    CHECK(c.key == "c");

    CHECK(hypr::parse_chord("<M-C>", false, c).empty());
    CHECK(c.mods == (hypr::kModAlt | hypr::kModCtrl));
    CHECK(c.key.empty());

    CHECK(hypr::parse_chord("opt shift", false, c).empty());
    CHECK(c.mods == (hypr::kModAlt | hypr::kModShift));
    CHECK(c.key.empty());

    for (const char *k : {"a", "z", "0", "9", "f1", "f12", "space", "tab", "return", "escape", "grave", "minus",
                          "equal", "comma", "period", "slash", "left", "right", "up", "down"}) {
        INFO(k);
        CHECK(hypr::is_key_name(k));
        CHECK(parse_err((std::string("alt+") + k).c_str(), true).empty());
    }
    for (const char *k : {"f0", "f13", "ab", "enter", "A", "+", "", "f1x", "backspace"}) {
        INFO(k);
        CHECK_FALSE(hypr::is_key_name(k));
    }
}

TEST_CASE("chord grammar: errors") {
    CHECK(parse_err("hyper", false) == "unknown modifier 'hyper'");
    CHECK(parse_err("alt+hyper", false) == "unknown modifier 'hyper'");
    CHECK(parse_err("", false) == "must not be empty");
    CHECK(parse_err("alt++shift", false) == "empty element in 'alt++shift' (stray '+')");
    CHECK(parse_err("alt+", false).find("empty element") == 0);
    CHECK(parse_err("alt+alt", false) == "duplicate modifier 'alt'");
    CHECK(parse_err("opt+alt", false) == "duplicate modifier 'alt'");
    CHECK(parse_err("alt+f", false).find("'f' is a key") == 0);           // throw/switch: modifiers only
    CHECK(parse_err("f", true) == "needs at least one modifier");
    CHECK(parse_err("alt+shift", true).find("needs exactly one key") == 0);
    CHECK(parse_err("alt+f+g", true) == "more than one key in 'alt+f+g'");
    CHECK(parse_err("alt+shift+banana", true) == "unknown key 'banana'");
    CHECK(parse_err("bogus+f", true) == "unknown modifier 'bogus'");
}

TEST_CASE("cross-field validation") {
    hypr::Keys k;
    CHECK(hypr::validate_keys(k).empty());
    k.switch_to = k.throw_to;
    CHECK(has(hypr::validate_keys(k), "keys.throw: must differ from keys.switch"));
    k = hypr::Keys{};
    k.toggle_float = {hypr::kModAlt | hypr::kModShift, "3"};
    CHECK(has(hypr::validate_keys(k), "keys.toggle_float: conflicts with the throw shortcut"));
    k.toggle_float = {hypr::kModAlt | hypr::kModShift, "0"};  // 0 isn't a Desktop digit
    CHECK(hypr::validate_keys(k).empty());
}

TEST_CASE("cross-field validation: the new actions") {
    using namespace hypr;
    Keys k;
    k.resize_left = {kModAlt | kModShift, "3"};
    CHECK(has(validate_keys(k), "keys.resize_left: conflicts with the throw shortcut for Desktop 3"));
    k = Keys{};
    k.toggle_zoom = {kModAlt, "4"};
    CHECK(has(validate_keys(k), "keys.toggle_zoom: conflicts with the Desktop switch shortcut for Desktop 4"));
    k = Keys{};
    k.toggle_zoom = {kModAlt | kModShift, "0"};
    CHECK(validate_keys(k).empty());
    k = Keys{};
    k.equalize = {kModAlt | kModShift, "f"};  // toggle_float's default
    CHECK(validate_keys(k) == "keys.equalize: 'alt+shift+f' is already used by keys.toggle_float");
    k = Keys{};
    k.equalize = {kModAlt | kModShift, "h"};  // a default focus shortcut
    CHECK(validate_keys(k) == "keys.equalize: 'alt+shift+h' is already used by the default focus_left shortcut");
    k.focus_left = {kModAlt | kModShift, "j"};  // focus_left set: the defaults are replaced
    CHECK(validate_keys(k).empty());
    k = Keys{};
    k.rotate_split = {kModAlt | kModShift | kModCmd, "up"};  // default move_up (arrow)
    CHECK(has(validate_keys(k), "already used by the default move_up shortcut"));
    k = Keys{};
    k.equalize = {kModAlt | kModShift, "c"};  // default center_window
    CHECK(has(validate_keys(k), "already used by the default center_window shortcut"));
    k.center_window = {kModAlt | kModShift, "x"};
    CHECK(validate_keys(k).empty());
    k = Keys{};
    k.resize_left = {kModAlt | kModShift, "u"};
    k.resize_right = {kModAlt | kModShift, "u"};
    CHECK(validate_keys(k) == "keys.resize_right: 'alt+shift+u' is already used by keys.resize_left");
    k.resize_right = {kModAlt | kModShift, "i"};
    CHECK(validate_keys(k).empty());
}

// ---------- the loader ----------

TEST_CASE("extras: every new action is accepted, canonical and unbound by default (except rotate_split = alt+shift+r)") {
    auto e = extras("config = { keys = { toggle_float = 'ctrl+alt+t' } }\n");
    REQUIRE(e.status == HM_OK);
    for (const hypr::ActionKey &a : hypr::kActionKeys) {
        if (std::string(a.name) == "rotate_split") continue;
        CHECK_FALSE(has(e.json, std::string("\"") + a.name + "\""));
    }
    CHECK(has(e.json, R"("rotate_split":"alt+shift+r")"));

    const char *lua =
        "config = { keys = {\n"
        "  resize_left = 'Alt+Shift+Y', resize_down = 'alt+shift+u', resize_up = 'opt+shift+i', resize_right = 'alt+shift+o',\n"
        "  equalize = 'alt+shift+e', rotate_split = 'alt+shift+r', toggle_zoom = 'alt+shift+z',\n"
        "  move_display_next = 'alt+shift+period', move_display_prev = 'alt+shift+comma', toggle_pause = 'alt+shift+p',\n"
        "} }\n";
    e = extras(lua);
    INFO(e.err);
    REQUIRE(e.status == HM_OK);
    CHECK(has(e.json, R"("resize_left":"alt+shift+y","resize_down":"alt+shift+u","resize_up":"alt+shift+i","resize_right":"alt+shift+o",)"
                      R"("equalize":"alt+shift+e","rotate_split":"alt+shift+r","toggle_zoom":"alt+shift+z",)"
                      R"("move_display_next":"alt+shift+period","move_display_prev":"alt+shift+comma","toggle_pause":"alt+shift+p")"));
}

TEST_CASE("extras: the new actions validate like the existing ones") {
    for (const hypr::ActionKey &a : hypr::kActionKeys) {
        CAPTURE(a.name);
        const std::string k = a.name;
        auto e = extras("config = { keys = { " + k + " = 'alt+shift' } }\n");
        CHECK(e.status == HM_ERR_CONFIG);
        CHECK(e.err == "<path>: keys." + k + ": needs exactly one key (for example 'alt+shift+f' or '<M-S-f>')");
        e = extras("config = { keys = { " + k + " = 'f' } }\n");
        CHECK(e.err == "<path>: keys." + k + ": needs at least one modifier");
        e = extras("config = { keys = { " + k + " = 'hyper+f' } }\n");
        CHECK(e.err == "<path>: keys." + k + ": unknown modifier 'hyper'");
        e = extras("config = { keys = { " + k + " = 'alt+shift+nope' } }\n");
        CHECK(e.err == "<path>: keys." + k + ": unknown key 'nope'");
        e = extras("config = { keys = { " + k + " = 'alt+f+g' } }\n");
        CHECK(e.err == "<path>: keys." + k + ": more than one key in 'alt+f+g'");
        e = extras("config = { keys = { " + k + " = 5 } }\n");
        CHECK(e.err == "<path>: config.keys." + k + " must be a string, got number");
        e = extras("config = { keys = { " + k + " = '' } }\n");
        CHECK(e.err == "<path>: keys." + k + ": must not be empty");
        e = extras("config = { keys = { " + k + " = 'alt+shift+3' } }\n");
        CHECK(has(e.err, "keys." + k + ": conflicts with the throw shortcut for Desktop 3"));
        e = extras("config = { keys = { " + k + " = 'alt+3' } }\n");
        CHECK(has(e.err, "keys." + k + ": conflicts with the Desktop switch shortcut for Desktop 3"));
        e = extras("config = { keys = { " + k + " = 'alt+shift+f' } }\n");
        CHECK(e.err == "<path>: keys." + k + ": 'alt+shift+f' is already used by keys.toggle_float");
        e = extras("config = { keys = { " + k + " = 'ctrl+alt+shift+x' } }\n");
        CHECK(e.status == HM_OK);
    }
    auto e = extras("config = { keys = { resize_lef = 'alt+shift+y' } }\n");
    CHECK(has(e.err, "unknown key 'resize_lef' in config.keys (did you mean 'resize_left'?)"));
    e = extras("config = { keys = { toggel_zoom = 'alt+shift+z' } }\n");
    CHECK(has(e.err, "unknown key 'toggel_zoom' in config.keys (did you mean 'toggle_zoom'?)"));
    // A failed reload keeps the previous config: nothing is written to the caller's struct.
    hm_config c;
    hm_config_default(&c);
    const hm_config before = c;
    TempFile bad("config = { keys = { equalize = 'alt+shift+h' } }\n");
    char err[256];
    CHECK(hm_config_load_file(bad.path.c_str(), &c, err, sizeof err) == HM_ERR_CONFIG);
    CHECK(std::memcmp(&c, &before, sizeof c) == 0);
}

TEST_CASE("extras: two new actions on the same shortcut are rejected") {
    auto e = extras("config = { keys = { toggle_zoom = 'alt+shift+z', rotate_split = 'alt+shift+z' } }\n");
    CHECK(e.status == HM_ERR_CONFIG);
    CHECK(e.err == "<path>: keys.toggle_zoom: 'alt+shift+z' is already used by keys.rotate_split");
}

TEST_CASE("extras: defaults equal the hard-coded behaviour") {
    auto e = extras("config = { gaps = { inner = 4 } }\n");
    REQUIRE(e.status == HM_OK);
    CHECK(e.json == kDefaultJson);
    e = extras("");  // no config table at all
    REQUIRE(e.status == HM_OK);
    CHECK(e.json == kDefaultJson);
}

TEST_CASE("extras: custom keys come back canonical") {
    auto e = extras("config = { keys = { throw = 'Ctrl+Alt', toggle_float = 'ALT+shift+Space', switch = 'ctrl' } }\n");
    REQUIRE(e.status == HM_OK);
    CHECK(e.json == R"({"keys":{"throw":"ctrl+alt","toggle_float":"alt+shift+space","switch":"ctrl","rotate_split":"alt+shift+r"},)"
                    R"("rules":{"ignore":[],"float":[]},"osd_popup":true})");
    e = extras("config = { keys = { toggle_float = 'ctrl+alt+t' } }\n");  // partial table: others keep defaults
    REQUIRE(e.status == HM_OK);
    CHECK(has(e.json, R"("throw":"alt+shift","toggle_float":"ctrl+alt+t","switch":"alt")"));
}

TEST_CASE("extras: grammar errors use the loader style and keep the previous config") {
    auto e = extras("config = { keys = { throw = 'hyper' } }\n");
    CHECK(e.status == HM_ERR_CONFIG);
    CHECK(e.err == "<path>: keys.throw: unknown modifier 'hyper'");
    CHECK(e.json.empty());
    e = extras("config = { keys = { toggle_float = 'alt+shift' } }\n");
    CHECK(e.status == HM_ERR_CONFIG);
    CHECK(has(e.err, "<path>: keys.toggle_float: needs exactly one key"));
    e = extras("config = { keys = { switch = 'alt+x' } }\n");
    CHECK(has(e.err, "<path>: keys.switch: 'x' is a key"));
    e = extras("config = { keys = { throw = 'alt', switch = 'alt' } }\n");
    CHECK(has(e.err, "keys.throw: must differ from keys.switch"));
    e = extras("config = { keys = { throw = 5 } }\n");
    CHECK(e.err == "<path>: config.keys.throw must be a string, got number");
    e = extras("config = { keys = { prefix = 'ctrl+cmd' } }\n");
    CHECK(e.status == HM_ERR_CONFIG);
    CHECK(has(e.err, "keys.prefix: prefix is hardcoded to Option+Shift ('opt shift' / 'alt+shift') for native macOS safety and cannot be changed"));
    e = extras("config = { keys = { prefix = 'alt+shift' } }\n");
    CHECK(e.status == HM_OK);
    CHECK(has(e.json, R"("prefix":"alt+shift")"));
    e = extras("config = { keys = { prefix = 'opt shift' } }\n");
    CHECK(e.status == HM_OK);
    CHECK(has(e.json, R"("prefix":"alt+shift")"));
    e = extras("config = { keys = { thro = 'alt' } }\n");
    CHECK(has(e.err, "unknown key 'thro' in config.keys (did you mean 'throw'?)"));
    e = extras("config = { keys = 'alt' }\n");
    CHECK(has(e.err, "config.keys must be a table"));
    e = extras("config = { osd_popup = false }\n");
    CHECK(e.status == HM_OK);
    CHECK(has(e.json, R"("osd_popup":false)"));
    e = extras("config = { osd_popup = 'no' }\n");
    CHECK(e.status == HM_ERR_CONFIG);
    CHECK(has(e.err, "config.osd_popup must be a boolean, got string"));
}

TEST_CASE("hm_config_load_file accepts keys and rules as known keys, and still validates them") {
    TempFile f("config = { keys = { throw = 'ctrl+alt' }, rules = { ignore = { 'a.b' } } }\n");
    hm_config c;
    hm_config_default(&c);
    char err[256];
    CHECK(hm_config_load_file(f.path.c_str(), &c, err, sizeof err) == HM_OK);
    TempFile bad("config = { keys = { throw = 'hyper' } }\n");
    CHECK(hm_config_load_file(bad.path.c_str(), &c, err, sizeof err) == HM_ERR_CONFIG);
    CHECK(has(err, "keys.throw: unknown modifier 'hyper'"));
}

TEST_CASE("the shipped init.lua.example yields the default extras") {
    auto e = extras_of_file(std::string(HYPR_SOURCE_DIR) + "/config/init.lua.example");
    INFO(e.err);
    REQUIRE(e.status == HM_OK);
    CHECK(e.json == kShippedExampleJson);
}

// ---------- rules ----------

TEST_CASE("rules: lists come back in order") {
    auto e = extras("config = { rules = { ignore = { 'com.a', 'com.b' }, float = { 'com.c' } } }\n");
    REQUIRE(e.status == HM_OK);
    CHECK(has(e.json, R"("rules":{"ignore":["com.a","com.b"],"float":["com.c"]})"));
    e = extras("config = { rules = { float = { 'com.c' } } }\n");
    CHECK(has(e.json, R"("ignore":[],"float":["com.c"])"));
}

TEST_CASE("rules: JSON escaping") {
    auto e = extras("config = { rules = { ignore = { 'a\"b\\\\c\\n' } } }\n");
    REQUIRE(e.status == HM_OK);
    CHECK(has(e.json, R"("ignore":["a\"b\\c\n"])"));
}

TEST_CASE("rules: validation") {
    auto e = extras("config = { rules = { ignore = { '' } } }\n");
    CHECK(e.status == HM_ERR_CONFIG);
    CHECK(has(e.err, "config.rules.ignore[1] must not be empty"));
    e = extras("config = { rules = { float = { 'ok', 5 } } }\n");
    CHECK(has(e.err, "config.rules.float[2] must be a string, got number"));
    e = extras("config = { rules = { ignore = 'com.a' } }\n");
    CHECK(has(e.err, "config.rules.ignore must be a list of strings, got string"));
    e = extras("config = { rules = { ignore = { a = 'x' } } }\n");
    CHECK(has(e.err, "config.rules.ignore must be a list of strings"));
    e = extras("config = { rules = { ignore = { [1] = 'a', [3] = 'c' } } }\n");
    CHECK(has(e.err, "must be a list without holes"));
    e = extras("config = { rules = { ignre = {} } }\n");
    CHECK(has(e.err, "unknown key 'ignre' in config.rules (did you mean 'ignore'?)"));
    e = extras("config = { rules = 3 }\n");
    CHECK(has(e.err, "config.rules must be a table"));
}

TEST_CASE("rules: at most 200 entries per list") {
    auto build = [](int n) {
        return "local t = {}\nfor i = 1, " + std::to_string(n) +
               " do t[i] = 'com.example.app' .. i end\nconfig = { rules = { ignore = t } }\n";
    };
    CHECK(extras(build(200)).status == HM_OK);
    auto e = extras(build(201));
    CHECK(e.status == HM_ERR_CONFIG);
    CHECK(has(e.err, "config.rules.ignore has too many entries (max 200)"));
}

TEST_CASE("extras: argument checks and buffer size") {
    char err[64], tiny[8];
    CHECK(hm_config_load_extras("/nonexistent/init.lua", tiny, sizeof tiny, err, sizeof err) == HM_ERR_CONFIG);
    CHECK(has(err, "not found"));
    TempFile f("config = {}\n");
    CHECK(hm_config_load_extras(f.path.c_str(), tiny, sizeof tiny, err, sizeof err) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_config_load_extras(f.path.c_str(), nullptr, 10, err, sizeof err) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_config_load_extras(nullptr, tiny, sizeof tiny, err, sizeof err) == HM_ERR_INVALID_ARGUMENT);
}
