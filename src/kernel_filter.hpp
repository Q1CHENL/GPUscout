#ifndef KERNEL_FILTER_HPP
#define KERNEL_FILTER_HPP

#include <algorithm>
#include <cctype>
#include <sstream>
#include <string>
#include <vector>

inline std::string kernel_filter_trim_copy(const std::string &value)
{
    std::size_t begin = 0;
    while (begin < value.size() && std::isspace(static_cast<unsigned char>(value[begin])))
    {
        ++begin;
    }

    std::size_t end = value.size();
    while (end > begin && std::isspace(static_cast<unsigned char>(value[end - 1])))
    {
        --end;
    }

    return value.substr(begin, end - begin);
}

inline std::vector<std::string> parse_kernel_filter_csv(const std::string &csv)
{
    std::vector<std::string> filters;
    if (csv.empty())
    {
        return filters;
    }

    std::stringstream ss(csv);
    std::string token;
    while (std::getline(ss, token, ','))
    {
        token = kernel_filter_trim_copy(token);
        if (token.empty())
        {
            continue;
        }

        if (std::find(filters.begin(), filters.end(), token) == filters.end())
        {
            filters.push_back(token);
        }
    }

    return filters;
}

inline bool kernel_matches_filter(const std::string &kernel_name, const std::vector<std::string> &filters)
{
    if (filters.empty())
    {
        return true;
    }

    for (const auto &filter : filters)
    {
        if (kernel_name.find(filter) != std::string::npos)
        {
            return true;
        }
    }

    return false;
}

#endif // KERNEL_FILTER_HPP
