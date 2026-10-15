#pragma once

#include <string>
#include <vector>

#include "config.hpp"
#include "data.hpp"
#include "runner.hpp"

namespace sim {

/// Markdown report: setup, assumptions, then one results table per horizon (and a per-year table
/// for historical runs). Every number in it comes from `rows`.
std::string renderMarkdown(const Config& cfg, const Grid& grid, const std::vector<Row>& rows);

/// One CSV line per row (machine-readable twin of the tables).
std::string renderCsv(const std::vector<Row>& rows);

/// "2024-03-09" (UTC).
std::string isoDate(std::int64_t unixSeconds);

}  // namespace sim
