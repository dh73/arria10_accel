"""Width-only derivative of the qualified single-beat adapter."""
import argparse,hashlib
from pathlib import Path
SOURCE_SHA = "0e689ceb6754adeb0635614fe4d451d42b4d8d828101c006cb7ab63f5ce26bbf"
def derive(raw):
    if hashlib.sha256(raw).hexdigest()!=SOURCE_SHA: raise ValueError('source identity mismatch')
    s=raw.decode().replace('module kernel_ddr_adapter #(', 'module kernel_ddr_width_adapter #(\n  parameter int DATA_W = 64,')
    for name in ['k_writedata','k_readdata','cmd_writedata']:
        s=s.replace('[63:0] '+name,'[DATA_W-1:0] '+name)
    for name in ['k_byteenable','cmd_byteenable']:
        s=s.replace('[7:0] '+name,'[DATA_W/8-1:0] '+name)
    s=s.replace('64 * cmd_address[cmd_rd_q][5:3] +: 64','8 * (cmd_address[cmd_rd_q] & 35\'d63) +: DATA_W')
    s=s.replace('8 * cmd_address[cmd_rd_q][5:3] +: 8', '(cmd_address[cmd_rd_q] & 35\'d63) +: DATA_W/8')
    s=s.replace('64 * read_address[read_rd_q][5:3] +: 64', '8 * (read_address[read_rd_q] & 35\'d63) +: DATA_W')
    s=s.replace("k_address[2:0] != 3'b0", "(k_address % (DATA_W/8)) != 0")
    s=s.replace('k_address[2:0] == 0', '(k_address % (DATA_W/8)) == 0')
    s=s.replace('  initial begin', '  initial begin\n    if (!(DATA_W==64 || DATA_W==128 || DATA_W==256 || DATA_W==512))\n      $fatal(1, "unsupported port width");')
    return s
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
    with a.out.open('x') as f:f.write(derive(a.source.read_bytes()))
