#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <vector>
extern "C" void stream_copy512(const void*,void*,std::uint32_t);
extern "C" void stream_triad512(const void*,const void*,void*,std::uint32_t,std::uint32_t);
struct Aligned {
  std::unique_ptr<void,decltype(&std::free)> storage{nullptr,&std::free};
  std::uint32_t *base,*data;
  std::size_t words;
  explicit Aligned(std::size_t n):words(((n+31)/16)*16+32) {
    storage.reset(std::aligned_alloc(64,words*4));
    if(!storage)throw std::bad_alloc();
    base=static_cast<std::uint32_t*>(storage.get());data=base+16;
    for(std::size_t i=0;i<words;++i)base[i]=0xa5a5a5a5U;
  }
  bool guards(std::size_t n) const {
    for(std::size_t i=0;i<16;++i)if(base[i]!=0xa5a5a5a5U)return false;
    for(std::size_t i=n+16;i<words;++i)if(base[i]!=0xa5a5a5a5U)return false;
    return true;
  }
};
int main(){
  std::vector<std::uint32_t> counts;
  for(unsigned i=0;i<=65;++i)counts.push_back(i);
  for(auto n:{257U,4093U,65537U,1000003U})counts.push_back(n);
  for(auto n:counts){
    Aligned a(n),b(n),out(n);std::vector<std::uint32_t> aa(n),bb(n);
    std::uint32_t state=0x7f4a7c15U^n;
    auto random=[&](){state^=state<<13;state^=state>>17;state^=state<<5;return state;};
    for(unsigned i=0;i<n;++i){aa[i]=a.data[i]=random();bb[i]=b.data[i]=random();}
    stream_copy512(a.data,out.data,n);
    for(unsigned i=0;i<n;++i)if(out.data[i]!=aa[i])return 1;
    if(!out.guards(n))return 2;
    for(auto scale:{0U,1U,17U,0x80000000U,0xffffffffU}){
      for(unsigned i=0;i<n;++i)out.data[i]=0xa5a5a5a5U;
      stream_triad512(a.data,b.data,out.data,scale,n);
      for(unsigned i=0;i<n;++i){
        auto expected=static_cast<std::uint32_t>(std::uint64_t(aa[i])+std::uint64_t(bb[i])*scale);
        if(out.data[i]!=expected || a.data[i]!=aa[i] || b.data[i]!=bb[i])return 3;
      }
      if(!a.guards(n)||!b.guards(n)||!out.guards(n))return 4;
    }
  }
  std::cout<<"OPENCL_STREAM_BODY_PASS counts="<<counts.size()<<" kernels=2 scales=5\n";
}
