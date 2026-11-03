// Test-only runtime: synchronous memory fixture, never an ICD/device implementation.
#define CL_TARGET_OPENCL_VERSION 120
#include <CL/cl.h>
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>
#include <type_traits>
struct _cl_context {};
struct _cl_command_queue {};
struct _cl_program {};
struct _cl_mem { std::vector<cl_uint> data; };
struct _cl_kernel { std::string name; cl_mem buffers[3]{}; cl_uint count=0; };
struct _cl_event { int pass; };
namespace {
int calls=0,live=0;
bool injected=false;
int number(const char* name){auto p=std::getenv(name);return p?std::atoi(p):0;}
bool fail(){++calls;if(calls==number("FAIL_AT")){injected=true;return true;}return false;}
template<class T> T create(cl_int* err){if(fail()){*err=CL_OUT_OF_RESOURCES;return nullptr;}*err=CL_SUCCESS;++live;return new typename std::remove_pointer<T>::type;}
template<class T> cl_int release(T v){assert(v);delete v;--live;return CL_SUCCESS;}
cl_int str(const std::string& s,size_t n,void* out,size_t* size){if(fail())return CL_OUT_OF_RESOURCES;if(size)*size=s.size()+1;if(out){assert(n>=s.size()+1);std::memcpy(out,s.c_str(),s.size()+1);}return CL_SUCCESS;}
struct Audit {~Audit(){std::cerr<<"FAKE_AUDIT calls="<<calls<<" live="<<live<<" injected="<<injected<<'\n';if(live)std::abort();}} audit;
}
extern "C" {
void correctness_pass1(const cl_uint*,const cl_uint*,cl_uint*,cl_uint);
void correctness_pass2(const cl_uint*,const cl_uint*,cl_uint*,cl_uint);
cl_int clGetPlatformIDs(cl_uint n,cl_platform_id* out,cl_uint* count){if(fail())return CL_OUT_OF_RESOURCES;if(count)*count=1;if(out){assert(n==1);*out=reinterpret_cast<cl_platform_id>(1);}return CL_SUCCESS;}
cl_int clGetPlatformInfo(cl_platform_id,cl_platform_info field,size_t n,void* out,size_t* size){assert(field==CL_PLATFORM_NAME);return str("fixture",n,out,size);}
cl_int clGetDeviceIDs(cl_platform_id,cl_device_type type,cl_uint n,cl_device_id* out,cl_uint* count){assert(type==CL_DEVICE_TYPE_ACCELERATOR);if(fail())return CL_OUT_OF_RESOURCES;auto total=number("DUPLICATE")?2U:1U;if(count)*count=total;if(out){assert(n==total);for(unsigned i=0;i<n;++i)out[i]=reinterpret_cast<cl_device_id>(size_t(i+1));}return CL_SUCCESS;}
cl_int clGetDeviceInfo(cl_device_id,cl_device_info f,size_t n,void* out,size_t* size){if(f==CL_DEVICE_PROFILING_TIMER_RESOLUTION){if(fail())return CL_OUT_OF_RESOURCES;assert(n==sizeof(size_t));*static_cast<size_t*>(out)=1;return CL_SUCCESS;}return str(f==CL_DEVICE_NAME?"fixture-device":"fixture-driver",n,out,size);}
cl_context clCreateContext(const cl_context_properties*,cl_uint n,const cl_device_id*,void(CL_CALLBACK*)(const char*,const void*,size_t,void*),void*,cl_int* e){assert(n==1);return create<cl_context>(e);}
cl_command_queue clCreateCommandQueue(cl_context,cl_device_id,cl_command_queue_properties p,cl_int* e){assert(p==CL_QUEUE_PROFILING_ENABLE);return create<cl_command_queue>(e);}
cl_program clCreateProgramWithBinary(cl_context,cl_uint n,const cl_device_id*,const size_t* lengths,const unsigned char** bins,cl_int* status,cl_int* e){assert(n==1 && lengths[0] && bins[0]);*status=number("BAD_BINARY")?CL_INVALID_BINARY:CL_SUCCESS;return create<cl_program>(e);}
cl_int clBuildProgram(cl_program,cl_uint,const cl_device_id*,const char*,void(CL_CALLBACK*)(cl_program,void*),void*){return fail()?CL_BUILD_PROGRAM_FAILURE:CL_SUCCESS;}
cl_int clGetProgramBuildInfo(cl_program,cl_device_id,cl_program_build_info,size_t n,void* out,size_t* size){return str("fixture build failure",n,out,size);}
cl_kernel clCreateKernel(cl_program,const char* name,cl_int* e){auto k=create<cl_kernel>(e);if(k)k->name=name;return k;}
cl_mem clCreateBuffer(cl_context,cl_mem_flags,size_t n,void* host,cl_int* e){assert(!host);auto m=create<cl_mem>(e);if(m){assert(n%sizeof(cl_uint)==0);m->data.resize(n/sizeof(cl_uint));}return m;}
cl_int clEnqueueWriteBuffer(cl_command_queue,cl_mem m,cl_bool block,size_t off,size_t n,const void* source,cl_uint waits,const cl_event*,cl_event*){assert(block && !waits && off+n<=m->data.size()*sizeof(cl_uint));if(fail())return CL_OUT_OF_RESOURCES;std::memcpy(reinterpret_cast<unsigned char*>(m->data.data())+off,source,n);return CL_SUCCESS;}
cl_int clSetKernelArg(cl_kernel k,cl_uint index,size_t n,const void* value){if(fail())return CL_OUT_OF_RESOURCES;assert(index<4);if(index<3){assert(n==sizeof(cl_mem));std::memcpy(&k->buffers[index],value,n);}else{assert(n==sizeof(cl_uint));std::memcpy(&k->count,value,n);}return CL_SUCCESS;}
cl_int clEnqueueNDRangeKernel(cl_command_queue,cl_kernel k,cl_uint dim,const size_t* off,const size_t* global,const size_t* local,cl_uint waits,const cl_event* deps,cl_event* result){assert(dim==1 && !off && *global==1 && *local==1);int pass=k->name=="correctness_pass1"?1:2;if(pass==1)assert(waits==0);else assert(waits==1 && deps[0]->pass==1);if(fail())return CL_OUT_OF_RESOURCES;for(auto b:k->buffers)assert(b && b->data.size()==size_t(k->count));auto a=reinterpret_cast<cl_uint*>(k->buffers[0]->data.data());auto b=reinterpret_cast<cl_uint*>(k->buffers[1]->data.data());auto out=reinterpret_cast<cl_uint*>(k->buffers[2]->data.data());if(pass==1)correctness_pass1(a,b,out,k->count);else correctness_pass2(a,b,out,k->count);*result=new _cl_event{pass};++live;return CL_SUCCESS;}
cl_int clEnqueueReadBuffer(cl_command_queue,cl_mem m,cl_bool block,size_t off,size_t n,void* out,cl_uint waits,const cl_event* deps,cl_event*){assert(block && waits==1 && deps[0]->pass==2 && off+n<=m->data.size()*sizeof(cl_uint));if(fail())return CL_EXEC_STATUS_ERROR_FOR_EVENTS_IN_WAIT_LIST;std::memcpy(out,reinterpret_cast<unsigned char*>(m->data.data())+off,n);if(number("CORRUPT"))static_cast<unsigned char*>(out)[0]^=1;return CL_SUCCESS;}
cl_int clGetEventProfilingInfo(cl_event e,cl_profiling_info field,size_t n,void* out,size_t*) {
  assert(n==sizeof(cl_ulong) && out);
  if(fail())return CL_PROFILING_INFO_NOT_AVAILABLE;
  cl_ulong start=e->pass==1?100:250, end=e->pass==1?200:450;
  if(number("BAD_TIME")==1)end=start;
  if(number("BAD_TIME")==2)end=start-1;
  if(number("BAD_TIME")==3 && e->pass==2)start=150;
  *static_cast<cl_ulong*>(out)=field==CL_PROFILING_COMMAND_START?start:end;
  return CL_SUCCESS;
}
cl_int clFinish(cl_command_queue){return fail()?CL_OUT_OF_RESOURCES:CL_SUCCESS;}
cl_int clReleaseContext(cl_context v){return release(v);}
cl_int clReleaseCommandQueue(cl_command_queue v){return release(v);}
cl_int clReleaseProgram(cl_program v){return release(v);}
cl_int clReleaseKernel(cl_kernel v){return release(v);}
cl_int clReleaseMemObject(cl_mem v){return release(v);}
cl_int clReleaseEvent(cl_event v){return release(v);}
}
