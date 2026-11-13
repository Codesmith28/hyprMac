// v0.3.0 options: rules.float_title / ignore_title / desktop, config.smart_gaps / displays /
// focus_follows_mouse (schema, validation, JSON) and the title-pattern guards.
#include "doctest.h"
#include "hypr/hypr_core.h"
#include "hypr/rules.hpp"

#include <unistd.h>

#include <cstdlib>
#include <fstream>
#include <string>

namespace {

struct Loaded {
    hm_status status;
    std::string json, err;
};

Loaded load(const std::string &lua) {
    const char *tmp = std::getenv("TMPDIR");
    std::string tmpl = std::string(tmp && *tmp ? tmp : "/tmp") + "/hypr-rules-XXXXXX";
    std::string dir = mkdtemp(tmpl.data()) ? tmpl : std::string();
    std::string path = dir + "/init.lua";
    std::ofstream(path, std::ios::binary) << lua;
    static char json[65536];
    char err[512];
    Loaded l{HM_OK, {}, {}};
    l.status = hm_config_load_extras(path.c_str(), json, sizeof json, err, sizeof err);
    l.json = json;
    l.err = err;
    size_t at;
    while ((at = l.err.find(path)) != std::string::npos) l.err.replace(at, path.size(), "<path>");
    std::system(("rm -rf '" + dir + "'").c_str());
    return l;
}

bool has(const std::string &hay, const std::string &needle) { return hay.find(needle) != std::string::npos; }

} // namespace

TEST_CASE("v0.3.0 options default off and absent from the JSON") {
    Loaded l = load("config = {}");
    REQUIRE(l.status == HM_OK);
    CHECK_FALSE(has(l.json, "float_title"));
    CHECK_FALSE(has(l.json, "desktop"));
    CHECK_FALSE(has(l.json, "smart_gaps"));
    CHECK_FALSE(has(l.json, "focus_follows_mouse"));
    CHECK_FALSE(has(l.json, "displays"));
}

TEST_CASE("title rules: accepted and canonicalised into the JSON") {
    Loaded l = load(R"(config = { rules = { float_title = { "^Picture.in.Picture$", "Preferences" }, ignore_title = { "^Zoom Meeting" } } })");
    REQUIRE_MESSAGE(l.status == HM_OK, l.err);
    CHECK(has(l.json, R"("float_title":["^Picture.in.Picture$","Preferences"])"));
    CHECK(has(l.json, R"("ignore_title":["^Zoom Meeting"])"));
}

TEST_CASE("title rules: invalid regex is an error with file:line") {
    Loaded l = load("config = {\n  rules = {\n    float_title = {\n      \"ok\",\n      \"(unclosed\",\n    },\n  },\n}\n");
    CHECK(l.status == HM_ERR_CONFIG);
    CHECK(has(l.err, "<path>:5: config.rules.float_title[2]: invalid regular expression"));
}

TEST_CASE("title rules: the line points at the key when the pattern text is escaped in the source") {
    Loaded l = load("config = {\n  rules = {\n    ignore_title = { \"\\\\d++(\" },\n  },\n}\n");
    CHECK(l.status == HM_ERR_CONFIG);
    CHECK(has(l.err, "<path>:3: config.rules.ignore_title[1]"));
}

TEST_CASE("title rules: entry count, length and shape limits") {
    std::string many = "config = { rules = { float_title = {";
    for (int i = 0; i < 201; ++i) many += "\"a\",";
    many += "} } }";
    Loaded l = load(many);
    CHECK(l.status == HM_ERR_CONFIG);
    CHECK(has(l.err, "too many entries (max 200)"));

    std::string longp(hypr::kMaxTitlePatternLen + 1, 'a');
    l = load("config = { rules = { float_title = { \"" + longp + "\" } } }");
    CHECK(l.status == HM_ERR_CONFIG);
    CHECK(has(l.err, "pattern is too long"));
    l = load("config = { rules = { float_title = { \"" + std::string(hypr::kMaxTitlePatternLen, 'a') + "\" } } }");
    CHECK(l.status == HM_OK);

    CHECK(has(load(R"(config = { rules = { float_title = { "" } } })").err, "must not be empty"));
    CHECK(has(load(R"(config = { rules = { float_title = { 3 } } })").err, "must be a string"));
    CHECK(has(load(R"(config = { rules = { ignore_title = "x" } })").err, "must be a list of strings"));
}

