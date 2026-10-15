#include "data.hpp"
#include "paths.hpp"
#include "simtest.hpp"

using namespace sim;

namespace {

Grid flatGrid(std::size_t n, std::uint64_t eth = 200000000000ULL) {
  Grid g;
  g.t0 = 0;
  g.step = 3600;
  g.eth.assign(n, eth);
  g.usdc.assign(n, 100000000ULL);
  g.firstRealUsdc = n;
  return g;
}

}  // namespace

TEST(paths_splitmix64_matches_the_reference_sequence) {
  // First outputs of splitmix64 with seed 0 (public reference values).
  SplitMix64 r(0);
  CHECK_EQ(r.next(), static_cast<std::uint64_t>(0xE220A8397B1DCDAFULL));
  CHECK_EQ(r.next(), static_cast<std::uint64_t>(0x6E789E6AA1B965F4ULL));
  CHECK_EQ(r.next(), static_cast<std::uint64_t>(0x06C45D188009454FULL));
}

TEST(paths_uniform_and_below_stay_in_range) {
  SplitMix64 r(42);
  for (int i = 0; i < 1000; ++i) {
    const double u = r.uniform();
    CHECK(u >= 0.0 && u < 1.0);
    CHECK(r.below(7) < 7);
  }
  CHECK_THROWS_ANY(r.below(0));
}

TEST(paths_historical_windows_cover_the_whole_history_without_filtering) {
  const Grid g = flatGrid(100);
  CHECK_EQ(historicalWindowStarts(g, 10, 1).size(), static_cast<std::size_t>(91));  // 0..90
  CHECK_EQ(historicalWindowStarts(g, 10, 10).size(), static_cast<std::size_t>(10));  // 0,10,..,90
  CHECK_EQ(historicalWindowStarts(g, 100, 1).size(), static_cast<std::size_t>(1));
  CHECK_EQ(historicalWindowStarts(g, 101, 1).size(), static_cast<std::size_t>(0));
  CHECK_THROWS_ANY(historicalWindowStarts(g, 10, 0));
  const auto s = historicalWindowStarts(g, 10, 1);
  CHECK_EQ(s.front(), static_cast<std::size_t>(0));
  CHECK_EQ(s.back(), static_cast<std::size_t>(90));
}

TEST(paths_log_returns_are_zero_when_the_price_is_stale) {
  Grid g = flatGrid(4);
  g.eth = {100, 100, 200, 200};
  const ReturnSeries r = logReturns(g);
  CHECK_EQ(r.eth.size(), static_cast<std::size_t>(3));
  CHECK_NEAR(r.eth[0], 0.0, 0.0);
  CHECK_NEAR(r.eth[1], std::log(2.0), 1e-12);
  CHECK_NEAR(r.eth[2], 0.0, 0.0);
  CHECK_NEAR(r.usdc[1], 0.0, 0.0);
}

TEST(paths_bootstrap_is_deterministic_and_seed_sensitive) {
  Grid g = flatGrid(500);
  for (std::size_t i = 0; i < g.size(); ++i) g.eth[i] = 200000000000ULL + 100000000ULL * (i % 37);
  const ReturnSeries r = logReturns(g);

  std::vector<std::uint64_t> e1, u1, e2, u2, e3, u3;
  bootstrapPath(r, 7, 3, 50, 24.0, 200000000000ULL, 100000000ULL, e1, u1);
  bootstrapPath(r, 7, 3, 50, 24.0, 200000000000ULL, 100000000ULL, e2, u2);
  bootstrapPath(r, 7, 4, 50, 24.0, 200000000000ULL, 100000000ULL, e3, u3);
  CHECK(e1 == e2);          // same (seed, path index): identical
  CHECK(u1 == u2);
  CHECK(e1 != e3);          // another path index: different
  CHECK_EQ(e1.size(), static_cast<std::size_t>(50));
  CHECK_EQ(e1[0], static_cast<std::uint64_t>(200000000000ULL));
  CHECK_EQ(u1[0], static_cast<std::uint64_t>(100000000ULL));
  for (std::uint64_t v : e1) CHECK(v >= 1);
}

TEST(paths_bootstrap_of_a_constant_series_is_constant) {
  const Grid g = flatGrid(200);
  const ReturnSeries r = logReturns(g);
  std::vector<std::uint64_t> e, u;
  bootstrapPath(r, 1, 0, 30, 10.0, 123456789012ULL, 100000000ULL, e, u);
  for (std::uint64_t v : e) CHECK_EQ(v, static_cast<std::uint64_t>(123456789012ULL));
}

TEST(paths_bootstrap_rejects_bad_arguments) {
  ReturnSeries empty;
  std::vector<std::uint64_t> e, u;
  CHECK_THROWS_ANY(bootstrapPath(empty, 1, 0, 10, 5.0, 1, 1, e, u));
  const ReturnSeries r = logReturns(flatGrid(10));
  CHECK_THROWS_ANY(bootstrapPath(r, 1, 0, 10, 0.5, 1, 1, e, u));
}
