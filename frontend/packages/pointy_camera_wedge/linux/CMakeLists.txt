# Flutter's Linux build of the plugin: the native library itself is
# described once, in ../src/CMakeLists.txt, for every platform.
#
# The Flutter tooling requires only CMake 3.10 here; ../src asks for 3.16,
# which Ubuntu 20.04 and every later distro ships.
cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "pointy_camera_wedge")
project(${PROJECT_NAME} LANGUAGES C CXX)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

# Installed into the bundle's lib/ by the app's install step, where
# DynamicLibrary.open('libpointy_camera_wedge.so') finds it.
set(pointy_camera_wedge_bundled_libraries
  $<TARGET_FILE:pointy_camera_wedge>
  PARENT_SCOPE
)
