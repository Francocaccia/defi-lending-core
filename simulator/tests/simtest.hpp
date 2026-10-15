// Simulator test helpers on top of the reference model's tiny harness (testlib.hpp).
#pragma once

#include <cmath>
#include <exception>
#include <string>

#include "testlib.hpp"

namespace simtest {

template <class F>
void checkThrowsAny(F&& f, const char* expr, const char* file, int line) {
  ++testlib::checks();
  try {
    f();
  } catch (const std::exception&) {
    return;
  }
  testlib::fail(file, line, std::string("expected an exception from ") + expr);
}

inline void checkNear(double a, double b, double tol, const char* ea, const char* eb,
                      const char* file, int line) {
  ++testlib::checks();
  if (!(std::fabs(a - b) <= tol)) {
    testlib::fail(file, line,
                  std::string(ea) + " ~= " + eb + " (tol " + std::to_string(tol) +
                      ")\n    left : " + std::to_string(a) + "\n    right: " + std::to_string(b));
  }
}

}  // namespace simtest

#define CHECK_THROWS_ANY(expr) simtest::checkThrowsAny([&] { (void)(expr); }, #expr, __FILE__, __LINE__)
#define CHECK_NEAR(a, b, tol) simtest::checkNear((a), (b), (tol), #a, #b, __FILE__, __LINE__)
