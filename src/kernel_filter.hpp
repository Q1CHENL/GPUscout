#ifndef GPUSCOUNT_KERNEL_FILTER_HPP
#define GPUSCOUNT_KERNEL_FILTER_HPP

#include <algorithm>
#include <cctype>
#include <string>
#include <vector>

static inline std::string gpuscout_trim_copy(const std::string &s)
{
    size_t start = 0;
    while (start < s.size() && std::isspace(static_cast<unsigned char>(s[start]))) start++;
    size_t end = s.size();
    while (end > start && std::isspace(static_cast<unsigned char>(s[end - 1]))) end--;
    return s.substr(start, end - start);
}

static inline std::vector<std::string> gpuscout_parse_comma_list(const std::string &csv)
{
    std::vector<std::string> out;
    std::string current;
    for (char c : csv)
    {
        if (c == ',')
        {
            auto trimmed = gpuscout_trim_copy(current);
            if (!trimmed.empty()) out.push_back(trimmed);
            current.clear();
        }
        else
        {
            current.push_back(c);
        }
    }
    auto trimmed = gpuscout_trim_copy(current);
    if (!trimmed.empty()) out.push_back(trimmed);

    // Allow a convenience alias.
    if (out.size() == 1 && out[0] == "all")
    {
        out.clear();
    }

    return out;
}

static inline bool gpuscout_kernel_allowed(const std::string &kernel_name, const std::vector<std::string> &patterns)
{
    if (patterns.empty()) return true;
    for (const auto &p : patterns)
    {
        if (p.empty()) continue;
        if (kernel_name.find(p) != std::string::npos) return true;
    }
    return false;
}

#endif
