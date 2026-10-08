# Builds libwallet_fhse: FHSE, libcbor and libsodium from the vendored sources,
# behind the small interface in wfhse.h.
#
# Used by the Android plugin (android/build.gradle) and for host builds that
# the Dart tests load (test/README.md). iOS compiles the same sources through
# CocoaPods instead; see ios/wallet_fhse.podspec, which repeats the Apple
# definitions below (minus the two the iOS SDK lacks) and must be kept in step
# with them.

cmake_minimum_required(VERSION 3.10)
project(wallet_fhse LANGUAGES C)

set(VENDOR "${CMAKE_CURRENT_SOURCE_DIR}/vendor")
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_VISIBILITY_PRESET hidden)

# ----- libsodium -----
#
# Every source file, as libsodium's own build.zig compiles it. The optimised
# variants (SSE, AVX, ARM crypto, x86-64 assembly) are guarded by HAVE_*
# macros that are left undefined here, so they compile to nothing and the
# portable reference code is used; FHSE's hashing is far too small for that
# to matter. The defines are build.zig's Linux and macOS sets.

file(GLOB_RECURSE SODIUM_SOURCES CONFIGURE_DEPENDS "${VENDOR}/libsodium/src/libsodium/*.c")
add_library(wfhse_sodium STATIC ${SODIUM_SOURCES})
target_include_directories(wfhse_sodium
  PUBLIC "${VENDOR}/libsodium/src/libsodium/include"
  PRIVATE "${VENDOR}/libsodium/src/libsodium/include/sodium")
target_compile_definitions(wfhse_sodium
  PUBLIC SODIUM_STATIC=1
  PRIVATE
    CONFIGURED=1
    HAVE_ATOMIC_OPS=1
    HAVE_C11_MEMORY_FENCES=1
    HAVE_GCC_MEMORY_FENCES=1
    HAVE_INTTYPES_H=1
    HAVE_STDINT_H=1
    NATIVE_LITTLE_ENDIAN=1
    TLS=_Thread_local
    HAVE_CLOCK_GETTIME=1
    HAVE_GETPID=1
    HAVE_MADVISE=1
    HAVE_MLOCK=1
    HAVE_MMAP=1
    HAVE_MPROTECT=1
    HAVE_NANOSLEEP=1
    HAVE_POSIX_MEMALIGN=1
    HAVE_PTHREAD=1
    HAVE_RAISE=1
    HAVE_SYSCONF=1
    HAVE_SYS_MMAN_H=1
    HAVE_SYS_PARAM_H=1
    HAVE_SYS_RANDOM_H=1
    HAVE_WEAK_SYMBOLS=1)
if(CMAKE_SIZEOF_VOID_P EQUAL 8)
  # 128-bit integers; absent on 32-bit ARM (armeabi-v7a).
  target_compile_definitions(wfhse_sodium PRIVATE HAVE_TI_MODE=1)
endif()
if(APPLE)
  target_compile_definitions(wfhse_sodium PRIVATE
    HAVE_ARC4RANDOM=1 HAVE_ARC4RANDOM_BUF=1 HAVE_GETENTROPY=1 HAVE_MEMSET_S=1)
else()
  target_compile_definitions(wfhse_sodium PRIVATE _GNU_SOURCE=1 HAVE_SYS_AUXV_H=1)
endif()
target_compile_options(wfhse_sodium PRIVATE
  -fno-strict-aliasing -fno-strict-overflow -fwrapv -w)

# ----- libcbor 0.13.0 -----

file(GLOB CBOR_SOURCES CONFIGURE_DEPENDS
  "${VENDOR}/libcbor/src/*.c"
  "${VENDOR}/libcbor/src/cbor/*.c"
  "${VENDOR}/libcbor/src/cbor/internal/*.c")
add_library(wfhse_cbor STATIC ${CBOR_SOURCES})
target_include_directories(wfhse_cbor PUBLIC "${VENDOR}/libcbor/src")
set_target_properties(wfhse_cbor PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF)
target_compile_options(wfhse_cbor PRIVATE -w)

# ----- FHSE -----

file(GLOB FHSE_SOURCES CONFIGURE_DEPENDS
  "${VENDOR}/fhse/src/public/*.c"
  "${VENDOR}/fhse/src/private/*.c")
add_library(wfhse_fhse STATIC ${FHSE_SOURCES})
target_include_directories(wfhse_fhse
  PUBLIC "${VENDOR}/fhse/include"
  PRIVATE "${VENDOR}/fhse/src")
# libsodium backend; no FHSE_LIBFIDO2: the platform's own FIDO2 stack talks to
# the key and hands FHSE the hmac-secret.
target_compile_definitions(wfhse_fhse PUBLIC FHSE_LIBSODIUM=1)
target_link_libraries(wfhse_fhse PUBLIC wfhse_cbor wfhse_sodium)
set_target_properties(wfhse_fhse PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON)

# ----- the library Dart opens -----

add_library(wallet_fhse SHARED wfhse.c)
target_link_libraries(wallet_fhse PRIVATE wfhse_fhse)
set_target_properties(wallet_fhse PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON)
if(ANDROID)
  # 16 KB pages, required for apps targeting Android 15 and later.
  target_link_options(wallet_fhse PRIVATE "-Wl,-z,max-page-size=16384")
endif()
