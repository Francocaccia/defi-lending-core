cmake_minimum_required(VERSION 3.16)
project(refmodel LANGUAGES CXX)

# Independent C++ reference model of the lending protocol's pure math (docs/DESIGN.md section 9).
# No third-party dependencies: exact 256-bit math is hand-written (src/uint256.*) because MSVC has
# no __int128 and a header-only big-integer dependency would need a download for ~250 lines.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release)
endif()

option(REFMODEL_BUILD_TESTS "Build the C++ unit tests" ON)

add_library(refmodel_core STATIC src/uint256.cpp src/model.cpp src/cli.cpp)
target_include_directories(refmodel_core PUBLIC src)

add_executable(refmodel src/main.cpp)
target_link_libraries(refmodel PRIVATE refmodel_core)

if(MSVC)
  set(REFMODEL_WARNINGS /W4 /permissive- /utf-8)
else()
  set(REFMODEL_WARNINGS -Wall -Wextra -Wpedantic -Wshadow -Wconversion)
endif()
target_compile_options(refmodel_core PRIVATE ${REFMODEL_WARNINGS})
target_compile_options(refmodel PRIVATE ${REFMODEL_WARNINGS})

if(REFMODEL_BUILD_TESTS)
  enable_testing()

  add_executable(refmodel_tests
    tests/test_main.cpp
    tests/test_uint256.cpp
    tests/test_model.cpp
    tests/test_cli.cpp
    tests/test_vectors.cpp)
  target_link_libraries(refmodel_tests PRIVATE refmodel_core)
  target_compile_options(refmodel_tests PRIVATE ${REFMODEL_WARNINGS})
  # The shared spec vectors live in the Solidity half of the repo (test/differential/).
  get_filename_component(REFMODEL_VECTORS "${CMAKE_CURRENT_SOURCE_DIR}/../test/differential/vectors.txt" ABSOLUTE)
  target_compile_definitions(refmodel_tests PRIVATE VECTORS_FILE="${REFMODEL_VECTORS}")
  add_test(NAME unit COMMAND refmodel_tests)

  # Black-box tests of the REAL binary: exit code, exact stdout, stderr prefix (tests/cli_case.cmake).
  function(refmodel_cli_test name code stdout_exact stderr_prefix)
    add_test(NAME cli_${name}
      COMMAND ${CMAKE_COMMAND}
        -DBIN=$<TARGET_FILE:refmodel>
        -DEXPECT_CODE=${code}
        "-DEXPECT_OUT=${stdout_exact}"
        "-DEXPECT_ERR_PREFIX=${stderr_prefix}"
        "-DARGS=${ARGN}"
        -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/cli_case.cmake)
  endfunction()

  # ARGS are comma separated (a ';' would be a CMake list separator).
  refmodel_cli_test(ok_decimal 0
    "0x00000000000000000000000000000000000000000000000004a03ce68d215555" ""
    "utilization,3,1")
  refmodel_cli_test(ok_hex 0
    "0x00000000000000000000000000000000000000000000000004a03ce68d215555" ""
    "utilization,0x3,0X1")
  refmodel_cli_test(ok_three_words 0
    "0x000000000000000000000000000000000000000000000000000000012a05f200000000000000000000000000000000000000000000000000000000012a05f2000000000000000000000000000000000000000000000000000000000000000000"
    ""
    "badDebt,5000000000,5000000000,1000000000000000000000000000,5000000000")
  refmodel_cli_test(revert_exit1 1 "" "error: " "annualBorrowRate,0,0,0,0,0")
  refmodel_cli_test(usage_unknown_function 2 "" "usage: " "nope,1")
  refmodel_cli_test(usage_no_args 2 "" "usage: " "")
  refmodel_cli_test(usage_arity 2 "" "usage: " "utilization,1")
  refmodel_cli_test(usage_bad_number 2 "" "usage: " "utilization,1,abc")
  refmodel_cli_test(usage_too_big 2 "" "usage: "
    "utilization,115792089237316195423570985008687907853269984665640564039457584007913129639936,1")
  refmodel_cli_test(usage_decimals_over_255 2 "" "usage: " "collateralValueUsd,1,1,256")
endif()
