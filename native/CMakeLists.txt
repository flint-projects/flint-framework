cmake_minimum_required(VERSION 3.20)
project(flint_ffi_framework C)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
# The engines' Flint C shims (plan section 7). Each engine keeps its shim sources beside its package, in
# native/ffi: packages/engine-<name>/native/ffi in the monorepo, engine/<name>/native/ffi in flint-framework, where
# this directory is native/. They build into flint_ffi_framework, which framework and portfolio packages link before
# the flint repo's flint_ffi_base (native/ffi in the flint repo). tools/native_build.py builds that project first and
# installs it into the same prefix, so this one finds flint_ffi_base there.
file(GLOB FLINT_ENGINE_DIRS LIST_DIRECTORIES true
  "${CMAKE_CURRENT_SOURCE_DIR}/../../packages/engine-*/native/ffi"
  "${CMAKE_CURRENT_SOURCE_DIR}/../engine/*/native/ffi")
list(SORT FLINT_ENGINE_DIRS)
set(FLINT_FFI_FRAMEWORK_SHIMS)
foreach(dir IN LISTS FLINT_ENGINE_DIRS)
  file(GLOB shims CONFIGURE_DEPENDS "${dir}/flint_*.c")
  list(APPEND FLINT_FFI_FRAMEWORK_SHIMS ${shims})
endforeach()
if(NOT FLINT_FFI_FRAMEWORK_SHIMS)
  message(FATAL_ERROR "no engine shims under ../../packages/engine-*/native/ffi or ../engine/*/native/ffi")
endif()
# The engine directory that holds `name`, or "" when no engine ships it.
function(flint_engine_file name out)
  foreach(dir IN LISTS FLINT_ENGINE_DIRS)
    if(EXISTS "${dir}/${name}")
      set(${out} "${dir}/${name}" PARENT_SCOPE)
      return()
    endif()
  endforeach()
  set(${out} "" PARENT_SCOPE)
endfunction()
add_library(flint_ffi_framework STATIC ${FLINT_FFI_FRAMEWORK_SHIMS})
target_include_directories(flint_ffi_framework PRIVATE ${FLINT_ENGINE_DIRS} "${CMAKE_CURRENT_SOURCE_DIR}/include")
set(flint_ffi flint_ffi_framework)
target_include_directories(${flint_ffi} PRIVATE "${CMAKE_INSTALL_PREFIX}/include")
# One section per function and object, so a linked program keeps only the shim entry points it reaches
# (and the providers behind them) rather than every function that shares a translation unit with one.
if(NOT MSVC)
  target_compile_options(${flint_ffi} PRIVATE -ffunction-sections -fdata-sections)
else()
  # MSVC: C11 atomics are opt-in, and /Gy is its per-function sectioning. Flint's own C builds with level-4 warnings as
  # errors and the MSVC hardening set: Control Flow Guard, buffer security checks and the SDL checks (ADR-026).
  # C4200 flags C99 flexible array members, which are standard C.
  target_compile_options(${flint_ffi} PRIVATE /experimental:c11atomics /Gy /W4 /WX /guard:cf /GS /sdl /wd4200)
  # _NO_CRT_STDIO_INLINE: the UCRT headers otherwise define snprintf, vsnprintf and their helpers as external
  # inline COMDATs in every shim that prints. druntime references snprintf too, and link.exe would then load
  # whichever shim object it meets first, with that shim's provider, into a program that never calls it
  # (engine-wasi pulled in libpq and SQLite). With it, those calls bind to legacy_stdio_definitions.lib (ADR-026).
  target_compile_definitions(${flint_ffi} PRIVATE _NO_CRT_STDIO_INLINE)
endif()
# The providers are static archives. Their Windows headers declare DLL imports unless told otherwise.
if(WIN32)
  target_compile_definitions(${flint_ffi} PRIVATE UTF8PROC_STATIC CURL_STATICLIB NGHTTP2_STATICLIB YAML_DECLARE_STATIC
    LIBARCHIVE_STATIC SODIUM_STATIC LIBRDKAFKA_STATICLIB)
