# The native camera wedge: capture, zxing-cpp decode and confirmation, built
# as one shared library that the Dart side loads through FFI.
#
# Built by Flutter through windows/CMakeLists.txt, and directly for the native
# tests (see README.md):
#
#   cmake -S src -B build -DPCW_BUILD_TESTS=ON && cmake --build build
#   ctest --test-dir build --output-on-failure
cmake_minimum_required(VERSION 3.16)
project(pointy_camera_wedge LANGUAGES C CXX)

option(PCW_BUILD_TESTS "Build the native test suite" OFF)
option(PCW_SYNTHETIC_BACKEND
  "Replace the platform camera backend with drawn frames (tests only)" OFF)
option(PCW_BUILD_PROBE "Build the camera_wedge_probe console tool" OFF)

if(PCW_BUILD_TESTS)
  # The tests draw their barcodes with the synthetic backend's renderer.
  set(PCW_SYNTHETIC_BACKEND ON)
endif()

# --- zxing-cpp ---------------------------------------------------------------
# Readers only in the product. The test builds also need zxing's (old,
# dependency-free) writer to draw barcodes. Normal variables, not cache
# entries: they configure zxing's directory and nothing else in the app.
set(ZXING_READERS ON)
if(PCW_SYNTHETIC_BACKEND)
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

# --- the platform-independent core ------------------------------------------
set(PCW_CORE_SOURCES
  capture/device_selection.cpp
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

# --- the one platform-specific part: where frames come from -----------------
if(PCW_SYNTHETIC_BACKEND)
  list(APPEND PCW_CORE_SOURCES
    platform/synthetic/scene.cpp
    platform/synthetic/synthetic_backend.cpp
  )
elseif(WIN32)
  list(APPEND PCW_CORE_SOURCES
    platform/windows/mf_backend.cpp
  )
else()
  # Linux goes here: platform/linux/v4l2_backend.cpp (see README.md).
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

if(MSVC)
  # Warnings are for us to read, not for a compiler update to turn into a
  # failed release: no /WX.
  target_compile_options(pointy_camera_wedge_core PRIVATE /W4)
else()
  target_compile_options(pointy_camera_wedge_core PRIVATE -Wall -Wextra)
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

# --- tests and tools ---------------------------------------------------------
if(PCW_BUILD_TESTS)
  enable_testing()
  add_executable(pcw_tests
    test/test_main.cpp
    test/device_selection_test.cpp
    test/engine_test.cpp
    test/luma_test.cpp
    test/policy_test.cpp
    test/reader_test.cpp
    test/transform_test.cpp
    test/utf8_test.cpp
    api/utf8.cpp
  )
  target_link_libraries(pcw_tests PRIVATE pointy_camera_wedge_core)
  add_test(NAME pcw_tests COMMAND pcw_tests)
endif()

if(PCW_BUILD_PROBE)
  add_executable(camera_wedge_probe tools/camera_wedge_probe.cpp)
  target_link_libraries(camera_wedge_probe PRIVATE pointy_camera_wedge_core)
  if(MINGW)
    target_link_options(camera_wedge_probe PRIVATE -static)
  endif()
endif()
