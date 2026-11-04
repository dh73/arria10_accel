task platform_single_msi(input integer phase);
 reg [2:0] completion;reg [31:0] capability;reg [15:0] control;
 begin
  ebfm_cfgrd_wait(1,0,0,32'h50,4,32'h1f004,completion);
  if(completion!==0)$fatal(1,"MSI_CONFIG_READ_FAILED");
  capability=shmem_read(32'h1f004,4);control=capability[31:16];
  // Linux pci_enable_msi selects one message: MME=0, enable=1.
  control[6:4]=0;control[0]=1;
  ebfm_cfgwr_imm_wait(1,0,0,32'h50,4,{control,capability[15:0]},completion);
  if(completion!==0)$fatal(1,"MSI_CONFIG_ENABLE_FAILED");
  ebfm_cfgwr_imm_wait(1,0,0,32'h54,4,32'h1f000,completion);
  if(completion!==0)$fatal(1,"MSI_CONFIG_ADDRESS_FAILED");
  if(control[7])begin
   ebfm_cfgwr_imm_wait(1,0,0,32'h58,4,0,completion);
   if(completion!==0)$fatal(1,"MSI_CONFIG_UPPER_FAILED");
  end
  ebfm_cfgwr_imm_wait(1,0,0,control[7]?32'h5c:32'h58,4,32'hb040+phase,completion);
  if(completion!==0)$fatal(1,"MSI_CONFIG_DATA_FAILED");
  ebfm_cfgrd_wait(1,0,0,32'h50,4,32'h1f004,completion);
  capability=shmem_read(32'h1f004,4);
  if(completion!==0 || capability[22:20]!==0 || capability[16]!==1)$fatal(1,"MSI_MODE_READBACK");
  shmem_write(32'h1f000,32'hdeadbeef,4);
 end
endtask
task platform_wait_msi(input integer phase,input integer status_base);
 reg [31:0] data;
 begin
  data=shmem_read(32'h1f000,4);
  while(data===32'hdeadbeef)begin #10;data=shmem_read(32'h1f000,4);end
  if(data!==32'hb040+phase)$fatal(1,"MSI_PAYLOAD phase=%0d actual=%h",phase,data);
  if(shmem_read(status_base+4,4)!==1)$fatal(1,"MSI_BEFORE_FINAL_STATUS");
  $display("PLATFORM_SINGLE_MSI_PASS phase=%0d data=%h",phase,data);
 end
endtask