TEST_CASE("title patterns: catastrophic shapes and back-references are refused") {
    for (const char *p : {"(a+)+", "(.*)*", "(a*)+b", "((a+))+", "(x+y){2,}", "(a+)*$", "(a)\\1"}) {
        INFO(p);
        CHECK_FALSE(hypr::validate_title_pattern(p).empty());
    }
    for (const char *p : {"a+", "(abc)+", "(a|b)+", "^(Slack|Teams) - .*$", "[a+]+", "\\(a+\\)+", "(a+)?", "colou?r"}) {
        INFO(p);
        CHECK(hypr::validate_title_pattern(p).empty());
    }
}

TEST_CASE("smart_gaps and focus_follows_mouse are booleans, default false") {
    Loaded l = load("config = { smart_gaps = true, focus_follows_mouse = true }");
    REQUIRE(l.status == HM_OK);
    CHECK(has(l.json, R"("smart_gaps":true,"focus_follows_mouse":true)"));
    l = load("config = { smart_gaps = false }");
    CHECK_FALSE(has(l.json, "smart_gaps"));
    CHECK(has(load("config = { smart_gaps = 1 }").err, "config.smart_gaps must be a boolean, got number"));
    CHECK(has(load("config = { focus_follows_mouse = 'yes' }").err, "config.focus_follows_mouse must be a boolean"));
}

TEST_CASE("displays: per-display gaps, partial entries, sorted") {
    Loaded l = load(R"(config = { displays = { ["Studio Display"] = { inner = 4, outer = 8 }, ["Built-in Retina Display"] = { outer = 0 } } })");
    REQUIRE_MESSAGE(l.status == HM_OK, l.err);
    CHECK(has(l.json, R"("displays":{"Built-in Retina Display":{"outer":0},"Studio Display":{"inner":4,"outer":8}})"));
}

TEST_CASE("displays: validation errors") {
    CHECK(has(load(R"(config = { displays = { A = { inner = 201 } } })").err, "inner must be within [0, 200]"));
    CHECK(has(load(R"(config = { displays = { A = { outer = -1 } } })").err, "outer must be within [0, 200]"));
    CHECK(has(load(R"(config = { displays = { A = { innr = 1 } } })").err, "unknown key 'innr'"));
    CHECK(has(load(R"(config = { displays = { A = { innr = 1 } } })").err, "did you mean 'inner'"));
    CHECK(has(load(R"(config = { displays = { A = 5 } })").err, "must be a table, got number"));
    CHECK(has(load(R"(config = { displays = { [""] = { inner = 1 } } })").err, "display name must not be empty"));
    CHECK(has(load(R"(config = { displays = { { inner = 1 } } })").err, "must map display names"));
    CHECK(has(load(R"(config = { displays = 3 })").err, "config.displays must be a table"));
    CHECK(has(load(R"(config = { displays = { A = { inner = "4" } } })").err, "must be a number"));
    CHECK(load(R"(config = { displays = { A = { } } })").status == HM_OK);
}

TEST_CASE("rules.desktop: bundle id to Desktop 1-9") {
    Loaded l = load(R"(config = { rules = { desktop = { ["com.b.app"] = 3, ["com.a.app"] = 1 } } })");
    REQUIRE_MESSAGE(l.status == HM_OK, l.err);
    CHECK(has(l.json, R"("desktop":{"com.a.app":1,"com.b.app":3})"));
    CHECK(has(load(R"(config = { rules = { desktop = { ["a.b"] = 0 } } })").err, "Desktop for 'a.b' must be a whole number from 1 to 9"));
    CHECK(has(load(R"(config = { rules = { desktop = { ["a.b"] = 10 } } })").err, "from 1 to 9"));
    CHECK(has(load(R"(config = { rules = { desktop = { ["a.b"] = 2.5 } } })").err, "whole number"));
    CHECK(has(load(R"(config = { rules = { desktop = { ["a.b"] = "3" } } })").err, "must be a number, got string"));
    CHECK(has(load(R"(config = { rules = { desktop = { ["a b"] = 3 } } })").err, "must not contain whitespace"));
    CHECK(has(load(R"(config = { rules = { desktop = { [""] = 3 } } })").err, "bundle id must not be empty"));
    CHECK(has(load(R"(config = { rules = { desktop = { "a.b" } } })").err, "must map bundle ids"));
    CHECK(has(load(R"(config = { rules = { desktop = "x" } })").err, "must be a table"));
}

TEST_CASE("a bad v0.3.0 option leaves hm_config_load_file failing too") {
    hm_config cfg;
    hm_config_default(&cfg);
    char err[256];
    CHECK(hm_config_load_string("config = { rules = { float_title = { '(' } } }", "x.lua", &cfg, err, sizeof err) == HM_ERR_CONFIG);
}
