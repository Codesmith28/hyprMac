// Tests for the sandboxed Lua config loader (core/src/config_lua.cpp).
#include "doctest.h"
#include "hypr/config.hpp"
#include "hypr/hypr_core.h"

#include <sys/stat.h>
#include <unistd.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>

#ifndef HYPR_SOURCE_DIR
#define HYPR_SOURCE_DIR "."
#endif

namespace {

struct Result {
    hm_status status;
    hm_config cfg;
    std::string err;
};

// Sentinel config so tests can see whether *inout was touched.
hm_config sentinel() { return hm_config{1.25, 2.5, 0.75}; }

bool same(const hm_config &a, const hm_config &b) {
    return std::memcmp(&a, &b, sizeof a) == 0;
}

Result load(const std::string &src, const char *name = "init.lua") {
    Result r{HM_OK, sentinel(), {}};
    char buf[512];
    std::memset(buf, 'X', sizeof buf);
    r.status = hm_config_load_string(src.c_str(), name, &r.cfg, buf, sizeof buf);
    if (r.status != HM_OK) r.err = buf;
    return r;
}

bool contains(const std::string &hay, const std::string &needle) {
    return hay.find(needle) != std::string::npos;
}

struct TempDir {
    std::string path;
    TempDir() {
        const char *tmp = std::getenv("TMPDIR");
        std::string tmpl = std::string(tmp && *tmp ? tmp : "/tmp") + "/hypr-cfg-XXXXXX";
        path = mkdtemp(tmpl.data()) ? tmpl : std::string();
    }
    ~TempDir() {
        if (!path.empty()) std::system(("rm -rf '" + path + "'").c_str());
    }
    std::string write(const std::string &name, const std::string &content) const {
        std::string p = path + "/" + name;
        std::ofstream(p, std::ios::binary) << content;
        return p;
    }
};

Result load_file(const std::string &path) {
    Result r{HM_OK, sentinel(), {}};
    char buf[512] = {0};
    r.status = hm_config_load_file(path.c_str(), &r.cfg, buf, sizeof buf);
    if (r.status != HM_OK) r.err = buf;
    return r;
}

} // namespace

