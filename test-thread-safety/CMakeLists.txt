cmake_minimum_required(VERSION 3.14)
project(ThreadSafetyTests LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core RemoteObjects)
find_package(GTest REQUIRED)

# Resolve logos-liblogos root (provides logos_core.h in include/ and liblogos_core in lib/)
if(DEFINED LOGOS_LIBLOGOS_ROOT)
  set(_liblogos "${LOGOS_LIBLOGOS_ROOT}")
elseif(DEFINED ENV{LOGOS_LIBLOGOS_ROOT})
  set(_liblogos "$ENV{LOGOS_LIBLOGOS_ROOT}")
else()
  message(FATAL_ERROR "LOGOS_LIBLOGOS_ROOT is not set")
endif()

find_library(LOGOS_CORE_LIB logos_core
    PATHS ${_liblogos}/lib NO_DEFAULT_PATH REQUIRED)

add_executable(thread_safety_tests test_thread_safety.cpp)

target_include_directories(thread_safety_tests PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${_liblogos}/include
)

target_link_libraries(thread_safety_tests PRIVATE
    ${LOGOS_CORE_LIB}
    GTest::gtest_main
    Qt6::Core
    Qt6::RemoteObjects
)

# DUMMY_PLUGIN_TEMPLATE_DIR can be baked in at cmake time or set via env at runtime
if(DEFINED DUMMY_PLUGIN_TEMPLATE_DIR)
  target_compile_definitions(thread_safety_tests PRIVATE
      DUMMY_PLUGIN_TEMPLATE_DIR="${DUMMY_PLUGIN_TEMPLATE_DIR}")
endif()

# The fixture patches a real plugin binary per dummy module, which invalidates
# its code signature. On Apple platforms a signature-invalid image is SIGKILLed
# the moment it is paged in, so each copy has to be re-signed ad hoc — see
# dummy_module_generator.h. LOGOS_CODESIGN names the tool; the environment
# variable of the same name overrides it at runtime.
if(APPLE)
  if(NOT DEFINED LOGOS_CODESIGN)
    set(LOGOS_CODESIGN "/usr/bin/codesign")
  endif()
  target_compile_definitions(thread_safety_tests PRIVATE
      LOGOS_CODESIGN="${LOGOS_CODESIGN}")
endif()

enable_testing()
add_test(NAME thread_safety_tests COMMAND thread_safety_tests)
