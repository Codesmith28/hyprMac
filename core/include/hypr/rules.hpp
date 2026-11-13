#pragma once
// Validation of the v0.3.0 rule options: title patterns (rules.float_title / rules.ignore_title),
// rules.desktop and config.displays. Pure C++ so doctest covers it.
//
// Title patterns are ECMAScript regular expressions matched case-insensitively against a window title
// by the Swift shell. Backtracking engines can take exponential time on some patterns, so the loader
// refuses the dangerous shapes up front: patterns longer than kMaxTitlePatternLen, back-references and
// a quantified group that itself contains a quantifier, such as "(a+)+" or "(.*)*". Swift additionally
// truncates titles to 512 characters before matching. Overlapping alternations like "(a|a)*" are not
// detected; keep patterns simple.
#include <string>
#include <utility>
#include <vector>

namespace hypr {

inline constexpr size_t kMaxTitlePatternLen = 128;
inline constexpr size_t kMaxDisplayEntries = 32;
inline constexpr int kMaxDesktop = 9;

struct DisplayGaps {
    std::string name;
    double inner = -1;  // < 0: not set, the global gap applies
    double outer = -1;
};

// "" when the pattern is acceptable, else the reason (no "rules.x[n]:" prefix).
std::string validate_title_pattern(const std::string &pattern);

// "" when acceptable, else the reason (no prefix). Bundle id: non-empty, <= 255 bytes, no whitespace.
std::string validate_desktop_entry(const std::string &bundle_id, double desktop);

// Display names are non-empty and <= 200 bytes; each gap is within [0, 200] (reasons carry no prefix).
std::string validate_display_name(const std::string &name);
std::string validate_display_gap(const char *which, double v);

} // namespace hypr