TEST_SUITE("config_lua") {

// ---------- valid configurations ----------

TEST_CASE("full config is applied") {
    auto r = load("config = { gaps = { inner = 4, outer = 20 }, split_ratio = 0.6 }");
    REQUIRE(r.status == HM_OK);
    CHECK(r.cfg.inner_gap == 4.0);
    CHECK(r.cfg.outer_gap == 20.0);
    CHECK(r.cfg.split_ratio == doctest::Approx(0.6));
}

TEST_CASE("partial config: unspecified keys take built-in defaults, not *inout") {
    auto r = load("config = { gaps = { inner = 3 } }");
    REQUIRE(r.status == HM_OK);
    CHECK(r.cfg.inner_gap == 3.0);
    CHECK(r.cfg.outer_gap == 12.0);
    CHECK(r.cfg.split_ratio == 0.5);
}

TEST_CASE("partial config: only split_ratio") {
    auto r = load("config = { split_ratio = 0.3 }");
    REQUIRE(r.status == HM_OK);
    CHECK(r.cfg.inner_gap == 8.0);
    CHECK(r.cfg.outer_gap == 12.0);
    CHECK(r.cfg.split_ratio == doctest::Approx(0.3));
}

TEST_CASE("empty source gives defaults") {
    auto r = load("");
    REQUIRE(r.status == HM_OK);
    hm_config d;
    hm_config_default(&d);
    CHECK(same(r.cfg, d));
}

TEST_CASE("file that never sets config gives defaults") {
    auto r = load("local x = 1 + 2\nlocal t = { 1, 2, 3 }\nprint('hello')\n");
    REQUIRE(r.status == HM_OK);
    CHECK(r.cfg.inner_gap == 8.0);
    CHECK(r.cfg.outer_gap == 12.0);
    CHECK(r.cfg.split_ratio == 0.5);
}

TEST_CASE("empty config table and empty gaps table give defaults") {
    auto r = load("config = { gaps = {} }");
    REQUIRE(r.status == HM_OK);
    CHECK(r.cfg.inner_gap == 8.0);
    CHECK(r.cfg.outer_gap == 12.0);
}

TEST_CASE("integer and float values are both accepted") {
    auto r = load("config = { gaps = { inner = 10, outer = 10.5 }, split_ratio = 0.25 }");
    REQUIRE(r.status == HM_OK);
    CHECK(r.cfg.inner_gap == 10.0);
    CHECK(r.cfg.outer_gap == 10.5);
    auto r2 = load("config = { gaps = { inner = 2^3, outer = 7 // 2 } }");
    REQUIRE(r2.status == HM_OK);
    CHECK(r2.cfg.inner_gap == 8.0);
    CHECK(r2.cfg.outer_gap == 3.0);
}

TEST_CASE("boundary values are accepted") {
    auto r = load("config = { gaps = { inner = 0, outer = 200 }, split_ratio = 0.9 }");
    REQUIRE(r.status == HM_OK);
    CHECK(r.cfg.inner_gap == 0.0);
    CHECK(r.cfg.outer_gap == 200.0);
    auto r2 = load("config = { split_ratio = 0.1 }");
    CHECK(r2.status == HM_OK);
}

TEST_CASE("scripts may compute values with string/math/table libraries") {
    auto r = load("local g = math.floor(9.7)\n"
                  "local parts = {}\n"
                  "table.insert(parts, string.format('%d', g))\n"
                  "config = { gaps = { inner = tonumber(parts[1]), outer = math.max(1, 3) } }\n");
    REQUIRE(r.status == HM_OK);
    CHECK(r.cfg.inner_gap == 9.0);
    CHECK(r.cfg.outer_gap == 3.0);
}

TEST_CASE("config set via a function and pcall works") {
    auto r = load("local ok = pcall(function() error('ignored') end)\n"
                  "local function mk() return { gaps = { inner = 1 } } end\n"
                  "if not ok then config = mk() end\n");
    REQUIRE(r.status == HM_OK);
    CHECK(r.cfg.inner_gap == 1.0);
}

TEST_CASE("the shipped config/init.lua.example loads to the defaults") {
    auto r = load_file(std::string(HYPR_SOURCE_DIR) + "/config/init.lua.example");
    INFO(r.err);
    REQUIRE(r.status == HM_OK);
    hm_config d;
    hm_config_default(&d);
    CHECK(same(r.cfg, d));
}

// ---------- validation errors ----------

TEST_CASE("negative gap is rejected without a line number") {
    auto r = load("config = { gaps = { inner = -1 } }");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(r.err == "init.lua: gaps.inner must be >= 0");
}

TEST_CASE("NaN (0/0) is rejected") {
    auto r = load("config = { gaps = { outer = 0/0 } }");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(contains(r.err, "gaps.outer must be a finite number"));
}

TEST_CASE("infinity (1/0) is rejected") {
    auto r = load("config = { gaps = { inner = 1/0 } }");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(contains(r.err, "gaps.inner must be a finite number"));
}

TEST_CASE("201 is above the gap maximum") {
    auto r = load("config = { gaps = { outer = 201 } }");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(r.err == "init.lua: gaps.outer must be <= 200");
}

TEST_CASE("split_ratio out of range") {
    CHECK(load("config = { split_ratio = 0.95 }").err == "init.lua: split_ratio must be within [0.1, 0.9]");
    CHECK(load("config = { split_ratio = 0 }").status == HM_ERR_CONFIG);
}

// ---------- type / schema errors ----------

TEST_CASE("string value is a type error") {
    auto r = load("config = { gaps = { inner = '8' } }");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(r.err == "init.lua: config.gaps.inner must be a number, got string");
}

TEST_CASE("boolean and table values are type errors") {
    CHECK(load("config = { split_ratio = true }").err ==
          "init.lua: config.split_ratio must be a number, got boolean");
    CHECK(load("config = { gaps = { outer = {} } }").err ==
          "init.lua: config.gaps.outer must be a number, got table");
}

TEST_CASE("gaps must be a table") {
    CHECK(load("config = { gaps = 8 }").err == "init.lua: config.gaps must be a table, got number");
}

TEST_CASE("config must be a table") {
    CHECK(load("config = 'big gaps please'").err == "init.lua: config must be a table, got string");
}

TEST_CASE("unknown top-level key with suggestion") {
    auto r = load("config = { gap = 8 }");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(r.err == "init.lua: unknown key 'gap' in config (did you mean 'gaps'?)");
}

TEST_CASE("unknown nested key with suggestion") {
    auto r = load("config = { gaps = { iner = 8 } }");
    CHECK(r.err == "init.lua: unknown key 'iner' in config.gaps (did you mean 'inner'?)");
    auto r2 = load("config = { ratio = 0.5 }");
    CHECK(r2.err == "init.lua: unknown key 'ratio' in config (did you mean 'split_ratio'?)");
}

TEST_CASE("unknown key without a close match has no suggestion") {
    auto r = load("config = { wallpaper = 'x' }");
    CHECK(r.err == "init.lua: unknown key 'wallpaper' in config");
}

TEST_CASE("non-string keys are unknown keys") {
    auto r = load("config = { 1, 2 }");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(contains(r.err, "unknown key [1] in config"));
}

TEST_CASE("metatables on config are ignored (raw access only)") {
    auto r = load("config = setmetatable({}, { __index = function() error('should not run') end })");
    CHECK(r.status == HM_OK);
    auto r2 = load("config = setmetatable({}, { __index = { gaps = { inner = 1 } } })");
    REQUIRE(r2.status == HM_OK);
    CHECK(r2.cfg.inner_gap == 8.0);
}

// ---------- Lua errors ----------

TEST_CASE("syntax error reports chunk and line") {
    auto r = load("config = {\n  gaps = { inner = 8 }\n  split_ratio = 0.5\n}\n");
    CHECK(r.status == HM_ERR_CONFIG);
    INFO(r.err);
    CHECK(r.err.rfind("init.lua:3:", 0) == 0);
}

TEST_CASE("syntax error on line 1") {
    auto r = load("config = = 3");
    CHECK(r.err.rfind("init.lua:1:", 0) == 0);
}

TEST_CASE("runtime error() keeps Lua's position") {
    auto r = load("\n\nerror('boom')\n");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(r.err == "init.lua:3: boom");
}

TEST_CASE("runtime error without position and with a table object") {
    CHECK(load("error('plain', 0)").err == "init.lua: plain");
    CHECK(load("error({})").err == "init.lua: (error object is a table value)");
    CHECK(load("error(42)").err == "init.lua: 42");
    CHECK(load("error(nil)").err == "init.lua: (error object is a nil value)");
}

TEST_CASE("arithmetic on nil is a runtime error with line") {
    auto r = load("local a\nconfig = { gaps = { inner = a + 1 } }");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(r.err.rfind("init.lua:2:", 0) == 0);
    CHECK(contains(r.err, "arithmetic"));
}

TEST_CASE("binary chunks are refused") {
    std::string bin = "\x1bLua";
    auto r = load(bin);
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(contains(r.err, "binary"));
}

// ---------- sandbox ----------

TEST_CASE("os.execute is unavailable") {
    auto r = load("os.execute('touch /tmp/hypr-pwned')");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(contains(r.err, "os"));
}

TEST_CASE("io.open is unavailable") {
    auto r = load("local f = io.open('/etc/passwd')");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(contains(r.err, "io"));
}

TEST_CASE("require is unavailable") {
    auto r = load("local m = require('os')");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(contains(r.err, "require"));
}

TEST_CASE("dofile, loadfile, load, collectgarbage, debug, package, coroutine are absent") {
    auto r = load("assert(dofile == nil and loadfile == nil and load == nil)\n"
                  "assert(collectgarbage == nil and debug == nil and package == nil)\n"
                  "assert(coroutine == nil and io == nil and os == nil and require == nil)\n"
                  "assert(type(print) == 'function')\n");
    INFO(r.err);
    CHECK(r.status == HM_OK);
}

TEST_CASE("infinite loop hits the instruction limit") {
    auto r = load("config = {}\nwhile true do end\n");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(r.err == "init.lua:2: configuration took too long");
}

TEST_CASE("pcall cannot swallow the time limit") {
    auto r = load("local function spin() while true do end end\n"
                  "while true do pcall(spin) end\n");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(contains(r.err, "configuration took too long"));
    auto r2 = load("while true do xpcall(function() while true do end end, function(e) return e end) end");
    CHECK(contains(r2.err, "configuration took too long"));
}

TEST_CASE("memory bomb hits the allocation cap") {
    auto r = load("local t = {}\nwhile true do t[#t + 1] = string.rep('x', 1024 * 1024) .. #t end\n");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(contains(r.err, "too much memory"));
}

TEST_CASE("single huge allocation hits the cap") {
    auto r = load("local s = string.rep('x', 64 * 1024 * 1024)");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(contains(r.err, "too much memory"));
}

TEST_CASE("__gc finalizers are refused (they would run without the instruction hook)") {
    auto r = load("setmetatable({}, { __gc = function() while true do end end })\n"
                  "config = { gaps = { inner = 2 } }\n");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(r.err == "init.lua:1: __gc metamethods are not allowed in the configuration");
    // Adding __gc after setmetatable does not mark the object in Lua 5.4.
    auto r2 = load("local mt = {}\nlocal t = setmetatable({}, mt)\n"
                   "mt.__gc = function() while true do end end\nt = nil\n"
                   "config = { gaps = { inner = 2 } }\n");
    CHECK(r2.status == HM_OK);
    CHECK(r2.cfg.inner_gap == 2.0);
}

TEST_CASE("looping __close handler during error unwinding still times out") {
    auto r = load("do\n local x <close> = setmetatable({}, { __close = function() while true do end end })\n"
                  " error('first')\nend\n");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(contains(r.err, "configuration took too long"));
}

// ---------- files ----------

TEST_CASE("load_file: valid file") {
    TempDir d;
    auto p = d.write("init.lua", "config = { gaps = { inner = 5 } }\n");
    auto r = load_file(p);
    REQUIRE(r.status == HM_OK);
    CHECK(r.cfg.inner_gap == 5.0);
}

TEST_CASE("load_file: errors are prefixed with the full path") {
    TempDir d;
    auto p = d.write("init.lua", "\nconfig = { gaps = { inner = 'x' } }\n");
    auto r = load_file(p);
    CHECK(r.err == p + ": config.gaps.inner must be a number, got string");
    auto p2 = d.write("bad.lua", "x = \n\n)");
    auto r2 = load_file(p2);
    CHECK(r2.err.rfind(p2 + ":3:", 0) == 0);
}

TEST_CASE("load_file: long paths are not truncated in messages") {
    TempDir d;
    std::string dir = d.path + "/" + std::string(80, 'd');
    REQUIRE(::mkdir(dir.c_str(), 0700) == 0);
    std::string p = dir + "/init.lua";
    std::ofstream(p) << "error('x')";
    auto r = load_file(p);
    CHECK(r.err == p + ":1: x");
}

TEST_CASE("load_file: missing file is HM_ERR_CONFIG with 'not found'") {
    TempDir d;
    auto r = load_file(d.path + "/nope.lua");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(contains(r.err, "not found"));
    CHECK(same(r.cfg, sentinel()));
    auto r2 = load_file(d.path + "/no/such/dir/init.lua");
    CHECK(contains(r2.err, "not found"));
}

TEST_CASE("load_file: directory path is rejected") {
    TempDir d;
    auto r = load_file(d.path);
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(contains(r.err, "directory"));
    CHECK(!contains(r.err, "not found"));
}

TEST_CASE("load_file: file over 256 KB is rejected") {
    TempDir d;
    std::string big = "config = {}\n" + std::string(256 * 1024, '-') ;
    auto p = d.write("big.lua", big);
    auto r = load_file(p);
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(contains(r.err, "too large"));
}

TEST_CASE("load_file: exactly 256 KB is accepted") {
    TempDir d;
    std::string head = "config = { gaps = { inner = 1 } }\n--";
    std::string src = head + std::string(256 * 1024 - head.size(), 'c');
    REQUIRE(src.size() == 256 * 1024);
    auto r = load_file(d.write("edge.lua", src));
    INFO(r.err);
    CHECK(r.status == HM_OK);
}

TEST_CASE("load_string: huge source is rejected") {
    std::string big = "--" + std::string(300 * 1024, 'a');
    auto r = load(big);
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(contains(r.err, "too large"));
}

// ---------- API contract ----------

TEST_CASE("NULL arguments") {
    hm_config c = sentinel();
    char buf[64];
    CHECK(hm_config_load_string(nullptr, "x", &c, buf, sizeof buf) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_config_load_string("config = {}", "x", nullptr, buf, sizeof buf) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_config_load_file(nullptr, &c, buf, sizeof buf) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_config_load_file("/x", nullptr, buf, sizeof buf) == HM_ERR_INVALID_ARGUMENT);
    CHECK(same(c, sentinel()));
    // err == NULL is allowed on both success and failure.
    CHECK(hm_config_load_string("config = { gap = 1 }", "x", &c, nullptr, 0) == HM_ERR_CONFIG);
    CHECK(hm_config_load_string("config = { gaps = { inner = 2 } }", "x", &c, nullptr, 100) == HM_OK);
    CHECK(c.inner_gap == 2.0);
    // NULL chunk name falls back to a placeholder.
    c = sentinel();
    CHECK(hm_config_load_string("error('e')", nullptr, &c, buf, sizeof buf) == HM_ERR_CONFIG);
    CHECK(std::string(buf) == "<string>:1: e");
}

TEST_CASE("tiny err_cap never overflows and is NUL-terminated") {
    for (size_t cap : {size_t(1), size_t(2), size_t(8)}) {
        char buf[16];
        std::memset(buf, 'Z', sizeof buf);
        hm_config c = sentinel();
        CHECK(hm_config_load_string("config = { gap = 8 }", "init.lua", &c, buf, cap) == HM_ERR_CONFIG);
        CHECK(buf[cap - 1] == '\0');
        CHECK(std::strlen(buf) == cap - 1);
        for (size_t i = cap; i < sizeof buf; ++i) CHECK(buf[i] == 'Z');
    }
    char one = 'Z';
    hm_config c = sentinel();
    CHECK(hm_config_load_string("error('x')", "n", &c, &one, 0) == HM_ERR_CONFIG);
    CHECK(one == 'Z');  // cap 0: nothing written
}

TEST_CASE("*inout is unchanged on every kind of failure") {
    const char *bad[] = {
        "config = {",                          // syntax
        "error('x')",                          // runtime
        "config = { gaps = { inner = -5 } }",  // validation
        "config = { gaps = { inner = 's' } }", // type
        "config = { gapz = 1 }",               // unknown key
        "while true do end",                   // timeout
        "local s = string.rep('x', 1e8)",      // memory
        "config = { gaps = { inner = 1 }, split_ratio = 2 }", // partial-then-invalid
    };
    for (const char *src : bad) {
        auto r = load(src);
        INFO(src);
        CHECK(r.status == HM_ERR_CONFIG);
        CHECK(same(r.cfg, sentinel()));
        CHECK(!r.err.empty());
    }
}

TEST_CASE("states are independent between loads") {
    CHECK(load("x = 1 config = { gaps = { inner = 1 } }").status == HM_OK);
    auto r = load("assert(x == nil)");
    CHECK(r.status == HM_OK);
}

} // TEST_SUITE

