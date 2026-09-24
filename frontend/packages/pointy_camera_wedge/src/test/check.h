// A deliberately tiny test harness: the native tests must build anywhere the
// library builds (MSVC, clang, MinGW) with nothing fetched.
#pragma once

#include <functional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace pcwtest {

struct TestCase {
  const char* name;
  std::function<void()> body;
};

std::vector<TestCase>& Registry();

struct Registrar {
  Registrar(const char* name, std::function<void()> body) {
    Registry().push_back({name, std::move(body)});
  }
};

struct Failure : std::runtime_error {
  using std::runtime_error::runtime_error;
};

[[noreturn]] inline void Fail(const char* file, int line, const std::string& what) {
  std::ostringstream message;
  message << file << ":" << line << ": " << what;
  throw Failure(message.str());
}

}  // namespace pcwtest

#define PCW_TEST(name)                                              \
  static void name();                                               \
  static ::pcwtest::Registrar name##_registrar(#name, &name);       \
  static void name()

#define CHECK(condition)                                            \
  do {                                                              \
    if (!(condition)) {                                             \
      ::pcwtest::Fail(__FILE__, __LINE__, "CHECK(" #condition ")"); \
    }                                                               \
  } while (0)

#define CHECK_EQ(actual, expected)                                         \
  do {                                                                     \
    const auto& pcw_actual = (actual);                                     \
    const auto& pcw_expected = (expected);                                 \
    if (!(pcw_actual == pcw_expected)) {                                   \
      std::ostringstream pcw_message;                                      \
      pcw_message << "CHECK_EQ(" #actual ", " #expected "): got "          \
                  << pcw_actual << ", expected " << pcw_expected;          \
      ::pcwtest::Fail(__FILE__, __LINE__, pcw_message.str());              \
    }                                                                      \
  } while (0)