endif()
# The shims request POSIX.1-2008, which hides Darwin's own declarations (SO_NOSIGPIPE, F_SETNOSIGPIPE,
# statfs's f_fstypename). Darwin keeps them visible alongside the POSIX set (ADR-024).
if(APPLE)
  target_compile_definitions(${flint_ffi} PRIVATE _DARWIN_C_SOURCE)
endif()
# Wasmtime is a static archive in this profile; Windows headers must not emit DLL imports.
if(WIN32 AND EXISTS "${CMAKE_INSTALL_PREFIX}/include/wasmtime.h")
  target_compile_definitions(${flint_ffi} PRIVATE WASM_API_EXTERN= WASI_API_EXTERN=)
endif()
foreach(PAIR IN ITEMS "llhttp.h|LLHTTP" "nghttp2/nghttp2.h|NGHTTP2" "curl/curl.h|CURL" "openssl/ssl.h|OPENSSL"
    "sqlite3.h|SQLITE" "libpq-fe.h|LIBPQ" "hiredis/hiredis_ssl.h|HIREDIS" "sodium.h|LIBSODIUM"
    "librdkafka/rdkafka.h|LIBRDKAFKA" "protobuf-c/protobuf-c.h|PROTOBUF_C" "yaml.h|LIBYAML" "utf8proc.h|UTF8PROC"
    "zlib.h|ZLIB" "zstd.h|ZSTD" "brotli/decode.h|BROTLI" "archive.h|LIBARCHIVE")
  string(REPLACE "|" ";" FIELDS "${PAIR}")
  list(GET FIELDS 0 HEADER)
  list(GET FIELDS 1 SYMBOL)
  if(EXISTS "${CMAKE_INSTALL_PREFIX}/include/${HEADER}")
    target_compile_definitions(${flint_ffi} PRIVATE "FLINT_HAS_${SYMBOL}=1")
  endif()
endforeach()
find_library(FLINT_FFI_BASE NAMES flint_ffi_base PATHS "${CMAKE_INSTALL_PREFIX}/lib" NO_DEFAULT_PATH REQUIRED)
install(TARGETS flint_ffi_framework ARCHIVE DESTINATION lib)
enable_testing()

# Each public header is installed when its engine ships it and its provider is in the prefix.
foreach(PAIR IN ITEMS
    "flint_codec.h|zlib.h;zstd.h;brotli/decode.h;archive.h"
    "flint_http.h|curl/curl.h"
    "flint_web.h|llhttp.h"
    "flint_sql.h|sqlite3.h;libpq-fe.h"
    "flint_cache.h|hiredis/hiredis_ssl.h"
    "flint_security.h|openssl/evp.h;sodium.h"
    "flint_mq.h|librdkafka/rdkafka.h"
    "flint_mq_socket.h|librdkafka/rdkafka.h"
    "flint_rpc.h|openssl/evp.h;protobuf-c/protobuf-c.h")
  string(FIND "${PAIR}" "|" bar)
  string(SUBSTRING "${PAIR}" 0 ${bar} header)
  math(EXPR rest "${bar} + 1")
  string(SUBSTRING "${PAIR}" ${rest} -1 providers)
  flint_engine_file(${header} path)
  set(provided FALSE)
  foreach(provider IN LISTS providers)
    if(EXISTS "${CMAKE_INSTALL_PREFIX}/include/${provider}")
      set(provided TRUE)
    endif()
  endforeach()
  if(path AND provided)
    install(FILES "${path}" DESTINATION include)
  endif()
endforeach()

