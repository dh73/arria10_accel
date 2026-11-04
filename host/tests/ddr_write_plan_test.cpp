#include "ddr_write_plan.hpp"
#include <algorithm>
#include <array>
#include <cassert>
#include <cstring>
#include <iostream>
#include <limits>
using namespace asus::a10::memory;
int main(){
  std::array<unsigned char,128> source;
  for(unsigned i=0;i<source.size();++i)source[i]=static_cast<unsigned char>(i*37+9);
  unsigned cases=0;
  for(unsigned address=0;address<=128;++address)for(unsigned size=0;size<=128-address;++size){
    auto p=plan_write(128,address,source.data(),size);
    assert(p.valid&&p.count<=3);
    std::array<unsigned char,128> actual,expected;
    actual.fill(0xa5);expected=actual;
    std::memcpy(expected.data()+address,source.data(),size);
    std::size_t consumed=0,bulk=0,edges=0;
    for(std::size_t i=0;i<p.count;++i){
      auto s=p.segments[i];assert(s.source_offset==consumed&&s.bytes);
      assert(!(s.device_address&3));
      if(s.route==WriteRoute::Dma){
        assert(!(s.bytes&3)&&!s.mask&&s.device_address==address+consumed);
        std::memcpy(actual.data()+s.device_address,source.data()+s.source_offset,s.bytes);bulk+=s.bytes;
      }else{
        ++edges;assert(s.bytes<=3&&s.mask&&s.mask<16);
        unsigned selected=0;
        for(unsigned lane=0;lane<4;++lane)if(s.mask&(1u<<lane)){
          assert(s.device_address+lane==address+consumed+selected);
          actual[s.device_address+lane]=static_cast<unsigned char>(s.data>>(8*lane));++selected;
        }
        assert(selected==s.bytes);
      }
      consumed+=s.bytes;
    }
    assert(consumed==size&&actual==expected&&edges<=2);
    const auto head=(address&3)?std::min(size,4-(address&3)):0;
    assert(bulk==((size-head)&~3u));++cases;
  }
  assert(plan_write(128,128,nullptr,0).valid);
  assert(!plan_write(128,0,nullptr,1).valid);
  assert(!plan_write(127,0,source.data(),1).valid);
  assert(!plan_write(128,127,source.data(),2).valid);
  assert(!plan_write(128,std::numeric_limits<std::uint64_t>::max(),source.data(),1).valid);
  assert(!plan_write(128,0,source.data(),std::numeric_limits<std::size_t>::max()).valid);
  auto last=plan_write(0x80000000ULL,0x7fffffff,source.data(),1);
  assert(last.valid&&last.count==1&&last.segments[0].mask==8);
  std::cout<<"DDR_WRITE_PLAN_PASS cases="<<cases<<" exact_bytes neighbors maximal_bulk bounds\n";
}
