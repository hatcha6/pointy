# The native camera wedge: capture, zxing-cpp decode and confirmation, built
# as one shared library that the Dart side loads through FFI.
#
# Built by Flutter through windows/CMakeLists.txt and linux/CMakeLists.txt,
# and directly for the native tests (see README.md):
#
#   cmake -S src -B build -DPCW_BUILD_TESTS=ON && cmake --build build
#   ctest --test-dir build --output-on-failure
cmake_minimum_required(VERSION 3.16)
project(pointy_camera_wedge LANGUAGES C CXX)

option(PCW_BUILD_TESTS "Build the native test suite" OFF)
option(PCW_SYNTHETIC_BACKEND
  "Replace the platform camera backend with drawn frames (tests only)" OFF)
option(PCW_BUILD_PROBE "Build the camera_wedge_probe console tool" OFF)
option(PCW_BUILD_LOOPBACK_FEED
  "Build v4l2_loopback_feed, which plays a drawn barcode into a v4l2loopback camera (Linux)" OFF)

if(PCW_BUILD_TESTS)
  # The tests draw their barcodes with the synthetic backend's renderer.
  set(PCW_SYNTHETIC_BACKEND ON)
endif()

set(PCW_LINUX_BACKEND OFF)
if(NOT PCW_SYNTHETIC_BACKEND AND UNIX AND NOT APPLE)
  set(PCW_LINUX_BACKEND ON)
endif()

# Drawing barcodes — the tests, the synthetic camera, the loopback feeder —
# needs zxing's writer and a JPEG encoder. Nothing the app ships does.
set(PCW_DRAWS_SCENES OFF)
if(PCW_SYNTHETIC_BACKEND OR PCW_BUILD_LOOPBACK_FEED)
  set(PCW_DRAWS_SCENES ON)
endif()

# --- zxing-cpp ---------------------------------------------------------------
# Readers only in the product. The test builds also need zxing's (old,
# dependency-free) writer to draw barcodes. Normal variables, not cache
# entries: they configure zxing's directory and nothing else in the app.
set(ZXING_READERS ON)
if(PCW_DRAWS_SCENES)
  set(ZXING_WRITERS OLD)
else()
  set(ZXING_WRITERS OFF)
endif()
set(ZXING_C_API OFF)
set(ZXING_ENABLE_MAXICODE OFF)
set(BUILD_SHARED_LIBS OFF)
# EXCLUDE_FROM_ALL also keeps zxing's install() rules out of the app's
# install step, which would otherwise copy a static library and its headers
# into the shipped bundle.
add_subdirectory(third_party/zxing-cpp/core zxing EXCLUDE_FROM_ALL)

set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)

# The sources are UTF-8 (comments carry the odd em dash). Without this MSVC
# reads them in the machine's legacy code page — Arabic on a Libyan till.
add_compile_options("$<$<CXX_COMPILER_ID:MSVC>:/utf-8>")

# Vendored C (stb) is compiled with its warnings off: it is not code this
# library reads, and its warnings would bury ours.
set(PCW_QUIET_VENDORED "$<IF:$<C_COMPILER_ID:MSVC>,/w,-w>")

# --- the platform-independent core ------------------------------------------
set(PCW_CORE_SOURCES
  capture/device_selection.cpp
  capture/mode_score.cpp
  capture/pixel_format.cpp
  engine/decode_scheduler.cpp
  engine/thread_util.cpp
  engine/wedge_engine.cpp
  policy/confirmation_policy.cpp
  policy/symbology.cpp
  vision/barcode_reader.cpp
  vision/luma_extract.cpp
  vision/transform.cpp
)

# MJPEG decoding. The Linux backend needs it — V4L2 delivers a webcam's MJPEG
# frames still compressed — and the synthetic camera's MJPEG recipes use it,
# so every platform's tests run it. The Windows product does not: Media
# Foundation decodes there.
if(PCW_LINUX_BACKEND OR PCW_SYNTHETIC_BACKEND)
  list(APPEND PCW_CORE_SOURCES
    capture/jpeg_decoder.cpp
    capture/stb_image_jpeg.c
  )
  set_source_files_properties(capture/stb_image_jpeg.c PROPERTIES
    COMPILE_OPTIONS "${PCW_QUIET_VENDORED}")