flint_engine_file(flint_desktop.h FLINT_DESKTOP_H)
if((CMAKE_SYSTEM_NAME STREQUAL "Linux" OR APPLE OR WIN32) AND EXISTS "${CMAKE_INSTALL_PREFIX}/include/SDL3/SDL.h"
    AND FLINT_DESKTOP_H)
  target_compile_definitions(flint_ffi_framework PRIVATE FLINT_HAS_SDL3=1)
  install(FILES "${FLINT_DESKTOP_H}" DESTINATION include)
endif()

# Test codecs and their benchmark control are separate from the production FFI archive.
flint_engine_file(flint_rpc.h FLINT_RPC_H)
if(FLINT_RPC_H)
  get_filename_component(FLINT_RPC_PACKAGE "${FLINT_RPC_H}/../../.." ABSOLUTE)
  set(FLINT_RPC_TEST_CODECS "${FLINT_RPC_PACKAGE}/tests/generated")
endif()
if(EXISTS "${CMAKE_INSTALL_PREFIX}/include/protobuf-c/protobuf-c.h" AND EXISTS "${FLINT_RPC_TEST_CODECS}/echo.pb-c.c")
  add_library(flint_rpc_fixture STATIC
    "${FLINT_RPC_TEST_CODECS}/echo.pb-c.c"
    "${FLINT_RPC_TEST_CODECS}/echo_flint.c"
    "${FLINT_RPC_PACKAGE}/bench/baseline/source/probe.c")
  get_filename_component(FLINT_RPC_SHIMS "${FLINT_RPC_H}" DIRECTORY)
  target_include_directories(flint_rpc_fixture PRIVATE
    "${FLINT_RPC_TEST_CODECS}" "${FLINT_RPC_SHIMS}" "${CMAKE_INSTALL_PREFIX}/include")
  install(TARGETS flint_rpc_fixture ARCHIVE DESTINATION lib)
endif()

flint_engine_file(flint_reactor_uring.h FLINT_URING_H)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND EXISTS "${CMAKE_INSTALL_PREFIX}/include/liburing.h" AND FLINT_URING_H)
  target_compile_definitions(flint_ffi_framework PRIVATE FLINT_HAS_LIBURING=1)
  install(FILES "${FLINT_URING_H}" DESTINATION include)
  get_filename_component(FLINT_REACTOR_SHIMS "${FLINT_URING_H}" DIRECTORY)
  find_library(FLINT_URING NAMES liburing.a PATHS "${CMAKE_INSTALL_PREFIX}/lib" NO_DEFAULT_PATH REQUIRED)
  add_executable(flint_reactor_uring_test "${FLINT_REACTOR_SHIMS}/reactor_uring_test.c")
  target_include_directories(flint_reactor_uring_test PRIVATE "${FLINT_REACTOR_SHIMS}")
  target_link_libraries(flint_reactor_uring_test PRIVATE flint_ffi_framework "${FLINT_FFI_BASE}" "${FLINT_URING}")
  add_test(NAME flint_reactor_uring_test COMMAND flint_reactor_uring_test)
  set_tests_properties(flint_reactor_uring_test PROPERTIES SKIP_RETURN_CODE 77 TIMEOUT 10)
  add_test(NAME flint_reactor_uring_denied COMMAND flint_reactor_uring_test --deny-setup)
  set_tests_properties(flint_reactor_uring_denied PROPERTIES TIMEOUT 10)
endif()

if(EXISTS "${CMAKE_INSTALL_PREFIX}/include/llhttp.h" AND EXISTS "${CMAKE_INSTALL_PREFIX}/include/zlib.h")
  find_library(FLINT_LLHTTP NAMES llhttp llhttp_static PATHS "${CMAKE_INSTALL_PREFIX}/lib" "${CMAKE_INSTALL_PREFIX}/lib64" NO_DEFAULT_PATH REQUIRED)
  find_library(FLINT_ZLIB NAMES z zlibstatic zlib zs libzs PATHS "${CMAKE_INSTALL_PREFIX}/lib" "${CMAKE_INSTALL_PREFIX}/lib64" NO_DEFAULT_PATH REQUIRED)
  add_executable(flint_native_library_test native_library_test.c)
  target_compile_definitions(flint_native_library_test PRIVATE FLINT_SMOKE_MAIN=1)
  target_include_directories(flint_native_library_test PRIVATE "${CMAKE_INSTALL_PREFIX}/include")
  target_link_libraries(flint_native_library_test PRIVATE flint_ffi_framework "${FLINT_FFI_BASE}" "${FLINT_LLHTTP}" "${FLINT_ZLIB}")
  add_test(NAME flint_native_library_test COMMAND flint_native_library_test)
