#pragma once
#include "shell_identity_v1.hpp"
#include <sys/types.h>
namespace asus::a10 {
using IdentitySnapshotRead=ssize_t (*)(int,void*,std::size_t);
// One read-only driver snapshot. Consistent is stable self-reported bytes,
// never a qualified image, exclusive session or DMA permission. Feed raw into
// image::check with independently trusted source/build/context/resources.
image::Capture read_identity_snapshot(int fd,IdentitySnapshotRead reader=nullptr) noexcept;
}
