cmake_minimum_required(VERSION 3.20)
project(asus_a10_dma_lifecycle LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(A10_BUILD_DMA_LIFECYCLE "Build the existing MMD DMA lifecycle and test" ON)
option(A10_BUILD_KERNEL_EXECUTOR "Build the generated-kernel executor and test" ON)

find_package(Threads REQUIRED)
enable_testing()

if(A10_BUILD_DMA_LIFECYCLE)
  set(AOCL_MMD_INCLUDE_DIR "" CACHE PATH
      "Directory containing MMD/aocl_mmd.h from pinned fpga-runtime-for-opencl")
  if(NOT EXISTS "${AOCL_MMD_INCLUDE_DIR}/MMD/aocl_mmd.h")
    message(FATAL_ERROR
      "Set -DAOCL_MMD_INCLUDE_DIR=<repo>/third_party/fpga-runtime-for-opencl/include")
  endif()

  add_library(a10_dma_operation_lifecycle STATIC
    src/dma_operation_lifecycle.cpp)
  target_include_directories(a10_dma_operation_lifecycle
    PUBLIC
      ${CMAKE_CURRENT_SOURCE_DIR}/include
      ${AOCL_MMD_INCLUDE_DIR})
  target_link_libraries(a10_dma_operation_lifecycle PUBLIC Threads::Threads)
  target_compile_options(a10_dma_operation_lifecycle PRIVATE
    -Wall -Wextra -Wpedantic -Werror)

  add_executable(a10_dma_operation_lifecycle_test
    tests/dma_operation_lifecycle_test.cpp)
  target_link_libraries(a10_dma_operation_lifecycle_test
    PRIVATE a10_dma_operation_lifecycle)
  target_compile_options(a10_dma_operation_lifecycle_test PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
  add_test(NAME a10_dma_operation_lifecycle
           COMMAND a10_dma_operation_lifecycle_test)
endif()

if(A10_BUILD_KERNEL_EXECUTOR)
  find_package(Python3 3.9 REQUIRED COMPONENTS Interpreter)
  set(A10_KERNEL_SOURCE_DIR "" CACHE PATH
      "Generated kernel snapshot containing the compiler XML and kernel_system.sv")
  option(A10_KERNEL_EXECUTOR_SNAPSHOT_ONLY
      "TEST ONLY: compile the supplied ABI snapshot without re-extracting generated RTL" OFF)
  set(a10_repo "${CMAKE_CURRENT_SOURCE_DIR}/..")
  set(a10_codegen "${a10_repo}/tools/kernel_executor_codegen.py")
  if(A10_KERNEL_EXECUTOR_SNAPSHOT_ONLY)
    if(A10_KERNEL_SOURCE_DIR)
      message(FATAL_ERROR "Select generated source OR explicit test snapshot, not both")
    endif()
    message(WARNING "Kernel executor uses supplied source ABI snapshot; hardware use is unqualified")
    set(a10_abi_input "${a10_repo}/tests/fixtures/generated-kernel-abi.json")
    set(a10_codegen_args --snapshot "${a10_abi_input}")
    set(a10_codegen_dependencies "${a10_abi_input}")
  else()
    if(NOT IS_DIRECTORY "${A10_KERNEL_SOURCE_DIR}")
      message(FATAL_ERROR
        "Set A10_KERNEL_SOURCE_DIR to generated source, or explicitly enable A10_KERNEL_EXECUTOR_SNAPSHOT_ONLY for fake tests")
    endif()
    file(GLOB_RECURSE a10_codegen_dependencies CONFIGURE_DEPENDS
      "${A10_KERNEL_SOURCE_DIR}/*.sv" "${A10_KERNEL_SOURCE_DIR}/*.bc.xml")
    set(a10_codegen_args --source "${A10_KERNEL_SOURCE_DIR}")
  endif()
  set(a10_abi_include "${CMAKE_CURRENT_BINARY_DIR}/generated/generated_kernel_abi_data.inc")
  add_custom_command(OUTPUT "${a10_abi_include}"
    COMMAND "${Python3_EXECUTABLE}" "${a10_codegen}" ${a10_codegen_args}
            --output "${a10_abi_include}"
    DEPENDS "${a10_codegen}" "${a10_repo}/tools/kernel_abi.py"
            ${a10_codegen_dependencies}
    VERBATIM)
  add_library(a10_generated_kernel_executor STATIC
    src/generated_kernel_abi.cpp src/generated_kernel_executor.cpp "${a10_abi_include}")
  target_include_directories(a10_generated_kernel_executor
    PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include"
    PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/generated")
  target_link_libraries(a10_generated_kernel_executor PUBLIC Threads::Threads)
  target_compile_options(a10_generated_kernel_executor PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
  add_executable(a10_generated_kernel_executor_test tests/generated_kernel_executor_test.cpp)
  target_link_libraries(a10_generated_kernel_executor_test PRIVATE a10_generated_kernel_executor)
  target_compile_options(a10_generated_kernel_executor_test PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
  add_test(NAME a10_generated_kernel_executor COMMAND a10_generated_kernel_executor_test)
  add_test(NAME a10_generated_kernel_codegen
    COMMAND "${Python3_EXECUTABLE}" "${a10_repo}/tools/test_kernel_executor_codegen.py")
  if(NOT A10_KERNEL_EXECUTOR_SNAPSHOT_ONLY)
    add_test(NAME a10_corrected_cra_source
      COMMAND "${Python3_EXECUTABLE}" -m unittest discover
        -s "${a10_repo}/tests/unit" -p test_corrected_cra_abi.py -v)
  else()
    message(STATUS "Snapshot mode: compiler-source CRA regression requires a source build")
  endif()
endif()
