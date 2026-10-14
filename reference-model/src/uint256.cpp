#include "uint256.hpp"

#include <algorithm>

namespace refmodel {

namespace {

constexpr std::size_t kWide = 16;  // 512 bit
using Wide = std::array<std::uint32_t, kWide>;

Wide widen(const U256::Limbs& a) {
  Wide r{};
  for (std::size_t i = 0; i < U256::kLimbs; ++i) r[i] = a[i];
  return r;
}

/// Full 256 x 256 -> 512 bit product (schoolbook, 32-bit limbs, 64-bit intermediates).
Wide mulWide(const U256::Limbs& a, const U256::Limbs& b) {
  Wide r{};
  for (std::size_t i = 0; i < U256::kLimbs; ++i) {
    std::uint64_t carry = 0;
    for (std::size_t j = 0; j < U256::kLimbs; ++j) {
      // (2^32-1)^2 + 2*(2^32-1) = 2^64 - 1: never overflows 64 bits.
      const std::uint64_t cur = static_cast<std::uint64_t>(a[i]) * b[j] + r[i + j] + carry;
      r[i + j] = static_cast<std::uint32_t>(cur);
      carry = cur >> 32;
    }
    r[i + U256::kLimbs] = static_cast<std::uint32_t>(carry);  // slot untouched so far
  }
  return r;
}

bool fits256(const Wide& w) {
  for (std::size_t i = U256::kLimbs; i < kWide; ++i)
    if (w[i] != 0) return false;
  return true;
}

U256::Limbs narrow(const Wide& w) {
  U256::Limbs r{};
  for (std::size_t i = 0; i < U256::kLimbs; ++i) r[i] = w[i];
  return r;
}

int cmpWide(const Wide& a, const Wide& b) {
  for (std::size_t i = kWide; i-- > 0;) {
    if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return 0;
}

void subWide(Wide& a, const Wide& b) {  // a -= b, requires a >= b
  std::int64_t borrow = 0;
  for (std::size_t i = 0; i < kWide; ++i) {
    std::int64_t cur = static_cast<std::int64_t>(a[i]) - b[i] - borrow;
    borrow = cur < 0 ? 1 : 0;
    if (cur < 0) cur += (static_cast<std::int64_t>(1) << 32);
    a[i] = static_cast<std::uint32_t>(cur);
  }
}

void shl1(Wide& a) {
  std::uint32_t carry = 0;
  for (std::size_t i = 0; i < kWide; ++i) {
    const std::uint32_t next = a[i] >> 31;
    a[i] = (a[i] << 1) | carry;
    carry = next;
  }
}

/// Binary long division n / d (d != 0). Deliberately the simplest correct algorithm
/// (one shift-and-subtract step per bit): speed is irrelevant for a CLI that handles one
/// call per process, and simplicity is what makes the 512-bit path easy to trust.
/// During the loop r < 2d < 2^257, so 512 bits are plenty.
void divmodWide(const Wide& n, const U256::Limbs& d, Wide& q, Wide& r) {
  const Wide dd = widen(d);
  q = Wide{};
  r = Wide{};
  for (int i = static_cast<int>(kWide * 32) - 1; i >= 0; --i) {
    shl1(r);
    r[0] |= (n[static_cast<std::size_t>(i) / 32] >> (static_cast<unsigned>(i) % 32)) & 1U;
    if (cmpWide(r, dd) >= 0) {
      subWide(r, dd);
      q[static_cast<std::size_t>(i) / 32] |= 1U << (static_cast<unsigned>(i) % 32);
    }
  }
}

/// limbs = limbs * m + add; returns false on overflow beyond 256 bits.
bool mulSmallAdd(U256::Limbs& l, std::uint32_t m, std::uint32_t add) {
  std::uint64_t carry = add;
  for (std::size_t i = 0; i < U256::kLimbs; ++i) {
    const std::uint64_t cur = static_cast<std::uint64_t>(l[i]) * m + carry;
    l[i] = static_cast<std::uint32_t>(cur);
    carry = cur >> 32;
  }
  return carry == 0;
}

}  // namespace

U256 U256::fromLimbs(const Limbs& l) {
  U256 r;
  r.w_ = l;
  return r;
}

U256 U256::max() {
  U256 r;
  r.w_.fill(0xFFFFFFFFU);
  return r;
}

int U256::compare(const U256& a, const U256& b) {
  for (std::size_t i = kLimbs; i-- > 0;) {
    if (a.w_[i] != b.w_[i]) return a.w_[i] < b.w_[i] ? -1 : 1;
  }
  return 0;
}

bool U256::isZero() const {
  return std::all_of(w_.begin(), w_.end(), [](std::uint32_t x) { return x == 0; });
}

U256 operator+(const U256& a, const U256& b) {
  U256 r;
  std::uint64_t carry = 0;
  for (std::size_t i = 0; i < U256::kLimbs; ++i) {
    const std::uint64_t cur = static_cast<std::uint64_t>(a.w_[i]) + b.w_[i] + carry;
    r.w_[i] = static_cast<std::uint32_t>(cur);
    carry = cur >> 32;
  }
  if (carry != 0) throw ModelError("addition overflow");
  return r;
}

U256 operator-(const U256& a, const U256& b) {
  if (a < b) throw ModelError("subtraction underflow");
  U256 r;
  std::int64_t borrow = 0;
  for (std::size_t i = 0; i < U256::kLimbs; ++i) {
    std::int64_t cur = static_cast<std::int64_t>(a.w_[i]) - b.w_[i] - borrow;
    borrow = cur < 0 ? 1 : 0;
    if (cur < 0) cur += (static_cast<std::int64_t>(1) << 32);
    r.w_[i] = static_cast<std::uint32_t>(cur);
  }
  return r;
}

U256 operator*(const U256& a, const U256& b) {
  const Wide p = mulWide(a.w_, b.w_);
  if (!fits256(p)) throw ModelError("multiplication overflow");
  U256 r;
  r.w_ = narrow(p);
  return r;
}

U256 operator/(const U256& a, const U256& b) {
  if (b.isZero()) throw ModelError("division by zero");
  Wide q, rem;
  divmodWide(widen(a.w_), b.w_, q, rem);
  U256 r;
  r.w_ = narrow(q);  // a < 2^256 so the quotient fits
  return r;
}

namespace {
struct MulDivResult {
  U256 quotient;
  bool inexact;
};
MulDivResult mulDivImpl(const U256& a, const U256& b, const U256& d) {
  if (d.isZero()) throw ModelError("mulDiv: division by zero");
  const Wide p = mulWide(a.limbs(), b.limbs());
  Wide q, rem;
  divmodWide(p, d.limbs(), q, rem);
  if (!fits256(q)) throw ModelError("mulDiv: quotient does not fit in 256 bits");
  const bool inexact =
      std::any_of(rem.begin(), rem.end(), [](std::uint32_t x) { return x != 0; });
  return {U256::fromLimbs(narrow(q)), inexact};
}
}  // namespace

U256 mulDiv(const U256& a, const U256& b, const U256& d) { return mulDivImpl(a, b, d).quotient; }

U256 mulDivUp(const U256& a, const U256& b, const U256& d) {
  const MulDivResult r = mulDivImpl(a, b, d);
  if (!r.inexact) return r.quotient;
  if (r.quotient == U256::max()) throw ModelError("mulDivUp: rounding up overflows");
  return r.quotient + U256(1);
}

U256 pow10(unsigned d) {
  if (d >= 78) throw ModelError("10**d overflows 256 bits (d >= 78)");
  U256 r(1);
  for (unsigned i = 0; i < d; ++i) r = r * U256(10);  // exact: 10^77 < 2^256
  return r;
}

ParseResult parseU256(std::string_view text) {
  if (text.empty()) return {std::nullopt, "empty argument"};
  unsigned base = 10;
  if (text.size() >= 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X')) {
    base = 16;
    text.remove_prefix(2);
    if (text.empty()) return {std::nullopt, "hex argument has no digits"};
  }
  U256::Limbs l{};
  for (char c : text) {
    unsigned digit;
    if (c >= '0' && c <= '9') {
      digit = static_cast<unsigned>(c - '0');
    } else if (base == 16 && c >= 'a' && c <= 'f') {
      digit = static_cast<unsigned>(c - 'a') + 10;
    } else if (base == 16 && c >= 'A' && c <= 'F') {
      digit = static_cast<unsigned>(c - 'A') + 10;
    } else {
      return {std::nullopt, "argument is not an unsigned decimal or 0x-hex integer"};
    }
    if (!mulSmallAdd(l, base, digit)) return {std::nullopt, "argument does not fit in 256 bits"};
  }
  return {U256::fromLimbs(l), nullptr};
}

std::string U256::toHex64() const {
  static const char* kDigits = "0123456789abcdef";
  std::string s;
  s.reserve(64);
  for (std::size_t i = kLimbs; i-- > 0;) {
    for (int nib = 7; nib >= 0; --nib) s.push_back(kDigits[(w_[i] >> (nib * 4)) & 0xF]);
  }
  return s;
}

std::string U256::toDecimal() const {
  if (isZero()) return "0";
  Limbs l = w_;
  std::string rev;
  while (!std::all_of(l.begin(), l.end(), [](std::uint32_t x) { return x == 0; })) {
    std::uint64_t rem = 0;  // divide l by 10 in place
    for (std::size_t i = kLimbs; i-- > 0;) {
      const std::uint64_t cur = (rem << 32) | l[i];
      l[i] = static_cast<std::uint32_t>(cur / 10);
      rem = cur % 10;
    }
    rev.push_back(static_cast<char>('0' + rem));
  }
  std::reverse(rev.begin(), rev.end());
  return rev;
}

}  // namespace refmodel
