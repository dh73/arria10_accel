#include "generated_kernel_abi.hpp"
#include "shell_identity_expected.hpp"
#include <iostream>

int main() {
  namespace kernel = asus::a10::kernel;
  namespace expected = asus::a10::image::generated;
  const auto& abi = kernel::generated_abi();
  if (abi.validation() != kernel::SourceValidation::Reextracted ||
      abi.contract_sha256() != expected::source_sha256 ||
      abi.aperture_bytes() != expected::cra_bytes) {
    std::cerr << "Prepared image identity does not match the host kernel source contract\n";
    return 1;
  }
  std::cout << "PREPARED_HOST_SOURCE_MATCH; no loaded-image or admission claim\n";
}
