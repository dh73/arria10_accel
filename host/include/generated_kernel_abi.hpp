#pragma once

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

struct ArgumentDescriptor {
  std::string_view name;
  std::uint32_t byte_offset;
  bool memory_object;
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
  std::size_t kernel_count() const noexcept { return kernels_.size(); }
  const KernelDescriptor& kernel(std::size_t index) const { return kernels_.at(index); }
  std::size_t source_hash_count() const noexcept { return hashes_.size(); }
  const SourceHash& source_hash(std::size_t index) const { return hashes_.at(index); }

 private:
  friend const SourceAbi& generated_abi();
  SourceAbi();
  std::uint32_t aperture_bytes_{0};
  SourceValidation validation_{SourceValidation::SuppliedSnapshot};
  std::vector<KernelDescriptor> kernels_;
  std::vector<SourceHash> hashes_;
};

const SourceAbi& generated_abi();

// No caller-supplied offsets or descriptors can create a launch. Argument
// values are copied and retained in extracted RTL/XML order. Caller mutations
// after make() cannot change the launch. Assignment/move mutation is disabled.
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

 private:
  Launch(const KernelDescriptor& kernel, std::vector<std::uint64_t> values)
      : kernel_(&kernel), values_(std::move(values)) {}
  const KernelDescriptor* const kernel_;
  const std::vector<std::uint64_t> values_;
};

}  // namespace asus::a10::kernel
