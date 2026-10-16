#include "units.hpp"

#include <cstddef>
#include <stdexcept>

namespace sim {

namespace {

bool allDigits(const std::string& s) {
  if (s.empty()) return false;
  for (char c : s) {
    if (c < '0' || c > '9') return false;
  }
  return true;
}

}  // namespace

U256 parseUint(const std::string& text) {
  if (!allDigits(text)) throw std::invalid_argument("not a non-negative integer: '" + text + "'");
  const refmodel::ParseResult r = refmodel::parseU256(text);
  if (!r.value) throw std::invalid_argument("integer out of range: '" + text + "'");
  return *r.value;
}

U256 parseDecimalScaled(const std::string& text, unsigned decimals) {
  const std::size_t dot = text.find('.');
  const std::string whole = dot == std::string::npos ? text : text.substr(0, dot);
  std::string frac = dot == std::string::npos ? std::string() : text.substr(dot + 1);
  if (!allDigits(whole) || (dot != std::string::npos && !allDigits(frac))) {
    throw std::invalid_argument("not a decimal number: '" + text + "'");
  }
  if (frac.size() > decimals) {
    throw std::invalid_argument("'" + text + "' has more than " + std::to_string(decimals) +
                                " fractional digits");
  }
  frac.append(decimals - frac.size(), '0');
  return parseUint(whole + frac);
}

U256 parseWadParam(const std::string& text) {
  if (text.find('.') != std::string::npos) return parseDecimalScaled(text, 18);
  return parseUint(text);
}

double toDouble(const U256& v) {
  const auto& l = v.limbs();
  double out = 0.0;
  for (std::size_t i = U256::kLimbs; i-- > 0;) {
    out = out * 4294967296.0 + static_cast<double>(l[i]);
  }
  return out;
}

std::string formatScaled(const U256& v, unsigned decimals, unsigned shown) {
  const U256 unit = refmodel::pow10(decimals);
  const U256 whole = v / unit;
  const U256 rem = v - whole * unit;
  std::string frac;
  if (shown > 0) {
    const U256 scaled = rem / refmodel::pow10(decimals - (shown < decimals ? shown : decimals));
    frac = scaled.toDecimal();
    const unsigned width = shown < decimals ? shown : decimals;
    if (frac.size() < width) frac.insert(0, width - frac.size(), '0');
  }
  return shown == 0 ? whole.toDecimal() : whole.toDecimal() + "." + frac;
}

std::int64_t parseIsoDate(const std::string& text) {
  const auto bad = [&text]() { return std::invalid_argument("date must look like YYYY-MM-DD, got '" + text + "'"); };
  if (text.size() != 10 || text[4] != '-' || text[7] != '-') throw bad();
  for (std::size_t i = 0; i < text.size(); ++i) {
    if (i != 4 && i != 7 && (text[i] < '0' || text[i] > '9')) throw bad();
  }
  std::int64_t y = std::stoi(text.substr(0, 4));
  const std::int64_t m = std::stoi(text.substr(5, 2));
  const std::int64_t d = std::stoi(text.substr(8, 2));
  static const int kDays[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  const bool leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
  if (m < 1 || m > 12 || d < 1 || d > kDays[m - 1] + ((m == 2 && leap) ? 1 : 0)) throw bad();
  // Howard Hinnant's days_from_civil.
  if (m <= 2) --y;
  const std::int64_t era = (y >= 0 ? y : y - 399) / 400;
  const std::int64_t yoe = y - era * 400;
  const std::int64_t doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
  const std::int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return (era * 146097 + doe - 719468) * 86400;
}

int yearOf(std::int64_t unixSeconds) {
  // Howard Hinnant's civil_from_days.
  std::int64_t z = unixSeconds / 86400;
  if (unixSeconds % 86400 < 0) --z;
  z += 719468;
  const std::int64_t era = (z >= 0 ? z : z - 146096) / 146097;
  const std::int64_t doe = z - era * 146097;
  const std::int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  std::int64_t y = yoe + era * 400;
  const std::int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  const std::int64_t mp = (5 * doy + 2) / 153;
  const std::int64_t m = mp < 10 ? mp + 3 : mp - 9;
  if (m <= 2) ++y;
  return static_cast<int>(y);
}

}  // namespace sim
