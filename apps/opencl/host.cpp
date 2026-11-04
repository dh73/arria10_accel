#define CL_TARGET_OPENCL_VERSION 120
#include <CL/cl.h>
#include "asus_a10/workload_reference.hpp"
#include <algorithm>
#include <cctype>
#include <charconv>
#include <limits>
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
struct Timing { cl_ulong start, end; };
Timing timing(cl_event event, size_t resolution) {
  Timing t{};
  check(clGetEventProfilingInfo(event,CL_PROFILING_COMMAND_START,sizeof(t.start),&t.start,nullptr),"profile start");
  check(clGetEventProfilingInfo(event,CL_PROFILING_COMMAND_END,sizeof(t.end),&t.end,nullptr),"profile end");
  if (t.end <= t.start) throw std::runtime_error("Unresolved or reversed event duration");
  if (t.end-t.start < resolution)
    throw std::runtime_error("Event duration below profiling timer resolution; use a larger workload");
  return t;
}
void run(cl_context context, cl_command_queue queue, cl_kernel first, cl_kernel second, cl_uint n, size_t resolution) {
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
  const auto t1=timing(e1.value,resolution),t2=timing(e2.value,resolution);
  if (t2.start<t1.end) throw std::runtime_error("Dependent kernel timestamps overlap");
  const auto elapsed=t2.end-t1.start;
  // Two reads and one write per element, per pass: algorithm traffic only.
  const std::uint64_t algorithm_bytes=std::uint64_t(n)*24;
  std::cout<<"OPENCL_KERNEL_TIMING count="<<n
           <<" pass1_ns="<<(t1.end-t1.start)<<" pass2_ns="<<(t2.end-t2.start)
           <<" span_ns="<<elapsed<<" algorithm_bytes="<<algorithm_bytes
           <<" algorithm_GBps="<<(double(algorithm_bytes)/double(elapsed))<<'\n';
  std::cout<<"OPENCL_DEVICE_DATA_PASS count="<<n<<'\n';
}
void run_stream(cl_context context, cl_command_queue queue, cl_kernel copy,
                cl_kernel triad, cl_uint n, size_t resolution) {
  std::vector<cl_uint> a(n),b(n),out(n);
  for(cl_uint i=0;i<n;++i){a[i]=i*0x9e3779b1U+0x80000000U;b[i]=~(i*17U);}
  const size_t bytes=size_t(n)*sizeof(cl_uint);
  Buffer ba,bb,bo;cl_int error=0;
  for(auto entry:{&ba,&bb,&bo}){
    entry->value=clCreateBuffer(context,CL_MEM_READ_WRITE,bytes,nullptr,&error);check(error,"stream buffer");
  }
  Event upload_a,upload_b;
  check(clEnqueueWriteBuffer(queue,ba.value,CL_TRUE,0,bytes,a.data(),0,nullptr,&upload_a.value),"stream write a");
  check(clEnqueueWriteBuffer(queue,bb.value,CL_TRUE,0,bytes,b.data(),0,nullptr,&upload_b.value),"stream write b");
  cl_mem copy_args[]={ba.value,bo.value},triad_args[]={ba.value,bb.value,bo.value};
  for(cl_uint j=0;j<2;++j)check(clSetKernelArg(copy,j,sizeof(cl_mem),&copy_args[j]),"copy buffer arg");
  check(clSetKernelArg(copy,2,sizeof(n),&n),"copy count");
  for(cl_uint j=0;j<3;++j)check(clSetKernelArg(triad,j,sizeof(cl_mem),&triad_args[j]),"triad buffer arg");
  const cl_uint scale=0xfffffffbU;
  check(clSetKernelArg(triad,3,sizeof(scale),&scale),"triad scale");
  check(clSetKernelArg(triad,4,sizeof(n),&n),"triad count");
  for(int pass=0;pass<2;++pass){
    std::fill(out.begin(),out.end(),0xa5a5a5a5U);
    check(clEnqueueWriteBuffer(queue,bo.value,CL_TRUE,0,bytes,out.data(),0,nullptr,nullptr),"stream poison");
    Event event,download;const size_t one=1;
    check(clEnqueueNDRangeKernel(queue,pass?triad:copy,1,nullptr,&one,&one,0,nullptr,&event.value),"stream enqueue");
    check(clEnqueueReadBuffer(queue,bo.value,CL_TRUE,0,bytes,out.data(),1,&event.value,&download.value),"stream readback");
    check(clFinish(queue),"stream finish");
    for(cl_uint i=0;i<n;++i){
      auto expected=pass?static_cast<cl_uint>(std::uint64_t(a[i])+std::uint64_t(b[i])*scale):a[i];
      if(out[i]!=expected)throw std::runtime_error("Streaming mismatch index="+std::to_string(i));
    }
    const auto t=timing(event.value,resolution),read=timing(download.value,resolution);
    if(read.start<t.end)throw std::runtime_error("Readback timestamps overlap producing kernel");
    const std::uint64_t traffic=std::uint64_t(n)*(pass?12:8);
    std::cout<<"OPENCL_STREAM_DATA_PASS kernel="<<(pass?"triad":"copy")<<" count="<<n
             <<" elapsed_ns="<<(t.end-t.start)<<" algorithm_bytes="<<traffic
             <<" algorithm_GBps="<<(double(traffic)/double(t.end-t.start))<<'\n';
    std::cout<<"OPENCL_TRANSFER_TIMING direction=d2h kernel="<<(pass?"triad":"copy")
             <<" count="<<n<<" bytes="<<bytes<<" elapsed_ns="<<(read.end-read.start)
             <<" payload_GBps="<<(double(bytes)/double(read.end-read.start))<<'\n';
  }
  // Publish upload rates only after both dependent workloads passed readback.
  for(auto event:{upload_a.value,upload_b.value}){
    const auto t=timing(event,resolution);
    std::cout<<"OPENCL_TRANSFER_TIMING direction=h2d count="<<n<<" bytes="<<bytes
             <<" elapsed_ns="<<(t.end-t.start)
             <<" payload_GBps="<<(double(bytes)/double(t.end-t.start))<<'\n';
  }
}
}
int main(int argc,char** argv) {
  if(argc<5 || std::string(argv[1])!="--physical") {
    std::cerr<<"usage: "<<argv[0]<<" --physical BINARY EXACT_PLATFORM_NAME EXACT_DEVICE_NAME [--streaming] [--count N]\n";return 64;
  }
  try {
    bool streaming=false,count_selected=false;
    std::vector<cl_uint> counts{1U,3U,17U,257U,4093U,65537U,1000003U};
    for(int i=5;i<argc;++i){
      const std::string arg=argv[i];
      if(arg=="--streaming" && !streaming)streaming=true;
      else if(arg=="--count" && !count_selected && i+1<argc){
        const std::string text=argv[++i];cl_uint count=0;
        const auto parsed=std::from_chars(text.data(),text.data()+text.size(),count);
        if(parsed.ec!=std::errc{} || parsed.ptr!=text.data()+text.size() || count==0)
          throw std::runtime_error("Count must be a nonzero decimal uint32");
        counts={count};count_selected=true;
      } else throw std::runtime_error("Unknown, duplicate or incomplete option: "+arg);
    }
    std::ifstream input(argv[2],std::ios::binary);
    if(!input) throw std::runtime_error("Cannot open device binary");
    std::vector<unsigned char> binary((std::istreambuf_iterator<char>(input)),{});
    if(input.bad() || binary.empty()) throw std::runtime_error("Empty or unreadable device binary");
    auto device=select_device(argv[3],argv[4]);cl_int error=0;
    std::cout<<"platform="<<argv[3]<<"\ndevice="<<argv[4]<<"\ndriver="<<device_string(device,CL_DRIVER_VERSION)<<'\n';
    size_t timer_resolution=0;
    check(clGetDeviceInfo(device,CL_DEVICE_PROFILING_TIMER_RESOLUTION,sizeof(timer_resolution),&timer_resolution,nullptr),"timer resolution");
    if(!timer_resolution) throw std::runtime_error("Invalid profiling timer resolution");
    std::cout<<"profiling_timer_resolution_ns="<<timer_resolution<<'\n';
    if(streaming){
      cl_uint alignment_bits=0;
      check(clGetDeviceInfo(device,CL_DEVICE_MEM_BASE_ADDR_ALIGN,sizeof(alignment_bits),&alignment_bits,nullptr),"buffer alignment");
      if(alignment_bits<512 || alignment_bits%512)throw std::runtime_error("512-bit buffer alignment not established");
    }
    cl_ulong max_allocation=0,global_memory=0;
    check(clGetDeviceInfo(device,CL_DEVICE_MAX_MEM_ALLOC_SIZE,sizeof(max_allocation),&max_allocation,nullptr),"max allocation");
    check(clGetDeviceInfo(device,CL_DEVICE_GLOBAL_MEM_SIZE,sizeof(global_memory),&global_memory,nullptr),"global memory");
    for(auto n:counts){
      const std::uint64_t bytes=std::uint64_t(n)*sizeof(cl_uint);
      if(bytes>std::numeric_limits<size_t>::max() || bytes>max_allocation ||
         bytes>global_memory/(streaming?3:4))
        throw std::runtime_error("Requested buffers exceed reported device or host address limits");
    }
    std::cout<<"max_allocation_bytes="<<max_allocation<<" global_memory_bytes="<<global_memory<<'\n';
    Context context;context.value=clCreateContext(nullptr,1,&device,nullptr,nullptr,&error);check(error,"context");
    Queue queue;queue.value=clCreateCommandQueue(context.value,device,CL_QUEUE_PROFILING_ENABLE,&error);check(error,"queue");
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
    first.value=clCreateKernel(program.value,streaming?"stream_copy512":"correctness_pass1",&error);check(error,"pass1 kernel");
    second.value=clCreateKernel(program.value,streaming?"stream_triad512":"correctness_pass2",&error);check(error,"pass2 kernel");
    for(cl_uint n:counts){
      if(streaming)run_stream(context.value,queue.value,first.value,second.value,n,timer_resolution);
      else run(context.value,queue.value,first.value,second.value,n,timer_resolution);
    }
    return 0;
  } catch(const std::exception& e){std::cerr<<"OpenCL failure: "<<e.what()<<'\n';return 1;}
}
