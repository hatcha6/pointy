#include "engine/thread_util.h"

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#elif defined(__linux__)
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <cerrno>
#endif

namespace pcw {

void LowerCurrentThreadPriority() {
#if defined(_WIN32)
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
#elif defined(__linux__)
  // Linux keeps a nice value per thread (where POSIX says per process), so
  // this lowers the calling thread alone. The scheduler has no strict
  // priorities for ordinary threads, only weights: at nice 10 a thread gets
  // about a tenth of what a nice-0 thread gets on a contested core, which is
  // the nearest thing to Windows' below-normal — the till wins whenever it
  // wants the core, and the wedge has it whenever it does not. Raising a nice
  // value needs no privilege.
  const auto thread = static_cast<id_t>(::syscall(SYS_gettid));
  errno = 0;
  const int current = ::getpriority(PRIO_PROCESS, thread);
  if (errno == 0 && current < 10) ::setpriority(PRIO_PROCESS, thread, 10);
#else
  // macOS runs only the test builds; nothing to protect there.
#endif
}

}  // namespace pcw
