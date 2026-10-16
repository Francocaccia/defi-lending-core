#include "data.hpp"

#include <fstream>
#include <sstream>
#include <stdexcept>

namespace sim {

namespace {

bool parseUnsigned(const std::string& s, std::uint64_t& out) {
  if (s.empty() || s.size() > 19) return false;
  std::uint64_t v = 0;
  for (char c : s) {
    if (c < '0' || c > '9') return false;
    v = v * 10U + static_cast<std::uint64_t>(c - '0');
  }
  out = v;
  return true;
}

}  // namespace

std::vector<OraclePoint> parseOracleCsv(const std::string& csvText, const std::string& label) {
  std::istringstream in(csvText);
  std::string line;
  if (!std::getline(in, line) || line.rfind("updatedAt,answer", 0) != 0) {
    throw std::runtime_error(label + ": expected the header 'updatedAt,answer'");
  }
  std::vector<OraclePoint> out;
  std::size_t lineNo = 1;
  while (std::getline(in, line)) {
    ++lineNo;
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty()) continue;
    const std::size_t comma = line.find(',');
    std::uint64_t t = 0;
    std::uint64_t a = 0;
    if (comma == std::string::npos || !parseUnsigned(line.substr(0, comma), t) ||
        !parseUnsigned(line.substr(comma + 1), a)) {
      throw std::runtime_error(label + ":" + std::to_string(lineNo) + ": malformed line '" + line +
                               "'");
    }
    if (a == 0) throw std::runtime_error(label + ":" + std::to_string(lineNo) + ": zero answer");
    if (!out.empty() && static_cast<std::int64_t>(t) <= out.back().t) {
      throw std::runtime_error(label + ":" + std::to_string(lineNo) +
                               ": timestamps must strictly increase");
    }
    out.push_back({static_cast<std::int64_t>(t), a});
  }
  if (out.empty()) throw std::runtime_error(label + ": no data rows");
  return out;
}

std::vector<OraclePoint> loadOracleCsv(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) throw std::runtime_error("cannot open price file '" + path + "'");
  std::ostringstream ss;
  ss << f.rdbuf();
  return parseOracleCsv(ss.str(), path);
}

std::vector<OraclePoint> fromTime(const std::vector<OraclePoint>& points, std::int64_t fromUnix) {
  std::vector<OraclePoint> out;
  for (const OraclePoint& p : points) {
    if (p.t >= fromUnix) out.push_back(p);
  }
  if (out.empty()) throw std::runtime_error("no oracle updates at or after the configured 'from' date");
  return out;
}

Grid buildGrid(const std::vector<OraclePoint>& eth, const std::vector<OraclePoint>& usdc,
               std::int64_t stepSeconds, std::uint64_t usdcFallbackAnswer) {
  if (stepSeconds <= 0) throw std::invalid_argument("stepSeconds must be positive");
  if (eth.empty()) throw std::invalid_argument("ETH history is empty");

  Grid g;
  g.step = stepSeconds;
  g.t0 = ((eth.front().t + stepSeconds - 1) / stepSeconds) * stepSeconds;
  const std::int64_t tEnd = eth.back().t;
  if (tEnd < g.t0) throw std::invalid_argument("ETH history shorter than one step");

  const std::size_t n = static_cast<std::size_t>((tEnd - g.t0) / stepSeconds) + 1;
  g.eth.reserve(n);
  g.usdc.reserve(n);

  std::size_t ie = 0;
  std::size_t iu = 0;
  bool usdcStarted = false;
  g.firstRealUsdc = n;  // "never" until proven otherwise
  for (std::size_t i = 0; i < n; ++i) {
    const std::int64_t t = g.timeAt(i);
    while (ie + 1 < eth.size() && eth[ie + 1].t <= t) ++ie;
    g.eth.push_back(eth[ie].answer);

    while (iu < usdc.size() && usdc[iu].t <= t) {
      usdcStarted = true;
      ++iu;
    }
    if (usdcStarted) {
      if (g.firstRealUsdc == n) g.firstRealUsdc = i;
      g.usdc.push_back(usdc[iu - 1].answer);
    } else {
      g.usdc.push_back(usdcFallbackAnswer);
    }
  }
  return g;
}

}  // namespace sim
