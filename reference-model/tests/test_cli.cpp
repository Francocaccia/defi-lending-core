// The command-line contract (docs/M8_HANDOFF.md section 2), exercised in-process through
// refmodel::run. The compiled binary itself is exercised by the cli_* CTest entries.
#include <sstream>

#include "cli.hpp"
#include "testlib.hpp"

using namespace refmodel;

namespace {
struct Out {
  int code;
  std::string out, err;
};
Out call(std::vector<std::string> args) {
  std::ostringstream o, e;
  const int code = run(args, o, e);
  return {code, o.str(), e.str()};
}
const char* kWord1 = "0x0000000000000000000000000000000000000000000000000000000000000001";
}  // namespace

TEST(cli_success_output_format) {
  Out r = call({"utilization", "3", "1"});
  CHECK_EQ(r.code, 0);
  CHECK_EQ(r.out, std::string("0x00000000000000000000000000000000000000000000000004a03ce68d215555\n"));
  CHECK_EQ(r.err, std::string());
  // multi-value functions: words concatenated on ONE line
  r = call({"repayAmounts", "20", "10", "2000000000000000000000000000"});
  CHECK_EQ(r.code, 0);
  CHECK_EQ(r.out.size(), std::size_t(2 + 128 + 1));
  CHECK_EQ(r.out.substr(0, 2), std::string("0x"));
  CHECK_EQ(r.out.back(), '\n');
  CHECK_EQ(r.out.find('\n'), r.out.size() - 1);
  r = call({"badDebt", "100", "100", "1000000000000000000000000000", "1000"});
  CHECK_EQ(r.code, 0);
  CHECK_EQ(r.out.size(), std::size_t(2 + 192 + 1));
}

TEST(cli_hex_and_decimal_arguments_agree) {
  const Out dec = call({"utilization", "123", "7"});
  const Out hex = call({"utilization", "0x7b", "0x7"});
  const Out hexUpper = call({"utilization", "0X7B", "0X7"});
  CHECK_EQ(dec.code, 0);
  CHECK_EQ(dec.out, hex.out);
  CHECK_EQ(dec.out, hexUpper.out);
  const Out mixed = call({"utilization", "0x7B", "7"});
  CHECK_EQ(mixed.out, dec.out);
}

TEST(cli_exit1_on_model_failure) {
  Out r = call({"annualBorrowRate", "0", "0", "0", "0", "0"});  // optimal = 0 -> division by zero
  CHECK_EQ(r.code, 1);
  CHECK_EQ(r.out, std::string());
  CHECK(r.err.rfind("error: ", 0) == 0);
  CHECK_EQ(r.err.back(), '\n');
  r = call({"validateRiskParams", "0", "0", "0", "0"});
  CHECK_EQ(r.code, 1);
  CHECK_EQ(r.out, std::string());
}

TEST(cli_exit2_on_usage_errors) {
  const std::vector<std::vector<std::string>> bad = {
      {},                                         // no function
      {"nope", "1"},                              // unknown function
      {"Utilization", "1", "2"},                  // case-sensitive
      {"utilization"},                            // too few
      {"utilization", "1"},                       // too few
      {"utilization", "1", "2", "3"},             // too many
      {"utilization", "", "2"},                   // empty argument
      {"utilization", "-1", "2"},                 // sign
      {"utilization", "+1", "2"},
      {"utilization", " 1", "2"},                 // whitespace
      {"utilization", "1 ", "2"},
      {"utilization", "1_000", "2"},              // underscore
      {"utilization", "1.5", "2"},
      {"utilization", "abc", "2"},
      {"utilization", "0x", "2"},                 // no hex digits
      {"utilization", "0xzz", "2"},
      {"utilization",
       "115792089237316195423570985008687907853269984665640564039457584007913129639936", "2"},  // 2^256
      {"utilization", "0x10000000000000000000000000000000000000000000000000000000000000000", "2"},
      {"collateralValueUsd", "1", "1", "256"},    // decimals > 255
      {"debtValueUsd", "1", "1", "0x100"},
      {"seizeForRepay", "1", "1", "256", "1", "18", "0"},
      {"seizeForRepay", "1", "1", "6", "1", "256", "0"},
      {"repayForSeize", "1", "1", "256", "1", "18", "0"},
      {"liquidationAmounts", "1", "1", "1", "1", "1", "1", "256", "6", "0", "0"},
      {"liquidationAmounts", "1", "1", "1", "1", "1", "1", "18", "256", "0", "0"},
  };
  for (const auto& args : bad) {
    const Out r = call(args);
    CHECK_EQ(r.code, 2);
    CHECK_EQ(r.out, std::string());
    CHECK(r.err.rfind("usage: ", 0) == 0);
  }
}