TEST_CASE("float: defaults, partial and full") {
    auto d = load("config = {}");
    REQUIRE(d.status == HM_OK);
    CHECK(d.cfg.float_min_w == 400.0);
    CHECK(d.cfg.float_min_h == 300.0);
    auto p = load("config = { float = { min_width = 0 } }");
    REQUIRE(p.status == HM_OK);
    CHECK(p.cfg.float_min_w == 0.0);
    CHECK(p.cfg.float_min_h == 300.0);
    auto f = load("config = { float = { min_width = 123.5, min_height = 2000 } }");
    REQUIRE(f.status == HM_OK);
    CHECK(f.cfg.float_min_w == doctest::Approx(123.5));
    CHECK(f.cfg.float_min_h == 2000.0);
}

TEST_CASE("float: out of range and wrong type") {
    auto r = load("config = { float = { min_width = 2001 } }");
    CHECK(r.status == HM_ERR_CONFIG);
    CHECK(r.err == "init.lua: float.min_width must be within [0, 2000]");
    CHECK(load("config = { float = { min_height = -1 } }").status == HM_ERR_CONFIG);
    CHECK(load("config = { float = { min_width = 'big' } }").status == HM_ERR_CONFIG);
    CHECK(load("config = { float = 5 }").status == HM_ERR_CONFIG);
}

TEST_CASE("float: unknown key suggestions") {
    auto r = load("config = { flot = {} }");
    CHECK(r.err == "init.lua: unknown key 'flot' in config (did you mean 'float'?)");
    auto r2 = load("config = { float = { min_widht = 5 } }");
    CHECK(r2.err == "init.lua: unknown key 'min_widht' in config.float (did you mean 'min_width'?)");
}
