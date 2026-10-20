# The FHSE library Dart opens (lib/src/fhse_native.dart), built from ../src as
# on every other platform. Flutter copies what `wallet_fhse_bundled_libraries`
# names next to the app.
#
# Built with MSVC: ../src/CMakeLists.txt has the Windows settings.
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "wallet_fhse")
project(${PROJECT_NAME} LANGUAGES C)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

set(wallet_fhse_bundled_libraries
  $<TARGET_FILE:wallet_fhse>
  PARENT_SCOPE
)
