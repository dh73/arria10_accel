#include "adapter.hpp"
#include "driver_receipt.hpp"
#include <array>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <stdexcept>
using namespace asus::a10;
using namespace asus::a10::mmd;
#define CHECK(x) do { if (!(x)) { std::cerr << __LINE__ << ": " #x << '\n'; std::abort(); } } while (false)
struct Fake : Transport {
  std::array<unsigned char,64> memory{};
  Submission outcome{Submission::Accepted};
  bool qualified{true}, early{}, throws{}, closed{};
  std::mutex gate;std::condition_variable cv;
  bool pause_submit=false,entered=false,release_submit=false;
  Request request{};
  Completion completion;
  bool qualified_and_owned() const noexcept override { return qualified; }
  int info(aocl_mmd_info_t id,size_t n,void* out,size_t* size) override {
    if(id!=AOCL_MMD_MEMORY_INTERFACE) return -1;
    if(size) *size=sizeof(int);
    if(!out || n<sizeof(int)) return -1;
    int i=7; std::memcpy(out,&i,sizeof(i)); return 0;
  }
  int blocking(const Request& r) noexcept override {
    if(r.interface_id!=7 || r.source_offset+r.size>memory.size() || r.destination_offset+r.size>memory.size()) return -1;
    if(r.kind==Kind::Read) std::memcpy(r.staging,memory.data()+r.source_offset,r.size);
    if(r.kind==Kind::Write) std::memcpy(memory.data()+r.destination_offset,r.staging,r.size);
    if(r.kind==Kind::Copy) std::memmove(memory.data()+r.destination_offset,memory.data()+r.source_offset,r.size);
    return 0;
  }
  Submission submit(const Request& r,Completion c) override {
    request=r; completion=std::move(c);
    if(pause_submit) {
      std::unique_lock<std::mutex> lock(gate);entered=true;cv.notify_all();
      cv.wait(lock,[&]{return release_submit;});
    }
    if(throws) throw std::runtime_error("unknown launch");
    if(early) finish();
    return outcome;
  }
  void finish(dma::DrainEvidence drain=dma::DrainEvidence::PerOperation) {
    int s=blocking(request); completion(request.ticket,s,drain);
  }
  int yield() override { return 0; }
  int close() override { closed=true; return 0; }
  int interrupt_handler(aocl_mmd_interrupt_handler_fn,void*) override { return -1; }
};
struct Factory : Backend {
  std::shared_ptr<Fake> device=std::make_shared<Fake>();
  std::vector<std::string> discover() override { return {"explicit-test"}; }
  std::shared_ptr<Transport> open(const std::string& name) override { return name=="explicit-test"?device:nullptr; }
};
struct State { int calls{}, status{}, handle{}; bool reenter{}; };
void callback(int h,void* context,aocl_mmd_op_t token,int s) {
  auto& state=*static_cast<State*>(context); ++state.calls; state.status=s; CHECK(h==state.handle);
  CHECK(token==&state);
  if(state.reenter) {
    state.reenter=false;
    CHECK(aocl_mmd_close(h)<0);
    CHECK(aocl_mmd_copy(h,token,1,7,0,1)==0);
  }
}
int main() {
  int count=-1; size_t size=0;
  CHECK(aocl_mmd_get_offline_info(AOCL_MMD_NUM_BOARDS,sizeof(count),&count,&size)==0 && count==0);
  CHECK(aocl_mmd_open("anything")<0);
  CHECK(aocl_mmd_close(123)<0 && aocl_mmd_yield(123)<0);
  CHECK(aocl_mmd_read(123,nullptr,1,nullptr,7,0)<0);
  auto factory=std::make_shared<Factory>(); CHECK(install_backend(factory));
  factory->device->qualified=false; CHECK(aocl_mmd_open("explicit-test")<0);
  factory->device=std::make_shared<Fake>(); auto fake=factory->device;
  int h=aocl_mmd_open("explicit-test"); CHECK(h>=0); CHECK(!install_backend(nullptr));
  CHECK(aocl_mmd_get_offline_info(AOCL_MMD_NUM_BOARDS,1,&count,&size)<0 && size==sizeof(int));
  State state; state.handle=h;
  char input[]="test", output[5]{};
  CHECK(aocl_mmd_write(h,&state,5,input,7,0)<0); // handler required
  CHECK(aocl_mmd_set_status_handler(h,callback,&state)==0);
  CHECK(aocl_mmd_write(h,nullptr,5,input,7,0)==0); CHECK(flush_ready(h));
  CHECK(aocl_mmd_read(h,nullptr,5,output,7,0)==0); CHECK(flush_ready(h));
  CHECK(std::memcmp(input,output,5)==0 && state.calls==0);
  CHECK(aocl_mmd_read(h,&state,5,output,7,0)==0);
  CHECK(aocl_mmd_read(h,&state,5,output,7,0)<0); // token reserved
  CHECK(aocl_mmd_close(h)<0 && !fake->closed);
  fake->finish(dma::DrainEvidence::None); CHECK(flush_ready(h)); CHECK(state.calls==0);
  fake->finish(); CHECK(flush_ready(h)); CHECK(state.calls==1);
  fake->completion(fake->request.ticket,0,dma::DrainEvidence::PerOperation); CHECK(flush_ready(h)); CHECK(state.calls==1); // duplicate
  CHECK(aocl_mmd_write(h,&state,5,input,7,8)==0);
  input[0]='X'; fake->finish(); CHECK(flush_ready(h));
  CHECK(fake->memory[8]=='t' && state.calls==2); // staged write owns original bytes
  CHECK(aocl_mmd_read(h,nullptr,5,output,7,SIZE_MAX)<0);
  // Error receipts release adapter staging but must not copy read data to caller.
  const int prior_calls=state.calls;
  std::memset(output,'?',sizeof(output));
  CHECK(aocl_mmd_read(h,&state,5,output,7,0)==0);
  DriverReceiptCompletion gate(42,fake->request.ticket,fake->completion);
  DmaReceipt receipt;receipt.state=DmaReceiptState::Drained;
  receipt.submitted=41;receipt.completed=41;
  CHECK(gate.observe(receipt)==DriverReceiptCompletion::Result::Retained);
  receipt.state=DmaReceiptState::Pending;receipt.submitted=42;
  CHECK(gate.observe(receipt)==DriverReceiptCompletion::Result::Retained);
  CHECK(flush_ready(h));CHECK(state.calls==prior_calls);
  receipt.state=DmaReceiptState::Drained;receipt.completed=42;receipt.result=-125;
  CHECK(gate.observe(receipt)==DriverReceiptCompletion::Result::Delivered);
  CHECK(gate.observe(receipt)==DriverReceiptCompletion::Result::AlreadyDelivered);
  CHECK(flush_ready(h));CHECK(state.calls==prior_calls+1 && state.status==-125);
  for(char c:output)CHECK(c=='?');
  fake->early=true; state.reenter=true;
  CHECK(aocl_mmd_read(h,&state,1,output,7,0)==0); CHECK(flush_ready(h)); CHECK(state.calls==5);
  fake->early=false; fake->outcome=Submission::NotAccepted;
  CHECK(aocl_mmd_write(h,&state,1,input,7,0)<0); CHECK(flush_ready(h)); CHECK(state.calls==5);
  fake->throws=true;
  CHECK(aocl_mmd_read(h,&state,1,output,7,0)<0); CHECK(flush_ready(h));
  CHECK(aocl_mmd_close(h)<0 && !fake->closed);
  CHECK(aocl_mmd_write(h,nullptr,1,input,7,0)<0); // offline
  fake->finish(); CHECK(flush_ready(h)); CHECK(state.calls==5); // orphan: never callback
  CHECK(aocl_mmd_close(h)==0 && fake->closed);
  CHECK(aocl_mmd_close(h)<0); CHECK(install_backend(nullptr));
  // Quiesce races an actual adapter-to-transport handoff. No timed sleeps.
  factory=std::make_shared<Factory>();CHECK(install_backend(factory));fake=factory->device;
  h=aocl_mmd_open("explicit-test");CHECK(h>=0);state={};state.handle=h;
  CHECK(aocl_mmd_set_status_handler(h,callback,&state)==0);
  fake->pause_submit=true;int submitted=-99;
  std::thread submitter([&]{submitted=aocl_mmd_read(h,&state,1,output,7,0);});
  {std::unique_lock<std::mutex> lock(fake->gate);fake->cv.wait(lock,[&]{return fake->entered;});}
  CHECK(!quiesce_submissions(h,0));CHECK(quiesce_submissions(h,-7));
  dma::Snapshot snapshot;CHECK(submission_snapshot(h,snapshot));
  CHECK(!snapshot.submissions_settled&&snapshot.prepared==1);
  CHECK(aocl_mmd_write(h,nullptr,1,input,7,0)<0);
  {std::lock_guard<std::mutex> lock(fake->gate);fake->release_submit=true;fake->cv.notify_all();}
  submitter.join();CHECK(submitted==0);CHECK(submission_snapshot(h,snapshot));
  CHECK(snapshot.submissions_settled&&snapshot.accepted_debt==1);
  CHECK(flush_ready(h)&&state.calls==0);CHECK(aocl_mmd_close(h)<0);
  fake->finish();CHECK(flush_ready(h));CHECK(state.calls==1&&state.status==-7);
  CHECK(aocl_mmd_close(h)==0);CHECK(!submission_snapshot(h,snapshot));
  CHECK(install_backend(nullptr));
  std::cout << "A10_MMD_ADAPTER_HOST_PASS prepared_quiesce_race=1 drain_required=1\n";
}