endif()

flint_engine_file(flint_mq_socket.c FLINT_MQ_SOCKET_C)
if((CMAKE_SYSTEM_NAME STREQUAL "Linux" OR APPLE) AND FLINT_MQ_SOCKET_C)
  # White-box socket option test; it compiles flint_mq_socket.c itself without TLS.
  get_filename_component(FLINT_MQ_SHIMS "${FLINT_MQ_SOCKET_C}" DIRECTORY)
  add_executable(flint_mq_socket_test "${FLINT_MQ_SHIMS}/mq_socket_test.c")
  target_include_directories(flint_mq_socket_test PRIVATE "${FLINT_MQ_SHIMS}")
  if(APPLE)
    target_compile_definitions(flint_mq_socket_test PRIVATE _DARWIN_C_SOURCE)
  endif()
  add_test(NAME flint_mq_socket_test COMMAND flint_mq_socket_test)
endif()

flint_engine_file(flint_wasi.h FLINT_WASI_H)
if((CMAKE_SYSTEM_NAME STREQUAL "Linux" OR APPLE OR WIN32) AND EXISTS "${CMAKE_INSTALL_PREFIX}/include/wasmtime.h" AND
    FLINT_WASI_H)
  target_compile_definitions(flint_ffi_framework PRIVATE FLINT_HAS_WASMTIME=1)
  if(EXISTS "${CMAKE_INSTALL_PREFIX}/include/flint_wasmtime_extensions.h")
    target_compile_definitions(flint_ffi_framework PRIVATE FLINT_HAS_WASMTIME_EXTENSIONS=1)
    get_filename_component(FLINT_WASI_REFERENCE "${FLINT_WASI_H}/../../../bench/baseline/native/direct.c" ABSOLUTE)
    # The direct-provider bench reference is built on Linux and macOS only; no Windows bench lane uses it yet.
    if(NOT WIN32 AND EXISTS "${FLINT_WASI_REFERENCE}")
      add_library(flint_wasi_reference STATIC "${FLINT_WASI_REFERENCE}")
      target_include_directories(flint_wasi_reference PRIVATE "${CMAKE_INSTALL_PREFIX}/include")
      install(TARGETS flint_wasi_reference ARCHIVE DESTINATION lib)
    endif()
  endif()
  install(FILES "${FLINT_WASI_H}" DESTINATION include)
endif()

flint_engine_file(flint_mail.h FLINT_MAIL_H)
if((CMAKE_SYSTEM_NAME STREQUAL "Linux" OR APPLE OR WIN32) AND FLINT_MAIL_H AND
    EXISTS "${CMAKE_INSTALL_PREFIX}/include/curl/curl.h")
  install(FILES "${FLINT_MAIL_H}" DESTINATION include)
  # Isolated pinned-ABI control. Static linking retains it only in the reference executable.
  get_filename_component(FLINT_MAIL_REFERENCE "${FLINT_MAIL_H}/../../../bench/baseline/native/direct.c" ABSOLUTE)
  if(EXISTS "${FLINT_MAIL_REFERENCE}")
    add_library(flint_mail_reference STATIC "${FLINT_MAIL_REFERENCE}")
    target_include_directories(flint_mail_reference PRIVATE "${CMAKE_INSTALL_PREFIX}/include")
    install(TARGETS flint_mail_reference ARCHIVE DESTINATION lib)
  endif()
endif()