endif()

# --- the one platform-specific part: where frames come from -----------------
if(PCW_SYNTHETIC_BACKEND)
  list(APPEND PCW_CORE_SOURCES
    platform/synthetic/synthetic_backend.cpp
  )
elseif(WIN32)
  list(APPEND PCW_CORE_SOURCES
    platform/windows/mf_backend.cpp
  )
elseif(PCW_LINUX_BACKEND)
  list(APPEND PCW_CORE_SOURCES
    platform/linux/v4l2_backend.cpp
    platform/linux/v4l2_rules.cpp
  )
else()
  list(APPEND PCW_CORE_SOURCES
    platform/unsupported/unsupported_backend.cpp
  )
endif()

add_library(pointy_camera_wedge_core STATIC ${PCW_CORE_SOURCES})
target_include_directories(pointy_camera_wedge_core PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_compile_features(pointy_camera_wedge_core PUBLIC cxx_std_20)
target_link_libraries(pointy_camera_wedge_core PUBLIC ZXing::ZXing Threads::Threads)
set_target_properties(pointy_camera_wedge_core PROPERTIES
  POSITION_INDEPENDENT_CODE ON
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON
)

if(WIN32)
  target_compile_definitions(pointy_camera_wedge_core PUBLIC
    NOMINMAX WIN32_LEAN_AND_MEAN UNICODE _UNICODE)
  if(NOT PCW_SYNTHETIC_BACKEND)
    # Media Foundation (Windows 7 and later) and the DirectShow camera
    # control interface used to switch autofocus on.
    target_link_libraries(pointy_camera_wedge_core PUBLIC
      mfplat mf mfreadwrite mfuuid ole32 strmiids)
  endif()
endif()

# Warnings are for us to read, not for a compiler update to turn into a failed
# release: no /WX, no -Werror. C++ only, so the vendored C above stays quiet.
if(MSVC)
  target_compile_options(pointy_camera_wedge_core PRIVATE
    "$<$<COMPILE_LANGUAGE:CXX>:/W4>")
else()
  target_compile_options(pointy_camera_wedge_core PRIVATE
    "$<$<COMPILE_LANGUAGE:CXX>:-Wall;-Wextra>")
endif()

# --- drawn scenes (test builds and tools only) ------------------------------
if(PCW_DRAWS_SCENES)
  add_library(pointy_camera_wedge_scenes STATIC
    platform/synthetic/jpeg_writer.cpp
    platform/synthetic/scene.cpp
    platform/synthetic/stb_image_write_impl.c
  )
  # stb_image_write's JPEG bit writer shifts a signed int left past its top
  # (it only ever reads bits 16-23 back), which UBSan rightly calls
  # undefined. It only draws test frames, so the sanitizer builds skip that
  # one check here; the decoder the product runs is checked in full.
  set_source_files_properties(platform/synthetic/stb_image_write_impl.c PROPERTIES
    COMPILE_OPTIONS "${PCW_QUIET_VENDORED};$<$<NOT:$<C_COMPILER_ID:MSVC>>:-fno-sanitize=shift>")
  target_include_directories(pointy_camera_wedge_scenes PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}"
  )
  target_compile_features(pointy_camera_wedge_scenes PUBLIC cxx_std_20)
  target_link_libraries(pointy_camera_wedge_scenes PUBLIC ZXing::ZXing)
  set_target_properties(pointy_camera_wedge_scenes PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    C_VISIBILITY_PRESET hidden
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
  )
  if(PCW_SYNTHETIC_BACKEND)
    target_link_libraries(pointy_camera_wedge_core PUBLIC pointy_camera_wedge_scenes)
  endif()
endif()

