cmake_minimum_required(VERSION 3.20)
project(asus_a10_dma_lifecycle LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(A10_BUILD_DMA_LIFECYCLE "Build the existing MMD DMA lifecycle and test" ON)
option(A10_BUILD_KERNEL_EXECUTOR "Build the generated-kernel executor and test" ON)

find_package(Threads REQUIRED)
enable_testing()

add_library(a10_kernel_mailbox STATIC src/kernel_mailbox.cpp)
target_include_directories(a10_kernel_mailbox PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_compile_options(a10_kernel_mailbox PRIVATE -Wall -Wextra -Wpedantic -Werror)
add_executable(a10_kernel_mailbox_test tests/kernel_mailbox_test.cpp)
target_link_libraries(a10_kernel_mailbox_test PRIVATE a10_kernel_mailbox)
target_compile_options(a10_kernel_mailbox_test PRIVATE -Wall -Wextra -Wpedantic -Werror)
add_test(NAME a10_kernel_mailbox COMMAND a10_kernel_mailbox_test)

add_library(a10_host_writeback_fence STATIC src/host_writeback_fence.cpp)
target_link_libraries(a10_host_writeback_fence PUBLIC a10_kernel_mailbox)
target_compile_options(a10_host_writeback_fence PRIVATE -Wall -Wextra -Wpedantic -Werror)
add_executable(a10_host_writeback_fence_test tests/host_writeback_fence_test.cpp)
target_link_libraries(a10_host_writeback_fence_test PRIVATE a10_host_writeback_fence)
add_test(NAME a10_host_writeback_fence COMMAND a10_host_writeback_fence_test)

add_library(a10_host_writeback_round STATIC src/host_writeback_round.cpp)
target_link_libraries(a10_host_writeback_round PUBLIC a10_kernel_mailbox)
target_compile_options(a10_host_writeback_round PRIVATE -Wall -Wextra -Wpedantic -Werror)
add_executable(a10_host_writeback_round_test tests/host_writeback_round_test.cpp)
target_link_libraries(a10_host_writeback_round_test PRIVATE a10_host_writeback_round)
add_test(NAME a10_host_writeback_round COMMAND a10_host_writeback_round_test)

add_library(a10_supervisor_command STATIC src/supervisor_command.cpp)
target_link_libraries(a10_supervisor_command PUBLIC a10_kernel_mailbox)
target_compile_options(a10_supervisor_command PRIVATE -Wall -Wextra -Wpedantic -Werror)
add_executable(a10_supervisor_command_test tests/supervisor_command_test.cpp)
target_link_libraries(a10_supervisor_command_test PRIVATE a10_supervisor_command)
add_test(NAME a10_supervisor_command COMMAND a10_supervisor_command_test)

add_library(a10_platform_open STATIC src/platform_open.cpp)
target_link_libraries(a10_platform_open PUBLIC a10_host_writeback_round a10_supervisor_command)
target_compile_options(a10_platform_open PRIVATE -Wall -Wextra -Wpedantic -Werror)
add_executable(a10_platform_open_test tests/platform_open_test.cpp)
target_link_libraries(a10_platform_open_test PRIVATE a10_platform_open)
target_compile_options(a10_platform_open_test PRIVATE -Wall -Wextra -Wpedantic -Werror)
add_test(NAME a10_platform_open COMMAND a10_platform_open_test)

add_library(a10_aclpci_mailbox_port STATIC src/aclpci_mailbox_port.cpp)
target_link_libraries(a10_aclpci_mailbox_port PUBLIC a10_kernel_mailbox)
target_include_directories(a10_aclpci_mailbox_port PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../drivers/aclpci")
target_compile_options(a10_aclpci_mailbox_port PRIVATE -Wall -Wextra -Wpedantic -Werror)
add_executable(a10_aclpci_mailbox_port_test tests/aclpci_mailbox_port_test.cpp)
target_link_libraries(a10_aclpci_mailbox_port_test PRIVATE a10_aclpci_mailbox_port)
target_include_directories(a10_aclpci_mailbox_port_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../drivers/aclpci")
add_test(NAME a10_aclpci_mailbox_port COMMAND a10_aclpci_mailbox_port_test)

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
  option(A10_KERNEL_EXECUTOR_PACKED "Extract schema 2 packed arguments from generated source" OFF)
  set(a10_repo "${CMAKE_CURRENT_SOURCE_DIR}/..")
  set(a10_codegen "${a10_repo}/tools/kernel_executor_codegen.py")
  if(A10_KERNEL_EXECUTOR_SNAPSHOT_ONLY)
    if(A10_KERNEL_SOURCE_DIR OR A10_KERNEL_EXECUTOR_PACKED)
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
    if(A10_KERNEL_EXECUTOR_PACKED)
      list(APPEND a10_codegen_args --packed)
    endif()
  endif()
  set(a10_abi_include "${CMAKE_CURRENT_BINARY_DIR}/generated/generated_kernel_abi_data.inc")
  add_custom_command(OUTPUT "${a10_abi_include}"
    COMMAND "${Python3_EXECUTABLE}" "${a10_codegen}" ${a10_codegen_args}
            --output "${a10_abi_include}"
    DEPENDS "${a10_codegen}" "${a10_repo}/tools/kernel_abi.py"
            "${a10_repo}/tools/packed_kernel_args.py"
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
  option(A10_KERNEL_EXECUTOR_OPENCL "Test the generated streaming OpenCL ABI" OFF)
  if(A10_KERNEL_EXECUTOR_OPENCL)
    if(NOT A10_KERNEL_EXECUTOR_PACKED)
      message(FATAL_ERROR "OpenCL streaming ABI requires packed source extraction")
    endif()
    add_executable(a10_generated_kernel_executor_test tests/opencl_kernel_executor_test.cpp)
    add_test(NAME a10_opencl_cra_source
      COMMAND "${Python3_EXECUTABLE}" -m unittest discover
        -s "${a10_repo}/tests/unit" -p test_opencl_cra_abi.py -v)
  elseif(A10_KERNEL_EXECUTOR_PACKED)
    add_executable(a10_generated_kernel_executor_test tests/packed_kernel_executor_test.cpp)
  else()
    add_executable(a10_generated_kernel_executor_test tests/generated_kernel_executor_test.cpp)
  endif()
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

option(A10_BUILD_SHELL_IDENTITY "Build read-only future-shell identity decoder" ON)
if(A10_BUILD_KERNEL_EXECUTOR AND A10_BUILD_SHELL_IDENTITY)
  add_library(a10_shell_identity STATIC src/shell_identity_v1.cpp)
  target_link_libraries(a10_shell_identity PUBLIC a10_generated_kernel_executor)
  target_compile_options(a10_shell_identity PRIVATE -Wall -Wextra -Wpedantic -Werror)
  add_library(a10_aclpci_identity_reader STATIC src/aclpci_identity_reader.cpp)
  target_link_libraries(a10_aclpci_identity_reader PUBLIC a10_shell_identity a10_aclpci_mailbox_port)
  target_include_directories(a10_aclpci_identity_reader PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../drivers/aclpci")
  target_compile_options(a10_aclpci_identity_reader PRIVATE -Wall -Wextra -Wpedantic -Werror)
  add_executable(a10_aclpci_identity_reader_test tests/aclpci_identity_reader_test.cpp)
  target_link_libraries(a10_aclpci_identity_reader_test PRIVATE a10_aclpci_identity_reader)
  target_include_directories(a10_aclpci_identity_reader_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../drivers/aclpci")
  add_test(NAME a10_aclpci_identity_reader COMMAND a10_aclpci_identity_reader_test)
  add_executable(a10_shell_identity_test tests/shell_identity_v1_test.cpp)
  target_link_libraries(a10_shell_identity_test PRIVATE a10_shell_identity)
  target_compile_options(a10_shell_identity_test PRIVATE -Wall -Wextra -Wpedantic -Werror)
  add_test(NAME a10_shell_identity COMMAND a10_shell_identity_test)
  set_tests_properties(a10_shell_identity PROPERTIES
    PASS_REGULAR_EXPRESSION "A10_IDENTITY_HOST_PASS"
    FAIL_REGULAR_EXPRESSION "Fatal:|Error!|Error:|Error-\\[")
  add_test(NAME a10_shell_identity_codegen
    COMMAND "${Python3_EXECUTABLE}" "${a10_repo}/tools/test_shell_identity_codegen.py")

  # Explicit retained build bundle: no default shell mapping or physical transport.
  set(A10_SHELL_IDENTITY_PREPARED_DIR "" CACHE PATH
      "Output directory of shell_identity_codegen.py prepare for this exact build")
  if(A10_SHELL_IDENTITY_PREPARED_DIR)
    if(A10_KERNEL_EXECUTOR_SNAPSHOT_ONLY)
      message(FATAL_ERROR "A retained shell build requires re-extracted generated sources")
    endif()
    foreach(item prepared.json shell_identity_params.svh shell_identity_expected.hpp)
      if(NOT EXISTS "${A10_SHELL_IDENTITY_PREPARED_DIR}/${item}")
        message(FATAL_ERROR "Missing prepared shell identity file: ${item}")
      endif()
    endforeach()
    add_library(a10_shell_identity_expected INTERFACE)
    target_link_libraries(a10_shell_identity_expected INTERFACE a10_shell_identity)
    target_include_directories(a10_shell_identity_expected INTERFACE
      "${A10_SHELL_IDENTITY_PREPARED_DIR}")
    # The HDL build must consume this SAME params file at shell_identity_v1.
    # Source/build comparison still occurs in image::check; this target grants no I/O.
  endif()
endif()

if(A10_BUILD_DMA_LIFECYCLE)
  set_target_properties(a10_dma_operation_lifecycle PROPERTIES POSITION_INDEPENDENT_CODE ON)
  add_library(a10_mmd_adapter SHARED mmd/adapter.cpp)
  target_include_directories(a10_mmd_adapter PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/mmd")
  target_link_libraries(a10_mmd_adapter PUBLIC a10_dma_operation_lifecycle)
  target_compile_options(a10_mmd_adapter PRIVATE -Wall -Wextra -Wpedantic -Werror)
  add_executable(a10_mmd_adapter_test mmd/adapter_test.cpp)
  target_link_libraries(a10_mmd_adapter_test PRIVATE a10_mmd_adapter)
  target_compile_options(a10_mmd_adapter_test PRIVATE -Wall -Wextra -Wpedantic -Werror)
  add_test(NAME a10_mmd_adapter COMMAND a10_mmd_adapter_test)
endif()

add_library(a10_ddr_traffic_metrics INTERFACE)
target_include_directories(a10_ddr_traffic_metrics INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
add_executable(a10_ddr_traffic_metrics_test tests/ddr_traffic_metrics_test.cpp)
target_link_libraries(a10_ddr_traffic_metrics_test PRIVATE a10_ddr_traffic_metrics)
target_compile_options(a10_ddr_traffic_metrics_test PRIVATE -Wall -Wextra -Wpedantic -Werror)
add_test(NAME a10_ddr_traffic_metrics COMMAND a10_ddr_traffic_metrics_test)

add_library(a10_ddr_snapshot_reader STATIC src/ddr_snapshot_reader.cpp)
target_link_libraries(a10_ddr_snapshot_reader PUBLIC a10_kernel_mailbox a10_ddr_traffic_metrics)
target_compile_options(a10_ddr_snapshot_reader PRIVATE -Wall -Wextra -Wpedantic -Werror)
add_executable(a10_ddr_snapshot_reader_test tests/ddr_snapshot_reader_test.cpp)
target_link_libraries(a10_ddr_snapshot_reader_test PRIVATE a10_ddr_snapshot_reader)
target_compile_options(a10_ddr_snapshot_reader_test PRIVATE -Wall -Wextra -Wpedantic -Werror)
add_test(NAME a10_ddr_snapshot_reader COMMAND a10_ddr_snapshot_reader_test)
