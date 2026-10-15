// Oracle price history: CSV loading and the regular observation grid the simulator steps on.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace sim {

/// One oracle update: unix seconds and the feed's integer answer (8 decimals for the USD feeds).
struct OraclePoint {
  std::int64_t t = 0;
  std::uint64_t answer = 0;
};

/// Loads `updatedAt,answer` (one header line). Throws std::runtime_error on any malformed line, a
/// non-positive answer, or a timestamp that does not strictly increase.
std::vector<OraclePoint> loadOracleCsv(const std::string& path);
std::vector<OraclePoint> parseOracleCsv(const std::string& csvText, const std::string& label);

/// Prices on a regular time grid. At grid time g the value is the LAST oracle update with
/// `updatedAt <= g` (carry-forward), which is exactly what a contract reading the feed at that
/// moment would see (an un-updated feed stays at its last answer until its next round).
struct Grid {
  std::int64_t t0 = 0;    // time of index 0
  std::int64_t step = 0;  // seconds between indices
  std::vector<std::uint64_t> eth;
  std::vector<std::uint64_t> usdc;
  /// First grid index at which a REAL USDC/USD answer exists. Before it the USDC price is the
  /// fallback assumption (1.00000000), which the report must state.
  std::size_t firstRealUsdc = 0;

  std::size_t size() const { return eth.size(); }
  std::int64_t timeAt(std::size_t i) const { return t0 + static_cast<std::int64_t>(i) * step; }
};

/// Grid spanning the ETH history (first update rounded up to the step, last update included).
Grid buildGrid(const std::vector<OraclePoint>& eth, const std::vector<OraclePoint>& usdc,
               std::int64_t stepSeconds, std::uint64_t usdcFallbackAnswer = 100000000ULL);

}  // namespace sim