# --- the shared library Dart loads ------------------------------------------
add_library(pointy_camera_wedge SHARED
  api/api.cpp
  api/dart_port_sink.cpp
  api/utf8.cpp
  third_party/dart_api/dart_api_dl.c
)
target_compile_definitions(pointy_camera_wedge PRIVATE PCW_BUILDING_LIBRARY)
target_include_directories(pointy_camera_wedge PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party/dart_api"
)
target_link_libraries(pointy_camera_wedge PRIVATE pointy_camera_wedge_core)
set_target_properties(pointy_camera_wedge PROPERTIES
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON
  OUTPUT_NAME pointy_camera_wedge
)
if(WIN32)
  # pointy_camera_wedge.dll with every toolchain (MinGW would add "lib").
  set_target_properties(pointy_camera_wedge PROPERTIES PREFIX "")
endif()
if(MINGW)
  # A MinGW build (the probe, cross-compiled checks) should not need the
  # MinGW runtime DLLs next to it.
  target_link_options(pointy_camera_wedge PRIVATE -static)
endif()

# Linux: one library that loads on every distro the app supports, whatever
# it was built on (releases build on Ubuntu 24.04; Mint 21 is 22.04).
#  * libstdc++ is linked in. One from a newer GCC adds symbol versions an
#    older till's libstdc++.so.6 lacks, and the library would not load at
#    all. Safe because nothing C++ crosses the C ABI. (libgcc_s stays
#    shared: its symbols have not changed since GCC 4.)
#  * api/glibc_compat.c keeps out the glibc symbols a new build machine
#    compiles in unasked (C23 strtol, arc4random).
#  * Only pcw_* is exported (api/exports.map).
# CI checks the outcome (.github/workflows/camera-wedge.yml).
set(PCW_LINUX_PORTABLE OFF)
if(UNIX AND NOT APPLE)
  set(PCW_LINUX_PORTABLE ON)
  target_sources(pointy_camera_wedge PRIVATE api/glibc_compat.c)
  target_link_options(pointy_camera_wedge PRIVATE
    -static-libstdc++
    "LINKER:--version-script=${CMAKE_CURRENT_SOURCE_DIR}/api/exports.map")
  set_target_properties(pointy_camera_wedge PROPERTIES
    LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/api/exports.map")
endif()

# --- tests and tools ---------------------------------------------------------
if(PCW_BUILD_TESTS)
  enable_testing()
  add_executable(pcw_tests
    test/test_main.cpp
    test/device_selection_test.cpp
    test/engine_test.cpp
    test/jpeg_test.cpp
    test/luma_test.cpp
    test/mode_score_test.cpp
    test/policy_test.cpp
    test/reader_test.cpp
    test/transform_test.cpp
    test/utf8_test.cpp
    test/v4l2_rules_test.cpp
    api/utf8.cpp
    # The V4L2 backend's decisions have no Linux dependency, so they are
    # tested wherever the tests run.
    platform/linux/v4l2_rules.cpp
  )
  target_link_libraries(pcw_tests PRIVATE pointy_camera_wedge_core)
  target_compile_definitions(pcw_tests PRIVATE
    PCW_TEST_DATA_DIR="${CMAKE_CURRENT_SOURCE_DIR}/test/data")
  add_test(NAME pcw_tests COMMAND pcw_tests)
endif()

if(PCW_BUILD_PROBE)
  add_executable(camera_wedge_probe tools/camera_wedge_probe.cpp)
  target_link_libraries(camera_wedge_probe PRIVATE pointy_camera_wedge_core)
  if(MINGW)
    target_link_options(camera_wedge_probe PRIVATE -static)
  endif()
  if(PCW_LINUX_PORTABLE)
    # Copied onto a till for a support call, so as portable as the library.
    target_sources(camera_wedge_probe PRIVATE api/glibc_compat.c)
    target_link_options(camera_wedge_probe PRIVATE -static-libstdc++)
  endif()
endif()

if(PCW_BUILD_LOOPBACK_FEED)
  if(NOT (UNIX AND NOT APPLE))
    message(FATAL_ERROR "v4l2_loopback_feed writes to a Linux v4l2loopback device")
  endif()
  add_executable(v4l2_loopback_feed tools/v4l2_loopback_feed.cpp)
  target_link_libraries(v4l2_loopback_feed PRIVATE pointy_camera_wedge_scenes)
endif()
