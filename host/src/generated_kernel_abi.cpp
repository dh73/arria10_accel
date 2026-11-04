#include "generated_kernel_abi.hpp"

#include <algorithm>
#include <iterator>
#include <map>

namespace asus::a10::kernel {

SourceAbi::SourceAbi() {
#include "generated_kernel_abi_data.inc"
}

const SourceAbi& generated_abi() {
  static const SourceAbi source;
  return source;
}

std::optional<Launch> Launch::make(std::string_view name,
                                 const NamedArguments& arguments) {
  const auto& source = generated_abi();
  const KernelDescriptor* selected = nullptr;
  for (std::size_t i = 0; i < source.kernel_count(); ++i) {
    if (source.kernel(i).name == name) selected = &source.kernel(i);
  }
  if (selected == nullptr || arguments.size() != selected->arguments.size()) {
    return std::nullopt;
  }
  std::vector<std::uint64_t> values;
  values.reserve(arguments.size());
  for (const auto& argument : selected->arguments) {
    const auto found = std::find_if(arguments.begin(), arguments.end(),
        [&](const auto& item) { return item.first == argument.name; });
    if (found == arguments.end() || std::find_if(std::next(found), arguments.end(),
        [&](const auto& item) { return item.first == argument.name; }) != arguments.end()) {
      return std::nullopt;
    }
    if (argument.size == 4 && found->second > UINT32_MAX) return std::nullopt;
    values.push_back(found->second);
  }
  // Allocate and combine each lane before any executor admission or I/O.
  std::map<std::uint32_t, ArgumentWrite> words;
  for (std::size_t i = 0; i < values.size(); ++i) {
    for (const auto& piece : selected->arguments[i].pieces) {
      const auto offset = selected->base + piece.byte_offset;
      auto& word = words[offset];
      word.byte_offset = offset;
      word.value |= ((values[i] >> piece.argument_bit_offset) & UINT64_C(0xffffffff))
                    << piece.register_bit_offset;
      word.byte_enable |= static_cast<std::uint8_t>(0x0f << (piece.register_bit_offset / 8));
    }
  }
  std::vector<ArgumentWrite> writes;
  writes.reserve(words.size());
  for (const auto& entry : words) writes.push_back(entry.second);
  return Launch(*selected, std::move(values), std::move(writes));
}

}  // namespace asus::a10::kernel
