#include <chrono>
#include <cstring>
#include <exception>
#include <iostream>

#include "test/check.h"

namespace pcwtest {

std::vector<TestCase>& Registry() {
  static std::vector<TestCase> tests;
  return tests;
}

}  // namespace pcwtest

// Runs every test, or only those whose name contains argv[1].
int main(int argc, char** argv) {
  const char* filter = argc > 1 ? argv[1] : nullptr;
  int passed = 0;
  int failed = 0;
  for (const auto& test : pcwtest::Registry()) {
    if (filter != nullptr && std::strstr(test.name, filter) == nullptr) continue;
    const auto started = std::chrono::steady_clock::now();
    try {
      test.body();
      ++passed;
      const auto ms = std::chrono::duration<double, std::milli>(
                          std::chrono::steady_clock::now() - started)
                          .count();
      std::cout << "[ PASS ] " << test.name << " (" << ms << " ms)\n";
    } catch (const std::exception& error) {
      ++failed;
      std::cout << "[ FAIL ] " << test.name << "\n    " << error.what() << "\n";
    }
  }
  std::cout << passed << " passed, " << failed << " failed\n";
  return failed == 0 && passed > 0 ? 0 : 1;
}
