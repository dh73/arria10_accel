#include "generated_kernel_abi.hpp"
#include <cassert>
#include <iostream>
using namespace asus::a10::kernel;
int main(){
 const auto& abi=generated_abi();unsigned checked=0;
 for(std::size_t k=0;k<abi.kernel_count();++k){
  const auto& kernel=abi.kernel(k);Launch::NamedArguments args;
  for(const auto& a:kernel.arguments)
   args.emplace_back(a.name,a.memory_object?a.alignment_bytes:1);
  assert(Launch::make(kernel.name,args));
  for(std::size_t i=0;i<args.size();++i){
   const auto& a=kernel.arguments[i];
   if(a.memory_object && a.alignment_bytes>1){
    auto bad=args;bad[i].second+=1;assert(!Launch::make(kernel.name,bad));++checked;
   }
  }
 }
 assert(checked==5); // copy input/output and triad a/b/output
 std::cout<<"GENERATED_ALIGNMENT_PASS pointers="<<checked<<"\n";
}
