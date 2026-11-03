cmake_minimum_required(VERSION 3.16)
project(asus_a10_platform LANGUAGES CXX)
include(CTest)
set(AOCL_MMD_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/fpga-runtime-for-opencl/include"
  CACHE PATH "Pinned Intel runtime MMD headers")
set(A10_KERNEL_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/qualification/cra-source-abi-v1/source"
  CACHE PATH "Qualified corrected generated source subset for checked executor ABI")
add_subdirectory(host)
find_package(Python3 REQUIRED COMPONENTS Interpreter)
add_test(NAME generated_kernel_abi COMMAND ${Python3_EXECUTABLE} -m unittest discover
  -s ${CMAKE_CURRENT_SOURCE_DIR}/tests/host -p test_kernel_abi.py -v)
add_test(NAME generated_kernel_launch COMMAND ${Python3_EXECUTABLE} -m unittest discover
  -s ${CMAKE_CURRENT_SOURCE_DIR}/tests/host -p test_kernel_launch.py -v)
add_test(NAME user_dma_fault_injection COMMAND ${Python3_EXECUTABLE} -m unittest discover
  -s ${CMAKE_CURRENT_SOURCE_DIR}/tests/driver -p test_user_dma.py -v)
add_test(NAME dma_descriptor_batch COMMAND ${Python3_EXECUTABLE} -m unittest discover
  -s ${CMAKE_CURRENT_SOURCE_DIR}/tests/driver -p test_dma_batch.py -v)
add_test(NAME dma_request_retirement COMMAND ${Python3_EXECUTABLE} -m unittest discover
  -s ${CMAKE_CURRENT_SOURCE_DIR}/tests/driver -p test_dma_request.py -v)
add_test(NAME dma_components COMMAND ${Python3_EXECUTABLE} -m unittest discover
  -s ${CMAKE_CURRENT_SOURCE_DIR}/tests/driver -p test_dma_components.py -v)
add_test(NAME driver_integration COMMAND sh
  ${CMAKE_CURRENT_SOURCE_DIR}/drivers/aclpci/tests/run-integration.sh)
add_library(asus_a10_host INTERFACE)
target_include_directories(asus_a10_host INTERFACE include include/asus_a10)
target_compile_features(asus_a10_host INTERFACE cxx_std_20)
foreach(name descriptor_codec native_dma_descriptor dma_range workload_reference)
  add_executable(test_${name} tests/host/test_${name}.cpp)
  target_link_libraries(test_${name} PRIVATE asus_a10_host)
  target_compile_options(test_${name} PRIVATE -Wall -Wextra -Werror -pedantic)
  add_test(NAME ${name} COMMAND test_${name})
endforeach()
add_test(NAME c126_preflight COMMAND ${Python3_EXECUTABLE} -m unittest discover
  -s ${CMAKE_CURRENT_SOURCE_DIR}/tests/c126 -p "test_*.py" -v)
set_tests_properties(c126_preflight PROPERTIES
  ENVIRONMENT "PYTHONPATH=${CMAKE_CURRENT_SOURCE_DIR}/tools/c126")
# RTL simulation requires VCS per user direction.
find_program(VCS_EXECUTABLE vcs)
find_program(VCS_RUN_EXECUTABLE vcs-run)
if(VCS_EXECUTABLE AND VCS_RUN_EXECUTABLE)
  add_test(NAME platform_supervisor_vcs COMMAND bash
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/platform_supervisor/run_vcs.sh)
  add_test(NAME supervised_generated_kernels_vcs COMMAND bash
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/vcs/run_supervised_kernel.sh)
  add_test(NAME repeated_generated_kernels_vcs COMMAND bash
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/vcs/run_repeated_kernel.sh)
  add_test(NAME initialized_generated_kernels_vcs COMMAND bash
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/vcs/run_initialized_kernel.sh)
  add_test(NAME kernel_ddr_lane_map_vcs COMMAND bash
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/vcs/run_lane_map.sh)
  add_test(NAME kernel_ddr_adapter_vcs COMMAND bash
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/vcs/run_adapter.sh)
  add_test(NAME kernel_ddr_init_integration_vcs COMMAND bash
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/vcs/run_ddr_init_integration.sh)
endif()
