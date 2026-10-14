// Exact unsigned 256-bit integer with CHECKED arithmetic and a 512-bit mulDiv.
//
// Written from docs/DESIGN.md section 0 / 9.1 (rules R1-R3) only.
// Every operation that would leave [0, 2^256 - 1] (or divide by zero) throws ModelError, which
// is the model's equivalent of "the Solidity call reverts". No floating point anywhere.
#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>

namespace refmodel {

/// The equivalent Solidity call would revert (DESIGN 9.1: R1-R4, or an explicit validation).
class ModelError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

class U256 {
 public:
  static constexpr std::size_t kLimbs = 8;  // 8 x 32 bit, little endian
  using Limbs = std::array<std::uint32_t, kLimbs>;

  U256() = default;
  // Implicit on purpose: lets the model code read like the formulas (`x + 1`, `d == 0`).
  U256(std::uint64_t v) {  // NOLINT(google-explicit-constructor)
    w_[0] = static_cast<std::uint32_t>(v);
    w_[1] = static_cast<std::uint32_t>(v >> 32);
  }

  static U256 max();  // 2^256 - 1
  static U256 fromLimbs(const Limbs& limbs);


  /// 64 lowercase hex digits (one big-endian 32-byte word), no prefix.
  std::string toHex64() const;
  std::string toDecimal() const;

  bool isZero() const;
  /// Low 64 bits (only meaningful once the caller knows the value fits).
  std::uint64_t low64() const {
    return static_cast<std::uint64_t>(w_[0]) | (static_cast<std::uint64_t>(w_[1]) << 32);
  }
  const Limbs& limbs() const { return w_; }

  friend bool operator==(const U256& a, const U256& b) { return a.w_ == b.w_; }
  friend bool operator!=(const U256& a, const U256& b) { return !(a == b); }
  friend bool operator<(const U256& a, const U256& b) { return compare(a, b) < 0; }
  friend bool operator>(const U256& a, const U256& b) { return compare(a, b) > 0; }
  friend bool operator<=(const U256& a, const U256& b) { return compare(a, b) <= 0; }
  friend bool operator>=(const U256& a, const U256& b) { return compare(a, b) >= 0; }

  // Checked arithmetic (R1): throw ModelError on overflow / underflow / division by zero.
  friend U256 operator+(const U256& a, const U256& b);
  friend U256 operator-(const U256& a, const U256& b);
  friend U256 operator*(const U256& a, const U256& b);
  friend U256 operator/(const U256& a, const U256& b);  // floor

 private:
  static int compare(const U256& a, const U256& b);
  Limbs w_{};
};

struct ParseResult {
  std::optional<U256> value;
  const char* error = nullptr;  // set when value is empty
};
/// Decimal ("123") or hex ("0x7b", "0X7B"). No sign, no whitespace, no underscores, non-empty,
/// value < 2^256.
ParseResult parseU256(std::string_view text);

/// floor(a*b/d) with a 512-bit intermediate (R2). Throws if d == 0 or the quotient >= 2^256.
U256 mulDiv(const U256& a, const U256& b, const U256& d);
/// mulDiv plus 1 when a*b mod d != 0 (R2). Also throws if that +1 overflows.
U256 mulDivUp(const U256& a, const U256& b, const U256& d);
/// 10**d as a checked 256-bit power (R3): throws for d >= 78.
U256 pow10(unsigned d);

}  // namespace refmodel
