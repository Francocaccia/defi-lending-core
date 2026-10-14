// Tests of the 256-bit checked integer and the 512-bit mulDiv (DESIGN 9.1: R1, R2, R3).
#include "model.hpp"
#include "testlib.hpp"

using namespace refmodel;

namespace {
U256 U(const char* s) {
  const ParseResult p = parseU256(s);
  if (!p.value) throw std::runtime_error(std::string("bad literal in test: ") + s);
  return *p.value;
}
const char* const kMax =
    "115792089237316195423570985008687907853269984665640564039457584007913129639935";
const char* const k2p255 =
    "57896044618658097711785492504343953926634992332820282019728792003956564819968";
const char* const k2p128 = "340282366920938463463374607431768211456";
}  // namespace

TEST(parse_decimal_and_hex) {
  CHECK_EQ(U("0"), U256(0));
  CHECK_EQ(U("123"), U256(123));
  CHECK_EQ(U("0x7b"), U256(123));
  CHECK_EQ(U("0X7B"), U256(123));
  CHECK_EQ(U("0xFf"), U256(255));
  CHECK_EQ(U("0x0"), U256(0));
  CHECK_EQ(U("007"), U256(7));  // leading zeros are accepted (documented in the report)
  CHECK_EQ(U("18446744073709551615"), U256(0xFFFFFFFFFFFFFFFFULL));
  CHECK_EQ(U("18446744073709551616").toHex64(),
           std::string("0000000000000000000000000000000000000000000000010000000000000000"));
}

TEST(parse_bounds) {
  CHECK_EQ(U(kMax), U256::max());
  CHECK_EQ(U("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"), U256::max());
  CHECK(parseU256("0x10000000000000000000000000000000000000000000000000000000000000000")
            .value == std::nullopt);  // 2^256
  CHECK(parseU256("115792089237316195423570985008687907853269984665640564039457584007913129639936")
            .value == std::nullopt);  // 2^256
  // many leading zeros are fine as long as the VALUE fits
  CHECK(parseU256("0x000000000000000000000000000000000000000000000000000000000000000000001")
            .value.has_value());
}

TEST(parse_rejects_malformed) {
  const char* bad[] = {"",   "-1", "+1",  " 1", "1 ", "1_000", "1e3", "0x",  "0X",
                       "0xg", "abc", "0b1", "1.5", "--1", "0x 1", "١٢٣", "1\n", "x10"};
  for (const char* s : bad) CHECK(!parseU256(s).value.has_value());
  CHECK(parseU256("").error != nullptr);
}

TEST(to_string_roundtrip) {
  CHECK_EQ(U256::max().toDecimal(), std::string(kMax));
  CHECK_EQ(U256(0).toDecimal(), std::string("0"));
  CHECK_EQ(U256(1).toHex64(),
           std::string("0000000000000000000000000000000000000000000000000000000000000001"));
  CHECK_EQ(U256::max().toHex64(), std::string(64, 'f'));
  CHECK_EQ(U(k2p128).toHex64(),
           std::string("0000000000000000000000000000000100000000000000000000000000000000"));
  CHECK_EQ(U(k2p255).toHex64(),
           std::string("8000000000000000000000000000000000000000000000000000000000000000"));
}

TEST(checked_add_sub_mul) {
  CHECK_EQ(U256::max() + U256(0), U256::max());
  CHECK_THROWS(U256::max() + U256(1));
  CHECK_THROWS(U256::max() + U256::max());
  CHECK_EQ(U("340282366920938463463374607431768211455") + U256(1), U(k2p128));  // carry chain
  CHECK_EQ(U256(0) - U256(0), U256(0));
  CHECK_THROWS(U256(0) - U256(1));
  CHECK_EQ(U(k2p128) - U256(1), U("340282366920938463463374607431768211455"));
  CHECK_EQ(U256::max() - U256::max(), U256(0));
  CHECK_EQ(U256::max() * U256(1), U256::max());
  CHECK_EQ(U256::max() * U256(0), U256(0));
  CHECK_THROWS(U256::max() * U256(2));
  CHECK_EQ(U(k2p255) * U256(1), U(k2p255));
  CHECK_THROWS(U(k2p255) * U256(2));                    // exactly 2^256
  CHECK_THROWS(U(k2p128) * U(k2p128));                  // exactly 2^256
  CHECK_EQ(U("340282366920938463463374607431768211455") * U("340282366920938463463374607431768211457"),
           U256::max());                                // (2^128-1)(2^128+1) = 2^256-1
  CHECK_THROWS(U256::max() / U256(0));
  CHECK_EQ(U256::max() / U256(1), U256::max());
  CHECK_EQ(U256::max() / U256::max(), U256(1));
  CHECK_EQ(U256(7) / U256(2), U256(3));
}

TEST(mulDiv_basic_and_rounding) {
  CHECK_EQ(mulDiv(U256(6), U256(7), U256(3)), U256(14));
  CHECK_EQ(mulDivUp(U256(6), U256(7), U256(3)), U256(14));  // exact: no round-up
  CHECK_EQ(mulDiv(U256(10), U256(10), U256(7)), U256(14));
  CHECK_EQ(mulDivUp(U256(10), U256(10), U256(7)), U256(15));  // 100/7 = 14.28
  CHECK_EQ(mulDiv(U256(0), U256::max(), U256(1)), U256(0));
  CHECK_EQ(mulDivUp(U256(0), U256::max(), U256(1)), U256(0));
  CHECK_EQ(mulDiv(U256(1), U256(1), U256::max()), U256(0));
  CHECK_EQ(mulDivUp(U256(1), U256(1), U256::max()), U256(1));  // 1 wei debt stays 1
}

