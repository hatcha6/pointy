#include "engine/thread_util.h"

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace pcw {

void LowerCurrentThreadPriority() {
#if defined(_WIN32)
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
#else
  // POSIX threads share the process's scheduling class unless the process
  // has privileges to change it; a per-thread nice value is Linux-only and
  // belongs with the Linux backend when it lands.
#endif
}

}  // namespace pcw
