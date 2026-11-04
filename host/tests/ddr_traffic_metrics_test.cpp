#include "ddr_traffic_metrics.hpp"
#include <cassert>
#include <limits>
#include <iostream>
using namespace asus::a10::metrics;
int main(){
 Snapshot a{{1,2,3,4},1,{100,10,20,1000,30,9,60},true,false,false};
 Snapshot b=a;b.sequence=3; // missed snapshots do not invalidate cumulative differences
 b.counts={200,35,45,1800,50,39,130};
 auto r=measure(a,b);assert(r&&r->cycles==100&&r->read_bus_bytes_per_cycle==16&&
 r->write_bus_bytes_per_cycle==16&&r->write_payload_bytes_per_cycle==8&&
 r->stall_fraction==0.2L&&!r->read_bus_bytes_per_second);
 r=measure(a,b,150000000.L);assert(r&&*r->read_bus_bytes_per_second==2400000000.L&&
 *r->write_payload_bytes_per_second==1200000000.L);
 for(unsigned mode=0;mode<10;++mode){auto x=b;
  switch(mode){case 0:x.context[0]++;break;case 1:x.sequence=1;break;
   case 2:x.valid=false;break;case 3:x.overflow=true;break;case 4:x.invalid_command=true;break;
   case 5:x.counts[0]=a.counts[0];break;case 6:x.counts[1]=0;break;
   case 7:x.counts[3]=100000;break;case 8:x.counts[4]++;break;case 9:x.counts[5]+=1000;break;}
  assert(!measure(a,x));
 }
 // Responses can belong to reads accepted before the measurement interval.
 auto x=a;x.sequence=2;x.counts[0]++;x.counts[5]++;assert(measure(a,x));
 auto zero=a;zero.counts={};auto huge=zero;huge.sequence=2;
 huge.counts={UINT64_MAX,0,UINT64_MAX/64,UINT64_MAX,0,0,UINT64_MAX/64};
 assert(!measure(zero,huge));huge.counts[3]-=63;assert(measure(zero,huge));
 assert(!measure(a,b,0));assert(!measure(a,b,-1));
 assert(!measure(a,b,std::numeric_limits<long double>::infinity()));
 assert(!measure(a,b,std::numeric_limits<long double>::quiet_NaN()));
 std::cout<<"DDR_METRICS_PASS context overflow atomic_interval payload_vs_bus clock_optional\n";
}
