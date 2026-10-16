#include <fstream>

#include "data.hpp"
#include "simtest.hpp"

using namespace sim;

TEST(data_parses_a_valid_csv) {
  const auto pts = parseOracleCsv("updatedAt,answer\n100,200000000000\n250,210000000000\r\n", "t");
  CHECK_EQ(pts.size(), static_cast<std::size_t>(2));
  CHECK_EQ(pts[0].t, static_cast<std::int64_t>(100));
  CHECK_EQ(pts[1].answer, static_cast<std::uint64_t>(210000000000ULL));
}

TEST(data_rejects_bad_files) {
  CHECK_THROWS_ANY(parseOracleCsv("time,price\n1,2\n", "t"));                 // wrong header
  CHECK_THROWS_ANY(parseOracleCsv("updatedAt,answer\n", "t"));                // no rows
  CHECK_THROWS_ANY(parseOracleCsv("updatedAt,answer\n5,0\n", "t"));           // zero answer
  CHECK_THROWS_ANY(parseOracleCsv("updatedAt,answer\n5,7\n5,8\n", "t"));      // not strictly increasing
  CHECK_THROWS_ANY(parseOracleCsv("updatedAt,answer\n5,7\n4,8\n", "t"));      // decreasing
  CHECK_THROWS_ANY(parseOracleCsv("updatedAt,answer\n5;7\n", "t"));           // malformed
  CHECK_THROWS_ANY(parseOracleCsv("updatedAt,answer\n5,-7\n", "t"));          // negative
  CHECK_THROWS_ANY(loadOracleCsv("this/file/does/not/exist.csv"));
}

TEST(data_grid_carries_the_last_round_forward) {
  // ETH updates at 100, 250, 300; the grid is hourly-in-miniature: every 100 s starting at 100.
  const auto eth = parseOracleCsv("updatedAt,answer\n100,1000\n250,2000\n300,3000\n", "eth");
  const auto usdc = parseOracleCsv("updatedAt,answer\n220,99000000\n", "usdc");
  const Grid g = buildGrid(eth, usdc, 100);
  CHECK_EQ(g.size(), static_cast<std::size_t>(3));  // t = 100, 200, 300
  CHECK_EQ(g.t0, static_cast<std::int64_t>(100));
  CHECK_EQ(g.eth[0], static_cast<std::uint64_t>(1000));
  CHECK_EQ(g.eth[1], static_cast<std::uint64_t>(1000));  // 250 not yet seen at t = 200
  CHECK_EQ(g.eth[2], static_cast<std::uint64_t>(3000));  // by t = 300 the 250 and 300 rounds exist: last wins
  // USDC: fallback $1.00 until its first real round (t = 220), then carried forward.
  CHECK_EQ(g.usdc[0], static_cast<std::uint64_t>(100000000));
  CHECK_EQ(g.usdc[1], static_cast<std::uint64_t>(100000000));
  CHECK_EQ(g.usdc[2], static_cast<std::uint64_t>(99000000));
  CHECK_EQ(g.firstRealUsdc, static_cast<std::size_t>(2));
}

TEST(data_grid_start_is_rounded_up_to_the_step) {
  const auto eth = parseOracleCsv("updatedAt,answer\n130,1000\n900,2000\n", "eth");
  const auto usdc = parseOracleCsv("updatedAt,answer\n1,100000000\n", "usdc");
  const Grid g = buildGrid(eth, usdc, 100);
  CHECK_EQ(g.t0, static_cast<std::int64_t>(200));
  CHECK_EQ(g.timeAt(1), static_cast<std::int64_t>(300));
  CHECK_EQ(g.firstRealUsdc, static_cast<std::size_t>(0));
}

TEST(data_grid_without_usdc_history_assumes_one_dollar_everywhere) {
  const auto eth = parseOracleCsv("updatedAt,answer\n0,1000\n500,2000\n", "eth");
  const auto usdc = parseOracleCsv("updatedAt,answer\n99999,100000000\n", "usdc");
  const Grid g = buildGrid(eth, usdc, 100);
  CHECK_EQ(g.firstRealUsdc, g.size());  // "never"
  for (std::uint64_t v : g.usdc) CHECK_EQ(v, static_cast<std::uint64_t>(100000000));
}

TEST(data_committed_history_is_sane_when_present) {
  // The real Chainlink history is committed under simulator/data. If it has not been fetched yet
  // (a fresh checkout of an early commit) the test has nothing to say.
  const std::string path = std::string(SIM_SOURCE_DIR) + "/data/eth_usd_chainlink.csv";
  std::ifstream probe(path);
  if (!probe) return;
  const auto eth = loadOracleCsv(path);  // already enforces strictly increasing time and answer > 0
  CHECK(eth.size() > 10000);
  CHECK(eth.front().t > 1596000000);  // Aug 2020 or later (the proxy has no older data)
  std::uint64_t lo = ~static_cast<std::uint64_t>(0);
  std::uint64_t hi = 0;
  for (const auto& p : eth) {
    if (p.answer < lo) lo = p.answer;
    if (p.answer > hi) hi = p.answer;
  }
  CHECK(lo > 10000000000ULL);    // never below $100 in this period
  CHECK(hi < 1000000000000ULL);  // never above $10,000
}

TEST(data_fromTime_keeps_only_updates_at_or_after_the_date) {
  const std::vector<OraclePoint> pts = {{100, 1}, {200, 2}, {300, 3}};
  CHECK_EQ(fromTime(pts, 200).size(), static_cast<std::size_t>(2));
  CHECK_EQ(fromTime(pts, 200).front().answer, static_cast<std::uint64_t>(2));
  CHECK_EQ(fromTime(pts, 0).size(), static_cast<std::size_t>(3));
  CHECK_THROWS_ANY(fromTime(pts, 301));
}
