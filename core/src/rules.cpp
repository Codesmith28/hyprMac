#include "hypr/rules.hpp"

#include "hypr/config.hpp"

#include <cmath>
#include <regex>

namespace hypr {

namespace {

bool is_quantifier_at(const std::string &p, size_t i) {
    if (i >= p.size()) return false;
    if (p[i] == '*' || p[i] == '+') return true;
    return p[i] == '{' && i + 1 < p.size() && p[i + 1] >= '0' && p[i + 1] <= '9';
}

// True for a group that contains a quantifier and is itself quantified (with *, + or {n,...}).
bool has_nested_quantifier(const std::string &p) {
    std::vector<bool> inner_quant;  // per open group: contains a quantifier
    bool in_class = false;
    for (size_t i = 0; i < p.size(); ++i) {
        const char c = p[i];
        if (c == '\\') { ++i; continue; }
        if (in_class) { if (c == ']') in_class = false; continue; }
        if (c == '[') { in_class = true; continue; }
        if (c == '(') { inner_quant.push_back(false); continue; }
        if (c == ')') {
            if (inner_quant.empty()) continue;
            const bool had = inner_quant.back();
            inner_quant.pop_back();
            if (had && is_quantifier_at(p, i + 1)) return true;
            if (!inner_quant.empty() && (had || is_quantifier_at(p, i + 1))) inner_quant.back() = true;
            continue;
        }
        if (is_quantifier_at(p, i) && !inner_quant.empty()) inner_quant.back() = true;
    }
    return false;
}

bool has_backreference(const std::string &p) {
    for (size_t i = 0; i + 1 < p.size(); ++i) {
        if (p[i] != '\\') continue;
        if (p[i + 1] >= '1' && p[i + 1] <= '9') return true;
        ++i;
    }
    return false;
}

} // namespace

std::string validate_title_pattern(const std::string &p) {
    if (p.empty()) return "must not be empty";
    if (p.size() > kMaxTitlePatternLen)
        return "pattern is too long (" + std::to_string(p.size()) + " bytes, max " + std::to_string(kMaxTitlePatternLen) + ")";
    if (has_backreference(p)) return "back-references are not allowed in title patterns";
    if (has_nested_quantifier(p))
        return "pattern could backtrack catastrophically (a repeated group that contains a repeat, like '(a+)+')";
    try {
        std::regex re(p, std::regex::ECMAScript | std::regex::icase);
    } catch (const std::regex_error &e) {
        return std::string("invalid regular expression: ") + e.what();
    }
    return "";
}

std::string validate_desktop_entry(const std::string &bundle, double desktop) {
    if (bundle.empty()) return "bundle id must not be empty";
    if (bundle.size() > 255) return "bundle id is too long";
    for (char c : bundle)
        if (static_cast<unsigned char>(c) <= ' ') return "bundle id '" + bundle + "' must not contain whitespace";
    if (!std::isfinite(desktop) || desktop != std::floor(desktop) || desktop < 1 || desktop > kMaxDesktop)
        return "Desktop for '" + bundle + "' must be a whole number from 1 to " + std::to_string(kMaxDesktop);
    return "";
}

std::string validate_display_name(const std::string &name) {
    if (name.empty()) return "display name must not be empty";
    if (name.size() > 200) return "display name is too long (max 200 bytes)";
    return "";
}

std::string validate_display_gap(const char *which, double v) {
    if (std::isnan(v) || !std::isfinite(v) || v < 0 || v > kMaxGap) return std::string(which) + " must be within [0, 200]";
    return "";
}

} // namespace hypr
