// Loads test/differential/vectors.txt (the shared spec vectors, produced by a SEPARATE
// implementation of DESIGN section 9) and runs every line through the real CLI entry point,
// first with decimal arguments, then again with the same arguments rewritten as 0x-hex.
#include <fstream>
#include <sstream>

#include "cli.hpp"
#include "testlib.hpp"

#ifndef VECTORS_FILE
#error "VECTORS_FILE must be defined by CMake"
#endif

using namespace refmodel;

namespace {

std::vector<std::string> split(const std::string& line) {
  std::vector<std::string> out;
  std::istringstream is(line);
  std::string t;
  while (is >> t) out.push_back(t);
  return out;
}

std::string toHexArg(const std::string& dec) {
  const auto p = parseU256(dec);
  std::string h = p.value->toHex64();
  const std::size_t nz = h.find_first_not_of('0');
  return "0x" + (nz == std::string::npos ? std::string("0") : h.substr(nz));
}

}  // namespace

TEST(all_shared_vectors) {
  std::ifstream f(VECTORS_FILE);
  CHECK(f.good());
  std::string line;
  int n = 0, fails = 0;
  int lineNo = 0;
  while (std::getline(f, line)) {
    ++lineNo;
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty() || line[0] == '#') continue;
    const std::vector<std::string> tok = split(line);
    std::size_t sep = 0;
    while (sep < tok.size() && tok[sep] != "=>") ++sep;
    CHECK(sep > 0 && sep < tok.size() - 1);
    if (sep == 0 || sep + 1 >= tok.size()) continue;

    const std::string name = tok[0].substr(0, tok[0].find('('));
    const bool expectFail = tok[sep + 1] == "FAIL";
    std::string expected = "0x";
    if (!expectFail) {
      for (std::size_t i = sep + 1; i < tok.size(); ++i)
        expected += parseU256(tok[i]).value->toHex64();
      expected += "\n";
    }

    for (int variant = 0; variant < 2; ++variant) {  // 0 = decimal args, 1 = hex args
      std::vector<std::string> args{name};
      for (std::size_t i = 1; i < sep; ++i) args.push_back(variant == 0 ? tok[i] : toHexArg(tok[i]));
      std::ostringstream o, e;
      const int code = run(args, o, e);
      ++n;
      const bool good = expectFail ? (code == 1 && o.str().empty()) : (code == 0 && o.str() == expected);
      if (!good) {
        ++fails;
        testlib::fail(VECTORS_FILE, lineNo,
                      "vector mismatch (" + std::string(variant ? "hex" : "dec") + "): " + line +
                          "\n    got exit " + std::to_string(code) + " out=" + o.str() +
                          " err=" + e.str());
      }
    }
  }
  std::cout << "    vectors run (decimal + hex variants): " << n << ", mismatches: " << fails
            << "\n";
  CHECK(n >= 2 * 1000);  // the file really was loaded (it has ~1,100 vectors)
}
