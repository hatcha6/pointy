# Flutter's Windows build of the plugin: the native library itself is
# described once, in ../src/CMakeLists.txt, for every platform.
#
# The Flutter tooling requires only CMake 3.14 here; ../src asks for 3.16,
# which every Visual Studio that can build Flutter ships.
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "pointy_camera_wedge")
project(${PROJECT_NAME} LANGUAGES C CXX)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

# Copied next to the app's executable by the app's install step, where
# DynamicLibrary.open('pointy_camera_wedge.dll') finds it.
set(pointy_camera_wedge_bundled_libraries
  $<TARGET_FILE:pointy_camera_wedge>
  PARENT_SCOPE
)
