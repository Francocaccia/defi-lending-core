#include "cli.hpp"

#include <cstdint>
#include <string_view>

#include "model.hpp"

namespace refmodel {

namespace {

using Words = std::vector<U256>;
using Handler = Words (*)(const Words&);

constexpr std::uint64_t kMaxDecimals = 255;  // the Solidity type is uint8

struct Spec {
  const char* name;
  std::size_t arity;
  std::vector<std::size_t> decimalsArgs;  // positions that must be <= 255
  Handler fn;
};

std::uint8_t dec(const U256& v) { return static_cast<std::uint8_t>(v.low64()); }

// clang-format off
const std::vector<Spec>& table() {
  static const std::vector<Spec> specs = {
    {"utilization", 2, {}, [](const Words& a) { return Words{utilization(a[0], a[1])}; }},
    {"validateRateParams", 4, {}, [](const Words& a) { return Words{validateRateParams(a[0], a[1], a[2], a[3])}; }},
    {"annualBorrowRate", 5, {}, [](const Words& a) { return Words{annualBorrowRate(a[0], a[1], a[2], a[3], a[4])}; }},
    {"borrowRatePerSecond", 5, {}, [](const Words& a) { return Words{borrowRatePerSecond(a[0], a[1], a[2], a[3], a[4])}; }},
    {"accrueIndex", 3, {}, [](const Words& a) { return Words{accrueIndex(a[0], a[1], a[2])}; }},
    {"scaledFromAssetsUp", 2, {}, [](const Words& a) { return Words{scaledFromAssetsUp(a[0], a[1])}; }},
    {"scaledFromAssetsDown", 2, {}, [](const Words& a) { return Words{scaledFromAssetsDown(a[0], a[1])}; }},
    {"debtFromScaled", 2, {}, [](const Words& a) { return Words{debtFromScaled(a[0], a[1])}; }},
    {"toSharesDown", 3, {}, [](const Words& a) { return Words{toSharesDown(a[0], a[1], a[2])}; }},
    {"toSharesUp", 3, {}, [](const Words& a) { return Words{toSharesUp(a[0], a[1], a[2])}; }},
    {"toAssetsDown", 3, {}, [](const Words& a) { return Words{toAssetsDown(a[0], a[1], a[2])}; }},
    {"toAssetsUp", 3, {}, [](const Words& a) { return Words{toAssetsUp(a[0], a[1], a[2])}; }},
    {"collateralValueUsd", 3, {2}, [](const Words& a) { return Words{collateralValueUsd(a[0], a[1], dec(a[2]))}; }},
    {"debtValueUsd", 3, {2}, [](const Words& a) { return Words{debtValueUsd(a[0], a[1], dec(a[2]))}; }},
    {"healthFactor", 3, {}, [](const Words& a) { return Words{healthFactor(a[0], a[1], a[2])}; }},
    {"maxDebtValue", 2, {}, [](const Words& a) { return Words{maxDebtValue(a[0], a[1])}; }},
    {"isWithinMaxLtv", 3, {}, [](const Words& a) { return Words{isWithinMaxLtv(a[0], a[1], a[2])}; }},
    {"maxRepayable", 2, {}, [](const Words& a) { return Words{maxRepayable(a[0], a[1])}; }},
    // seizeForRepay(repay, debtPriceWad, debtDecimals, collPriceWad, collDecimals, bonus)
    {"seizeForRepay", 6, {2, 4}, [](const Words& a) { return Words{seizeForRepay(a[0], a[1], dec(a[2]), a[3], dec(a[4]), a[5])}; }},
    {"repayForSeize", 6, {2, 4}, [](const Words& a) { return Words{repayForSeize(a[0], a[1], dec(a[2]), a[3], dec(a[4]), a[5])}; }},
    {"validateRiskParams", 4, {}, [](const Words& a) { return Words{validateRiskParams(a[0], a[1], a[2], a[3])}; }},
    {"accrue", 8, {}, [](const Words& a) {
        const AccrueResult r = accrue(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);
        return Words{r.newIndex, r.interest}; }},
    {"repayAmounts", 3, {}, [](const Words& a) {
        const RepayResult r = repayAmounts(a[0], a[1], a[2]);
        return Words{r.repaid, r.burned}; }},
    // liquidationAmounts(scaled, index, requested, collateral, cp, dp, cd, dd, bonus, closeFactor)
    {"liquidationAmounts", 10, {6, 7}, [](const Words& a) {
        const LiquidationResult r = liquidationAmounts(a[0], a[1], a[2], a[3], a[4], a[5], dec(a[6]), dec(a[7]), a[8], a[9]);
        return Words{r.repaid, r.seized, r.burned}; }},
    {"badDebt", 4, {}, [](const Words& a) {
        const BadDebtResult r = badDebt(a[0], a[1], a[2], a[3]);
        return Words{r.debtWrittenOff, r.loss, r.newTotalSupplyAssets}; }},
  };
  return specs;
}
// clang-format on

int usage(std::ostream& err, const std::string& reason) {
  err << "usage: " << reason << '\n';
  return 2;
}

}  // namespace

int run(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
  if (args.empty()) return usage(err, "missing function name");

  const Spec* spec = nullptr;
  for (const Spec& s : table()) {
    if (args[0] == s.name) {
      spec = &s;
      break;
    }
  }
  if (spec == nullptr) return usage(err, "unknown function '" + args[0] + "'");
  if (args.size() - 1 != spec->arity) {
    return usage(err, args[0] + " takes " + std::to_string(spec->arity) + " arguments, got " +
                          std::to_string(args.size() - 1));
  }

  // Parse and range-check EVERY argument before running the math: a usage error always wins
  // over a model failure (the caller is wrong, not the inputs).
  Words values;
  values.reserve(spec->arity);
  for (std::size_t i = 0; i < spec->arity; ++i) {
    const ParseResult p = parseU256(args[i + 1]);
    if (!p.value) return usage(err, "argument " + std::to_string(i + 1) + ": " + p.error);
    values.push_back(*p.value);
  }
  for (std::size_t idx : spec->decimalsArgs) {
    const U256& v = values[idx];
    if (v > U256(kMaxDecimals)) {
      return usage(err, "argument " + std::to_string(idx + 1) + " (decimals) must be <= 255");
    }
  }

  Words result;
  try {
    result = spec->fn(values);
  } catch (const ModelError& e) {
    err << "error: " << e.what() << '\n';
    return 1;
  }

  std::string line = "0x";
  for (const U256& w : result) line += w.toHex64();
  out << line << '\n';
  return 0;
}

}  // namespace refmodel
