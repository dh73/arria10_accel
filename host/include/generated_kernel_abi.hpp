#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace asus::a10::kernel {

enum class SourceValidation { Reextracted, SuppliedSnapshot };
// Source recurrence classification, not physical-image or read-clear authority.
enum class CompletionAccounting { Unqualified, DelayedSnapshotV1 };

struct ArgumentPiece {
  std::uint32_t byte_offset;
  std::uint8_t register_bit_offset, argument_bit_offset;  // Each piece is 32 bits.
};

struct ArgumentDescriptor {
  std::string_view name;
  std::uint32_t byte_offset;  // First piece only; use pieces/writes for packed I/O.
  bool memory_object;
  std::uint8_t size;
  std::vector<ArgumentPiece> pieces;
  std::uint64_t alignment_bytes{0};  // Zero means unknown; cannot launch.
};

struct KernelDescriptor {
  std::string_view name;
  std::uint32_t base, size, start_offset, status_offset, finish_count_offset;
  std::uint8_t finished_bit, finish_count_bits;
  bool finish_count_clear_on_read;
  std::vector<ArgumentDescriptor> arguments;
  CompletionAccounting completion_accounting{CompletionAccounting::Unqualified};
};

struct SourceHash {
  std::string_view path, sha256;
};

// Only the build-time extractor creates this immutable source contract.
// These hashes identify generated source files, never the loaded FPGA image.
class SourceAbi final {
 public:
  SourceAbi(const SourceAbi&) = delete;
  SourceAbi& operator=(const SourceAbi&) = delete;
  std::uint32_t aperture_bytes() const noexcept { return aperture_bytes_; }
  SourceValidation validation() const noexcept { return validation_; }
  // Canonical ABI plus six generated-source hashes; never a loaded-image ID.
  const std::array<std::uint8_t, 32>& contract_sha256() const noexcept {
    return contract_sha256_;
  }
  std::size_t kernel_count() const noexcept { return kernels_.size(); }
  const KernelDescriptor& kernel(std::size_t index) const { return kernels_.at(index); }
  std::size_t source_hash_count() const noexcept { return hashes_.size(); }
  const SourceHash& source_hash(std::size_t index) const { return hashes_.at(index); }

 private:
  friend const SourceAbi& generated_abi();
  SourceAbi();
  std::uint32_t aperture_bytes_{0};
  std::array<std::uint8_t, 32> contract_sha256_{};
  SourceValidation validation_{SourceValidation::SuppliedSnapshot};
  std::vector<KernelDescriptor> kernels_;
  std::vector<SourceHash> hashes_;
};

const SourceAbi& generated_abi();

struct ArgumentWrite {
  std::uint32_t byte_offset;  // Aperture relative, including kernel base.
  std::uint64_t value;
  std::uint8_t byte_enable;
};

// No caller-supplied offsets or descriptors can create a launch. Values are
// copied in extracted RTL/XML order; writes combine lanes in address order.
// Caller mutations cannot change the launch; assignment/move is disabled.
class Launch final {
 public:
  using NamedArguments = std::vector<std::pair<std::string, std::uint64_t>>;
  static std::optional<Launch> make(std::string_view kernel,
                                  const NamedArguments& arguments);
  Launch(const Launch&) = default;
  Launch& operator=(const Launch&) = delete;
  const SourceAbi& source() const noexcept { return generated_abi(); }
  const KernelDescriptor& descriptor() const noexcept { return *kernel_; }
  const std::vector<std::uint64_t>& arguments() const noexcept { return values_; }
  const std::vector<ArgumentWrite>& writes() const noexcept { return writes_; }

 private:
  Launch(const KernelDescriptor& kernel, std::vector<std::uint64_t> values,
         std::vector<ArgumentWrite> writes)
      : kernel_(&kernel), values_(std::move(values)), writes_(std::move(writes)) {}
  const KernelDescriptor* const kernel_;
  const std::vector<std::uint64_t> values_;
  const std::vector<ArgumentWrite> writes_;
};

}  // namespace asus::a10::kernel
