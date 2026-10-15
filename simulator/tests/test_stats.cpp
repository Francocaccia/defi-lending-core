#include "simtest.hpp"
#include "stats.hpp"

using namespace sim;

TEST(stats_quantiles_interpolate_linearly) {
  const std::vector<double> v = {1.0, 2.0, 3.0, 4.0, 5.0};
  CHECK_NEAR(quantileSorted(v, 0.0), 1.0, 0.0);
  CHECK_NEAR(quantileSorted(v, 1.0), 5.0, 0.0);
  CHECK_NEAR(quantileSorted(v, 0.5), 3.0, 1e-12);
  CHECK_NEAR(quantileSorted(v, 0.25), 2.0, 1e-12);
  CHECK_NEAR(quantileSorted(v, 0.125), 1.5, 1e-12);
  CHECK_NEAR(quantileSorted({}, 0.5), 0.0, 0.0);
  CHECK_NEAR(quantileSorted({7.0}, 0.99), 7.0, 0.0);
}

TEST(stats_wilson_interval_matches_known_values) {
  // Standard reference values for the 95% Wilson interval.
  const Interval a = wilson95(5, 10);
  CHECK_NEAR(a.lo, 0.2366, 5e-4);
  CHECK_NEAR(a.hi, 0.7634, 5e-4);
  const Interval z = wilson95(0, 10);
  CHECK_NEAR(z.lo, 0.0, 1e-12);
  CHECK_NEAR(z.hi, 0.2775, 5e-4);
  const Interval all = wilson95(10, 10);
  CHECK_NEAR(all.hi, 1.0, 1e-12);
  const Interval none = wilson95(0, 0);
  CHECK_NEAR(none.lo + none.hi, 0.0, 0.0);
}

TEST(stats_wilson_stays_inside_zero_one_and_shrinks_with_n) {
  const Interval small = wilson95(1, 10);
  const Interval big = wilson95(100, 1000);
  CHECK(small.lo >= 0.0 && small.hi <= 1.0);
  CHECK((big.hi - big.lo) < (small.hi - small.lo));
}

TEST(stats_episodes_group_nearby_indices) {
  CHECK_EQ(countEpisodes({}, 5), static_cast<std::size_t>(0));
  CHECK_EQ(countEpisodes({10}, 5), static_cast<std::size_t>(1));
  CHECK_EQ(countEpisodes({10, 11, 12, 13}, 5), static_cast<std::size_t>(1));
  CHECK_EQ(countEpisodes({10, 11, 40, 41, 100}, 5), static_cast<std::size_t>(3));
  CHECK_EQ(countEpisodes({10, 15, 20}, 5), static_cast<std::size_t>(1));  // gap == maxGap still joins
  CHECK_EQ(countEpisodes({10, 16}, 5), static_cast<std::size_t>(2));
}
