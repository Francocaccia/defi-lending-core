// Exact decimal <-> fixed-point helpers (no floating point is ever used to parse a parameter).
#pragma once

#include <cstdint>
#include <string>

#include "uint256.hpp"

namespace sim {

using refmodel::U256;

/// "0.75" with 18 decimals -> 0.75e18; "10" -> 10e18. Digits beyond `decimals` are an error
/// (never silently truncated). Throws std::invalid_argument on malformed text.
U256 parseDecimalScaled(const std::string& text, unsigned decimals);

/// Protocol-parameter convention: text containing '.' is a decimal FRACTION ("0.75" = 75%);
/// plain digits are a RAW WAD integer exactly as it would be passed to the contract
/// ("750000000000000000" = 75%).
U256 parseWadParam(const std::string& text);

/// Plain decimal integer (digits only).
U256 parseUint(const std::string& text);

/// Lossy conversion for statistics / screening only. NEVER used for a protocol decision.
double toDouble(const U256& v);

/// Fixed-point to text with `shown` fractional digits (truncated), e.g. (1.5e18, 18, 4) -> "1.5000".
std::string formatScaled(const U256& v, unsigned decimals, unsigned shown);

/// UTC civil year of a unix timestamp (proleptic Gregorian).
int yearOf(std::int64_t unixSeconds);

}  // namespace sim
