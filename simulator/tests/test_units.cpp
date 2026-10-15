#include "model.hpp"
#include "simtest.hpp"
#include "units.hpp"

using refmodel::U256;
using namespace sim;

TEST(units_decimal_fraction_to_wad_is_exact) {
  CHECK_EQ(parseDecimalScaled("0.75", 18), U256(750000000000000000ULL));
  CHECK_EQ(parseDecimalScaled("10", 18), U256(10) * refmodel::WAD);
  CHECK_EQ(parseDecimalScaled("0.000000000000000001", 18), U256(1));
  CHECK_EQ(parseDecimalScaled("1.5", 6), U256(1500000));
}

TEST(units_never_truncate_silently) {
  CHECK_THROWS_ANY(parseDecimalScaled("0.1234567", 6));  // 7 digits into 6 decimals
  CHECK_THROWS_ANY(parseDecimalScaled("1e18", 18));
  CHECK_THROWS_ANY(parseDecimalScaled("-1", 18));
  CHECK_THROWS_ANY(parseDecimalScaled("", 18));
  CHECK_THROWS_ANY(parseDecimalScaled("1.", 18));  // a dot with no digits after it
}

TEST(units_wad_param_accepts_fraction_or_raw_wad) {
  CHECK_EQ(parseWadParam("0.8"), parseWadParam("800000000000000000"));
  CHECK_EQ(parseWadParam("0.04"), U256(40000000000000000ULL));
  CHECK_EQ(parseWadParam("1.0"), refmodel::WAD);
  CHECK_THROWS_ANY(parseWadParam("abc"));
}

TEST(units_uint_parsing) {
  CHECK_EQ(parseUint("0"), U256(0));
  CHECK_EQ(parseUint("123456789012345678901234567890").toDecimal(), std::string("123456789012345678901234567890"));
  CHECK_THROWS_ANY(parseUint("0x10"));
  CHECK_THROWS_ANY(parseUint("12a"));
  CHECK_THROWS_ANY(parseUint(
      "115792089237316195423570985008687907853269984665640564039457584007913129639936"));  // 2^256
}

TEST(units_toDouble_is_close_and_monotone) {
  CHECK_NEAR(toDouble(U256(1000000)), 1e6, 0.0);
  CHECK_NEAR(toDouble(parseUint("1000000000000000000000")), 1e21, 1e6);
  CHECK(toDouble(parseUint("2000000000000000000000")) >= toDouble(parseUint("1999999999999999999999")));
}

TEST(units_formatScaled) {
  CHECK_EQ(formatScaled(U256(1500000000000000000ULL), 18, 4), std::string("1.5000"));
  CHECK_EQ(formatScaled(U256(5), 6, 6), std::string("0.000005"));
  CHECK_EQ(formatScaled(U256(1234567), 6, 2), std::string("1.23"));
  CHECK_EQ(formatScaled(U256(1234567), 6, 0), std::string("1"));
}

TEST(units_yearOf_handles_epoch_leap_days_and_negatives) {
  CHECK_EQ(yearOf(0), 1970);
  CHECK_EQ(yearOf(-1), 1969);
  CHECK_EQ(yearOf(1582934400), 2020);   // 2020-02-29 00:00 UTC
  CHECK_EQ(yearOf(1583020800), 2020);   // 2020-03-01
  CHECK_EQ(yearOf(1609459199), 2020);   // 2020-12-31 23:59:59
  CHECK_EQ(yearOf(1609459200), 2021);   // 2021-01-01 00:00:00
}
