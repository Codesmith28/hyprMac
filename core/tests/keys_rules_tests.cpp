// Tests for config.keys / config.rules: the grammar (keyspec.cpp), validation through the Lua
// loader and the hm_config_load_extras JSON.
#include "doctest.h"
#include "hypr/hypr_core.h"
#include "hypr/keyspec.hpp"

#include <unistd.h>

#include <cstdlib>
#include <fstream>
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
    R"({"keys":{"throw":"alt+shift","toggle_float":"alt+shift+f","switch":"alt"},"rules":{"ignore":[],"float":[]}})";

const char *kShippedExampleJson =
    R"({"keys":{"throw":"alt+shift","toggle_float":"alt+shift+f","switch":"alt","center_window":"alt+shift+c","focus_left":"alt+shift+h","focus_down":"alt+shift+j","focus_up":"alt+shift+k","focus_right":"alt+shift+l","move_left":"alt+shift+cmd+h","move_down":"alt+shift+cmd+j","move_up":"alt+shift+cmd+k","move_right":"alt+shift+cmd+l"},"rules":{"ignore":["com.docker.docker","com.mongodb.compass"],"float":["com.apple.systempreferences","com.apple.calculator"]}})";

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

// ---------- the loader ----------

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
    CHECK(e.json == R"({"keys":{"throw":"ctrl+alt","toggle_float":"alt+shift+space","switch":"ctrl"},)"
                    R"("rules":{"ignore":[],"float":[]}})");
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
