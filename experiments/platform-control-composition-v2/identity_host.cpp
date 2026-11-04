#include "shell_identity_v1.hpp"
#include "composition_build.hpp"
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
namespace im=asus::a10::image;namespace kn=asus::a10::kernel;
void need(bool v,const char*s){if(!v)throw std::runtime_error(s);}
std::string hex(const im::Digest& d){std::string s;const char*h="0123456789abcdef";for(auto i=d.rbegin();i!=d.rend();++i){s+=h[*i>>4];s+=h[*i&15];}return s;}
struct Transcript:im::Reader{
 std::array<std::uint32_t,72> words{};unsigned n=0;
 im::Reply read32(im::Request r)noexcept override{
  unsigned at=n++;unsigned offset=at<6?at*4:(at==6||at==71?24:(at-7)*4);
  if(at>=72||r.offset!=offset)return {r,false,0};
  return {r,true,words[at]};
 }
};
int main(int argc,char**argv){try{
 need(argc==3,"usage --emit or --check path");
 need(kn::generated_abi().validation()==kn::SourceValidation::Reextracted,"requires actual reextracted source");
 need(kn::generated_abi().kernel(0).name=="stream_copy512"&&kn::generated_abi().kernel(1).name=="stream_triad512","wrong source profile");
 for(unsigned k=0;k<2;k++)need(kn::generated_abi().kernel(k).completion_accounting==kn::CompletionAccounting::DelayedSnapshotV1,"uncorrected source");
 if(std::string(argv[1])=="--emit"){
  std::ofstream f(argv[2]);need(bool(f),"params open");
  f<<"localparam logic [255:0] ID_SOURCE=256'h"<<hex(kn::generated_abi().contract_sha256())<<";\nlocalparam logic [255:0] ID_BUILD=256'h"<<hex(composition_build)<<";\n";
  need(bool(f),"params write");return 0;
 }
 need(std::string(argv[1])=="--check","unknown command");Transcript t;std::ifstream f(argv[2]);need(bool(f),"transcript open");
 for(auto&w:t.words){std::string s;need(bool(f>>s)&&s.size()==8,"transcript length");w=0;for(char c:s){int d=c>='0'&&c<='9'?c-'0':c>='a'&&c<='f'?c-'a'+10:-1;need(d>=0,"nonhex transcript");w=(w<<4)|unsigned(d);}}
 std::string extra;need(!(f>>extra),"extra transcript data");
 im::Cursor cursor(90);auto captured=im::capture(t,cursor);need(captured.code==im::Code::Consistent&&t.n==72,"capture failed");
 im::Expected expected{composition_build,{2,256,256},{0x80000000u,0,512}};im::Context context{{1,2,3,4},9};
 std::vector<im::Resource> resources{{2,32768},{0x80000000u,512}};
 auto report=im::check(captured.raw,kn::generated_abi(),expected,context,resources);
 need(report.code==im::Code::Consistent,"source build range context mismatch");
 auto h=report.observed.health;
 need(h.valid&&h.fault&&!h.launch_permit&&!h.host_submit_permit&&h.address_valid&&h.address==0x10000000100ull&&h.adapter_code==0x80,"fault diagnosis mismatch");
 auto bad=expected;bad.build[0]^=1;need(im::check(captured.raw,kn::generated_abi(),bad,context,resources).code==im::Code::BuildMismatch,"build negative failed");
 auto stale=context;stale.epoch++;need(im::check(captured.raw,kn::generated_abi(),expected,stale,resources).code==im::Code::StaleContext,"context negative failed");
 auto corrupt=captured.raw;corrupt.words[8]^=1;need(im::check(corrupt,kn::generated_abi(),expected,context,resources).code==im::Code::SourceMismatch,"source negative failed");
 std::cout<<"COMPOSITION_RTL_HOST_DIAGNOSIS_PASS address=0x10000000100 reads=72 source=reextracted negatives=3\n";
}catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 1;}}
