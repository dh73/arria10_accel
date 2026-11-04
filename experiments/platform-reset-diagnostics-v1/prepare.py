from pathlib import Path
import json,hashlib,argparse
p=argparse.ArgumentParser();p.add_argument('--source',required=True,type=Path);p.add_argument('--out',required=True,type=Path);a=p.parse_args()
a.out.mkdir(exist_ok=False);pins={};outputs={}
def read(name):
 f=a.source/name;pins[str(f.resolve())]=hashlib.sha256(f.read_bytes()).hexdigest();return f.read_text()
def replace(s,old,new):
 assert s.count(old)==1,(old,s.count(old));return s.replace(old,new)
s=read('frontend.sv')
s=replace(s,' input logic memory_ready,',' input logic memory_ready,\n input logic [7:0] reset_diagnostic_status,')
s=replace(s,' wire byte_selected=', ' wire diag_selected=(m_address>=1088 && m_address<1096);\n wire diag_valid,diag_invalid,diag_wait;wire [31:0] diag_data;\n wire byte_selected=')
s=replace(s,'assign m_wait=','assign m_wait=diag_selected?diag_wait:')
s=replace(s,'assign m_valid=','assign m_valid=diag_valid || ')
s=replace(s,'assign m_readdata=','assign m_readdata=diag_valid?diag_data:')
s=replace(s,'assign invalid_access=','assign invalid_access=diag_invalid || ')
s=s.replace('&& !byte_selected;','&& !byte_selected && !diag_selected;')
s=s.replace('&& !byte_selected)rejected_access','&& !byte_selected && !diag_selected)rejected_access')
marker=' ddr_byte_mailbox_verified byte_mailbox('
binding=''' platform_reset_diagnostics reset_diagnostics(
 .clk(kernel_clk),.cold_reset_n(common_cold_reset_n),
 .read(m_read && diag_selected),.write(m_write && diag_selected),
 .address(3'(m_address-1088)),.byteenable(m_mask),.status(reset_diagnostic_status),
 .waitrequest(diag_wait),.readdatavalid(diag_valid),.readdata(diag_data),.invalid_access(diag_invalid));
'''
s=replace(s,marker,binding+marker);outputs['frontend.sv']=s
s=read('platform_control_command_v1.sv')
s=replace(s,' input logic pcie_clk,backend_reset_n,health_valid,',' input logic pcie_clk,backend_reset_n,health_valid,\n input logic [7:0] reset_diagnostic_status,')
s=replace(s,'frontend(\n','frontend(\n .reset_diagnostic_status,\n');outputs['platform_control_command_v1.sv']=s
s=read('full_platform_kernel_control.sv')
s=replace(s,')) control(\n',')) control(\n .reset_diagnostic_status({memory_ready,backend_ecc_interrupt,backend_init_failed,shared_mux_fault,dma_epoch_lost,snapshot_valid,reset_containment_valid,health_valid}),\n')
outputs['full_platform_kernel_control.sv']=s
for name,s in outputs.items():(a.out/name).write_text(s)
(a.out/'result.json').write_text(json.dumps({'state':'prepared_not_qualified','inputs':pins,'outputs':{name:hashlib.sha256(s.encode()).hexdigest() for name,s in outputs.items()},'read_only_bar2_range':[1088,1096],'physical_acceptance':False},indent=2)+'\n')
