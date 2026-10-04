/*
 * Lets the Linux library, built on a new distro, load on an older one.
 *
 * Releases are built on Ubuntu 24.04 (glibc 2.39); Mint 21 tills run Ubuntu
 * 22.04's glibc 2.35. A library that references even one symbol newer than
 * the till's glibc does not load at all, and the till quietly loses its
 * camera. Two kinds of reference get compiled in on a new build machine
 * without any code asking for them:
 *
 *  * glibc 2.38 compiles calls to strtol and its relatives as calls to
 *    __isoc23_strtol (and so on) whenever _GNU_SOURCE is on, which in C++ is
 *    always, because C23 taught them to read "0b101". zxing-cpp and the C++
 *    runtime linked into this library both call them. Nothing here parses a
 *    binary literal, so for every call made the C23 functions and the
 *    originals behave identically: these forward to the originals.
 *  * The C++ runtime's std::random_device draws from arc4random (glibc 2.36),
 *    and is linked in behind the standard exception classes even though
 *    nothing here constructs one. This draws from getentropy (glibc 2.25).
 *
 * Every definition is hidden and the version script (exports.map) exports
 * nothing but pcw_*, so they replace nothing outside this library. CI fails
 * when the library needs a glibc newer than 22.04's
 * (.github/workflows/camera-wedge.yml).
 */
#if defined(__linux__)
#include <features.h> /* __GLIBC__ and __GLIBC_PREREQ */
#endif

#if defined(__GLIBC__)
#include <stddef.h>

#define PCW_HIDDEN __attribute__((visibility("hidden")))

#if __GLIBC_PREREQ(2, 36)
/* The original, named by symbol so no header can redirect it. */
extern int pcw_getentropy(void* buffer, size_t length) __asm__("getentropy");

PCW_HIDDEN unsigned int arc4random(void) {
  unsigned int value = 0;
  /* getentropy cannot fail for four bytes on any kernel since 3.17. */
  (void)pcw_getentropy(&value, sizeof(value));
  return value;
}
#endif

#if __GLIBC_PREREQ(2, 38)
extern long pcw_strtol(const char*, char**, int) __asm__("strtol");
extern unsigned long pcw_strtoul(const char*, char**, int) __asm__("strtoul");
extern long long pcw_strtoll(const char*, char**, int) __asm__("strtoll");
extern unsigned long long pcw_strtoull(const char*, char**, int) __asm__("strtoull");

PCW_HIDDEN long __isoc23_strtol(const char* text, char** end, int base) {
  return pcw_strtol(text, end, base);
}
PCW_HIDDEN unsigned long __isoc23_strtoul(const char* text, char** end, int base) {
  return pcw_strtoul(text, end, base);
}
PCW_HIDDEN long long __isoc23_strtoll(const char* text, char** end, int base) {
  return pcw_strtoll(text, end, base);
}
PCW_HIDDEN unsigned long long __isoc23_strtoull(const char* text, char** end, int base) {
  return pcw_strtoull(text, end, base);
}
#endif

#endif /* __GLIBC__ */
