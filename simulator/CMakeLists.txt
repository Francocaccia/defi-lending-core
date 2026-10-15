cmake_minimum_required(VERSION 3.16)
project(defi_sim LANGUAGES CXX)

# Monte Carlo / historical risk simulator for the lending protocol (milestone M9).
# It links the independent reference model's static library, so every protocol decision (interest
# accrual, health factor, liquidation amounts, bad-debt write-off) runs on the SAME exact integer
# math that was verified against the Solidity. No other dependency: CMake + a C++17 compiler.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release)
endif()

option(DEFI_SIM_BUILD_TESTS "Build the simulator's unit tests" ON)

# Reuse the reference model (library only: its own tests/CLI tests are not built here).
set(REFMODEL_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../reference-model ${CMAKE_BINARY_DIR}/refmodel EXCLUDE_FROM_ALL)

find_package(Threads REQUIRED)

if(MSVC)
  set(SIM_WARNINGS /W4 /permissive- /utf-8)
else()
  set(SIM_WARNINGS -Wall -Wextra -Wpedantic -Wshadow)
endif()

add_library(defi_sim_core STATIC
  src/json.cpp
  src/units.cpp
  src/data.cpp
  src/stats.cpp
  src/paths.cpp
  src/engine.cpp
  src/config.cpp
  src/runner.cpp
  src/report.cpp)
target_include_directories(defi_sim_core PUBLIC src)
target_link_libraries(defi_sim_core PUBLIC refmodel_core Threads::Threads)
target_compile_options(defi_sim_core PRIVATE ${SIM_WARNINGS})

add_executable(defi_sim src/main.cpp)
target_link_libraries(defi_sim PRIVATE defi_sim_core)
target_compile_options(defi_sim PRIVATE ${SIM_WARNINGS})

if(DEFI_SIM_BUILD_TESTS)
  enable_testing()
  add_executable(defi_sim_tests
    tests/test_main.cpp
    tests/test_json.cpp
    tests/test_units.cpp
    tests/test_data.cpp
    tests/test_stats.cpp
    tests/test_paths.cpp
    tests/test_engine.cpp
    tests/test_config.cpp
    tests/test_runner.cpp)
  target_include_directories(defi_sim_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../reference-model/tests)
  target_link_libraries(defi_sim_tests PRIVATE defi_sim_core)
  target_compile_options(defi_sim_tests PRIVATE ${SIM_WARNINGS})
  # Tests that read the committed example configs / data need their location.
  target_compile_definitions(defi_sim_tests PRIVATE SIM_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}")
  add_test(NAME unit COMMAND defi_sim_tests)
endif()
