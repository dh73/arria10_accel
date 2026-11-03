#include "generated_kernel_abi.hpp"

#include <algorithm>
#include <iterator>

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
    values.push_back(found->second);
  }
  return Launch(*selected, std::move(values));
}

}  // namespace asus::a10::kernel
