#define CL_TARGET_OPENCL_VERSION 120
#include <CL/cl.h>
#include "asus_a10/workload_reference.hpp"
#include <algorithm>
#include <cctype>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
void check(cl_int status, const char* operation) {
  if (status != CL_SUCCESS)
    throw std::runtime_error(std::string(operation)+": OpenCL status "+std::to_string(status));
}
template<class T, cl_int (*Release)(T)> struct Owned {
  T value = nullptr;
  Owned() = default;
  Owned(const Owned&) = delete;
  Owned& operator=(const Owned&) = delete;
  ~Owned() { if (value) Release(value); }
};
using Context = Owned<cl_context, clReleaseContext>;
using Queue = Owned<cl_command_queue, clReleaseCommandQueue>;
using Program = Owned<cl_program, clReleaseProgram>;
using Kernel = Owned<cl_kernel, clReleaseKernel>;
using Buffer = Owned<cl_mem, clReleaseMemObject>;
using Event = Owned<cl_event, clReleaseEvent>;
std::string platform_name(cl_platform_id p) {
  size_t n=0; check(clGetPlatformInfo(p,CL_PLATFORM_NAME,0,nullptr,&n),"platform size");
  std::vector<char> s(n); check(clGetPlatformInfo(p,CL_PLATFORM_NAME,n,s.data(),nullptr),"platform name");
  return std::string(s.data());
}
std::string device_string(cl_device_id d, cl_device_info field) {
  size_t n=0; check(clGetDeviceInfo(d,field,0,nullptr,&n),"device string size");
  std::vector<char> s(n); check(clGetDeviceInfo(d,field,n,s.data(),nullptr),"device string");
  return std::string(s.data());
}
cl_device_id select_device(const std::string& platform, const std::string& name) {
  cl_uint n=0; check(clGetPlatformIDs(0,nullptr,&n),"platform count");
  std::vector<cl_platform_id> ps(n); check(clGetPlatformIDs(n,ps.data(),nullptr),"platforms");
  cl_device_id selected=nullptr;
  for (auto p:ps) {
    if (platform_name(p)!=platform) continue;
    cl_uint count=0; auto status=clGetDeviceIDs(p,CL_DEVICE_TYPE_ACCELERATOR,0,nullptr,&count);
    if (status==CL_DEVICE_NOT_FOUND) continue;
    check(status,"accelerator count");
    std::vector<cl_device_id> ds(count);
    check(clGetDeviceIDs(p,CL_DEVICE_TYPE_ACCELERATOR,count,ds.data(),nullptr),"accelerators");
    for (auto d:ds) if (device_string(d,CL_DEVICE_NAME)==name) {
      if (selected) throw std::runtime_error("Ambiguous accelerator identity");
      selected=d;
    }
  }
  if (!selected) throw std::runtime_error("Exact accelerator identity not found");
  auto identity=platform+" "+name;
  std::transform(identity.begin(),identity.end(),identity.begin(),[](unsigned char c){return std::tolower(c);});
  for (auto word:{"emulator","simulator","simulation"})
    if (identity.find(word)!=std::string::npos) throw std::runtime_error("Nonphysical identity refused");
  return selected;
}
void run(cl_context context, cl_command_queue queue, cl_kernel first, cl_kernel second, cl_uint n) {
  std::vector<cl_uint> a(n),b(n),out(n,0xa5a5a5a5U);
  cl_uint state=0x6d2b79f5U ^ n;
  auto random=[&](){state^=state<<13;state^=state>>17;state^=state<<5;return state;};
  for(cl_uint i=0;i<n;++i){a[i]=random();b[i]=random()^(i*17U);}
  const size_t bytes=size_t(n)*sizeof(cl_uint);
  Buffer ba,bb,tmp,bo;cl_int error=0;
  for(auto entry:{&ba,&bb,&tmp,&bo}) {
    entry->value=clCreateBuffer(context,CL_MEM_READ_WRITE,bytes,nullptr,&error);check(error,"buffer");
  }
  check(clEnqueueWriteBuffer(queue,ba.value,CL_TRUE,0,bytes,a.data(),0,nullptr,nullptr),"write a");
  check(clEnqueueWriteBuffer(queue,bb.value,CL_TRUE,0,bytes,b.data(),0,nullptr,nullptr),"write b");
  check(clEnqueueWriteBuffer(queue,bo.value,CL_TRUE,0,bytes,out.data(),0,nullptr,nullptr),"poison output");
  cl_mem inputs1[]={ba.value,bb.value,tmp.value},inputs2[]={tmp.value,bb.value,bo.value};
  for(cl_uint i=0;i<3;++i){check(clSetKernelArg(first,i,sizeof(cl_mem),&inputs1[i]),"pass1 arg");
                          check(clSetKernelArg(second,i,sizeof(cl_mem),&inputs2[i]),"pass2 arg");}
  check(clSetKernelArg(first,3,sizeof(n),&n),"pass1 count");
  check(clSetKernelArg(second,3,sizeof(n),&n),"pass2 count");
  Event e1,e2;const size_t one=1;
  check(clEnqueueNDRangeKernel(queue,first,1,nullptr,&one,&one,0,nullptr,&e1.value),"pass1 enqueue");
  check(clEnqueueNDRangeKernel(queue,second,1,nullptr,&one,&one,1,&e1.value,&e2.value),"pass2 enqueue");
  check(clEnqueueReadBuffer(queue,bo.value,CL_TRUE,0,bytes,out.data(),1,&e2.value,nullptr),"readback");
  check(clFinish(queue),"finish");
  for(cl_uint i=0;i<n;++i) if(out[i]!=asus_a10::workload_reference(a[i],b[i],i))
    throw std::runtime_error("Mismatch count="+std::to_string(n)+" index="+std::to_string(i));
  std::cout<<"OPENCL_DEVICE_DATA_PASS count="<<n<<'\n';
}
}
int main(int argc,char** argv) {
  if(argc!=5 || std::string(argv[1])!="--physical") {
    std::cerr<<"usage: "<<argv[0]<<" --physical BINARY EXACT_PLATFORM_NAME EXACT_DEVICE_NAME\n";return 64;
  }
  try {
    std::ifstream input(argv[2],std::ios::binary);
    if(!input) throw std::runtime_error("Cannot open device binary");
    std::vector<unsigned char> binary((std::istreambuf_iterator<char>(input)),{});
    if(input.bad() || binary.empty()) throw std::runtime_error("Empty or unreadable device binary");
    auto device=select_device(argv[3],argv[4]);cl_int error=0;
    std::cout<<"platform="<<argv[3]<<"\ndevice="<<argv[4]<<"\ndriver="<<device_string(device,CL_DRIVER_VERSION)<<'\n';
    Context context;context.value=clCreateContext(nullptr,1,&device,nullptr,nullptr,&error);check(error,"context");
    Queue queue;queue.value=clCreateCommandQueue(context.value,device,0,&error);check(error,"queue");
    Program program;const unsigned char* data=binary.data();size_t length=binary.size();cl_int binary_status=0;
    program.value=clCreateProgramWithBinary(context.value,1,&device,&length,&data,&binary_status,&error);
    check(error,"program binary");check(binary_status,"device binary status");
    error=clBuildProgram(program.value,1,&device,nullptr,nullptr,nullptr);
    if(error!=CL_SUCCESS) {
      size_t length_log=0;
      if(clGetProgramBuildInfo(program.value,device,CL_PROGRAM_BUILD_LOG,0,nullptr,&length_log)==CL_SUCCESS && length_log) {
        std::vector<char> log(length_log);
        if(clGetProgramBuildInfo(program.value,device,CL_PROGRAM_BUILD_LOG,length_log,log.data(),nullptr)==CL_SUCCESS)
          std::cerr.write(log.data(),static_cast<std::streamsize>(length_log));
      }
      check(error,"build binary");
    }
    Kernel first,second;
    first.value=clCreateKernel(program.value,"correctness_pass1",&error);check(error,"pass1 kernel");
    second.value=clCreateKernel(program.value,"correctness_pass2",&error);check(error,"pass2 kernel");
    for(cl_uint n:{1U,3U,17U,257U,4093U,65537U,1000003U})run(context.value,queue.value,first.value,second.value,n);
    return 0;
  } catch(const std::exception& e){std::cerr<<"OpenCL failure: "<<e.what()<<'\n';return 1;}
}