TEST(mulDiv_uses_a_512_bit_intermediate) {
  // a*b = 2^510 does not fit in 256 bits, but the quotient 2^255 does.
  CHECK_EQ(mulDiv(U(k2p255), U(k2p255), U(k2p255)), U(k2p255));
  CHECK_EQ(mulDiv(U256::max(), U256::max(), U256::max()), U256::max());
  CHECK_EQ(mulDivUp(U256::max(), U256::max(), U256::max()), U256::max());
  CHECK_EQ(mulDiv(U(k2p128), U(k2p128), U(k2p128)), U(k2p128));
  // (2^256-1)(2^256-2) / (2^256-1) = 2^256 - 2, with a 512-bit product
  CHECK_EQ(mulDiv(U256::max(), U256::max() - U256(1), U256::max()), U256::max() - U256(1));
  // (2^256-1)^2 / 2^255 = 2^257 - 4 + ...: too big -> fails, while /(2^256-1) is fine
  CHECK_THROWS(mulDiv(U256::max(), U256::max(), U(k2p255)));
}

TEST(mulDiv_result_exactly_2p256_minus_1_and_2p256) {
  // quotient == 2^256 - 1 is representable ...
  CHECK_EQ(mulDiv(U256::max(), U256(1), U256(1)), U256::max());
  CHECK_EQ(mulDiv(U256::max(), U256(2), U256(2)), U256::max());
  CHECK_EQ(mulDivUp(U256::max(), U256(2), U256(2)), U256::max());  // exact: no +1
  // ... quotient == 2^256 is not
  CHECK_THROWS(mulDiv(U(k2p255), U256(2), U256(1)));
  // floor(max/2) = 2^255 - 1, round-up gives 2^255
  CHECK_EQ(mulDiv(U256::max(), U256(1), U256(2)), U(k2p255) - U256(1));
  CHECK_EQ(mulDivUp(U256::max(), U256(1), U256(2)), U(k2p255));
}

TEST(mulDiv_overflow_boundary) {
  // quotient == 2^256 exactly -> fails
  CHECK_THROWS(mulDiv(U(k2p255), U256(2), U256(1)));
  CHECK_THROWS(mulDivUp(U(k2p255), U256(2), U256(1)));
  CHECK_THROWS(mulDiv(U(k2p128), U(k2p128), U256(1)));
  CHECK_THROWS(mulDiv(U256::max(), U256::max(), U256(1)));
  // quotient == 2^256 - 1 + fraction: (2^256-1)*d + 1 over d, found by a modular inverse:
  // a*b = (2^256-1)*d + 1  => mulDiv = 2^256-1 (fits), mulDivUp = 2^256 (+1 overflows)
  const U256 a = U("1606938044258990275541962092341162602522202993782792835301383");
  const U256 b =
      U("33571719514527927688003370120315708714688003647103931905614409415612082230172");
  const U256 d = U("465901199766082347975040408032339332915050584370319107585725");
  CHECK_EQ(mulDiv(a, b, d), U256::max());
  CHECK_THROWS(mulDivUp(a, b, d));
}

TEST(mulDiv_division_by_zero) {
  CHECK_THROWS(mulDiv(U256(0), U256(0), U256(0)));
  CHECK_THROWS(mulDivUp(U256(1), U256(1), U256(0)));
  CHECK_THROWS(mulDiv(U256::max(), U256::max(), U256(0)));
}

TEST(mulDiv_across_limb_boundaries) {
  // 2^32 - 1, 2^32, 2^64 neighbourhoods: carries inside the schoolbook product and the divider
  const U256 x = U("4294967295");
  const U256 y = U("4294967296");
  CHECK_EQ(mulDiv(x, y, y), x);
  CHECK_EQ(mulDiv(x * y, y, x), y * y);
  CHECK_EQ(mulDiv(U("18446744073709551615"), U("18446744073709551617"), U("18446744073709551615")),
           U("18446744073709551617"));
  CHECK_EQ(mulDiv(U("123456789012345678901234567890"), U("987654321098765432109876543210"),
                  U("1000000000000000000000000000000")),
           U("121932631137021795226185032733"));  // floor, computed independently in Python
}

TEST(pow10_boundaries) {
  CHECK_EQ(pow10(0), U256(1));
  CHECK_EQ(pow10(1), U256(10));
  CHECK_EQ(pow10(18), WAD);
  CHECK_EQ(pow10(27), RAY);
  CHECK_EQ(pow10(76).toDecimal(), std::string("1") + std::string(76, '0'));
  CHECK_EQ(pow10(77).toDecimal(), std::string("1") + std::string(77, '0'));
  CHECK(pow10(77) < U256::max());
  CHECK_THROWS(pow10(78));
  CHECK_THROWS(pow10(79));
  CHECK_THROWS(pow10(255));
}

TEST(constants) {
  CHECK_EQ(WAD, U("1000000000000000000"));
  CHECK_EQ(RAY, U("1000000000000000000000000000"));
  CHECK_EQ(WAD_TO_RAY, U("1000000000"));
  CHECK_EQ(SECONDS_PER_YEAR, U256(365ULL * 86400ULL));
  CHECK_EQ(VIRTUAL_SHARES, U256(1000000));
  CHECK_EQ(VIRTUAL_ASSETS, U256(1));
  CHECK_EQ(MAX_ANNUAL_RATE, U("10000000000000000000"));
  CHECK_EQ(MAX_LIQUIDATION_BONUS, U("250000000000000000"));
  CHECK_EQ(UINT256_MAX, U(kMax));
}
