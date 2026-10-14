// Minimal self-contained test harness (no third-party dependency).
// Why not Catch2/GoogleTest: neither is installed on the dev machine and fetching them needs a
// download; the model is a few hundred lines, so ~60 lines of harness keep the build
// dependency-free (CMake + a C++17 compiler only), which also keeps CI and review trivial.
#pragma once

#include <functional>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "uint256.hpp"

namespace testlib {

struct Case {
  const char* name;
  void (*fn)();
};
inline std::vector<Case>& registry() {
  static std::vector<Case> r;
  return r;
}
inline int& checks() {
  static int n = 0;
  return n;
}
inline int& failures() {
  static int n = 0;
  return n;
}
struct Registrar {
  Registrar(const char* name, void (*fn)()) { registry().push_back({name, fn}); }
};

template <class T>
std::string show(const T& v) {
  std::ostringstream os;
  os << v;
  return os.str();
}
inline std::string show(const refmodel::U256& v) { return v.toDecimal(); }

inline void fail(const char* file, int line, const std::string& msg) {
  ++failures();
  std::cerr << file << ":" << line << ": FAILED: " << msg << "\n";
}

template <class A, class B>
void checkEq(const A& a, const B& b, const char* ea, const char* eb, const char* file, int line) {
  ++checks();
  if (!(a == b)) {
    fail(file, line, std::string(ea) + " == " + eb + "\n    left : " + show(a) +
                         "\n    right: " + show(b));
  }
}

template <class F>
void checkThrows(F&& f, const char* expr, const char* file, int line) {
  ++checks();
  try {
    f();
  } catch (const refmodel::ModelError&) {
    return;
  }
  fail(file, line, std::string("expected ModelError from ") + expr);
}

template <class F>
void checkNoThrow(F&& f, const char* expr, const char* file, int line) {
  ++checks();
  try {
    f();
  } catch (const std::exception& e) {
    fail(file, line, std::string("unexpected exception from ") + expr + ": " + e.what());
  }
}

inline int runAll() {
  for (const Case& c : registry()) {
    const int before = failures();
    try {
      c.fn();
    } catch (const std::exception& e) {
      fail(c.name, 0, std::string("uncaught exception: ") + e.what());
    }
    std::cout << (failures() == before ? "[ ok ] " : "[FAIL] ") << c.name << "\n";
  }
  std::cout << registry().size() << " tests, " << checks() << " checks, " << failures()
            << " failures\n";
  return failures() == 0 ? 0 : 1;
}

}  // namespace testlib

#define TEST(name)                                         \
  static void name();                                      \
  static testlib::Registrar registrar_##name(#name, &name); \
  static void name()

#define CHECK(cond) testlib::checkEq(static_cast<bool>(cond), true, #cond, "true", __FILE__, __LINE__)
#define CHECK_EQ(a, b) testlib::checkEq((a), (b), #a, #b, __FILE__, __LINE__)
#define CHECK_THROWS(expr) testlib::checkThrows([&] { (void)(expr); }, #expr, __FILE__, __LINE__)
#define CHECK_NOTHROW(expr) testlib::checkNoThrow([&] { (void)(expr); }, #expr, __FILE__, __LINE__)