TEST(cli_usage_error_wins_over_model_failure) {
  // Would fail in the model (optimal = 0) but the last argument is unparsable: exit 2, not 1.
  CHECK_EQ(call({"annualBorrowRate", "0", "0", "0", "0", "x"}).code, 2);
  // decimals 255 is accepted by the CLI and then fails in the model (10**255): exit 1, not 2.
  CHECK_EQ(call({"collateralValueUsd", "1", "1", "255"}).code, 1);
  CHECK_EQ(call({"collateralValueUsd", "1", "1", "78"}).code, 1);
  CHECK_EQ(call({"collateralValueUsd", "1", "1", "77"}).code, 0);
}

TEST(cli_boundary_values) {
  const std::string max =
      "115792089237316195423570985008687907853269984665640564039457584007913129639935";
  const std::string maxHex = "0x" + std::string(64, 'f');
  Out a = call({"utilization", max, max});
  Out b = call({"utilization", maxHex, maxHex});
  CHECK_EQ(a.code, 0);
  CHECK_EQ(a.out, b.out);
  // result of 2^256 - 1 is printed as 64 f's
  a = call({"healthFactor", "0", "0", "0"});
  CHECK_EQ(a.out, "0x" + std::string(64, 'f') + "\n");
  CHECK_EQ(call({"isWithinMaxLtv", "100", "75", "750000000000000000"}).out, std::string(kWord1) + "\n");
  CHECK_EQ(call({"validateRateParams", "0", "40000000000000000", "750000000000000000",
                 "800000000000000000"}).out,
           std::string(kWord1) + "\n");
}

TEST(cli_every_function_is_reachable_with_correct_arity) {
  // Each function with the right number of zero arguments must NOT be a usage error.
  const std::pair<const char*, int> fns[] = {
      {"utilization", 2},         {"validateRateParams", 4}, {"annualBorrowRate", 5},
      {"borrowRatePerSecond", 5}, {"accrueIndex", 3},        {"scaledFromAssetsUp", 2},
      {"scaledFromAssetsDown", 2}, {"debtFromScaled", 2},     {"toSharesDown", 3},
      {"toSharesUp", 3},          {"toAssetsDown", 3},       {"toAssetsUp", 3},
      {"collateralValueUsd", 3},  {"debtValueUsd", 3},       {"healthFactor", 3},
      {"maxDebtValue", 2},        {"isWithinMaxLtv", 3},     {"maxRepayable", 2},
      {"seizeForRepay", 6},       {"repayForSeize", 6},      {"validateRiskParams", 4},
      {"accrue", 8},              {"repayAmounts", 3},       {"liquidationAmounts", 10},
      {"badDebt", 4},
  };
  CHECK_EQ(sizeof(fns) / sizeof(fns[0]), std::size_t(25));
  for (const auto& f : fns) {
    std::vector<std::string> ok{f.first}, tooMany{f.first};
    for (int i = 0; i < f.second; ++i) ok.push_back("1");
    tooMany = ok;
    tooMany.push_back("1");
    CHECK(call(ok).code != 2);
    CHECK_EQ(call(tooMany).code, 2);
    ok.pop_back();
    CHECK_EQ(call(ok).code, 2);
  }
}
