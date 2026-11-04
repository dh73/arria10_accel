"""Correct the repeated-workload fixture without modifying captured runs."""
from pathlib import Path
import argparse

def repair_bfm(text):
    if 'cntlr_base_addr+20, total_descriptors_m1, 4);' in text:
        raise ValueError('ring configuration already present')
    for direction in ('Rd', 'Wr'):
        marker=f'    downstream_write(bar_table, 0, Dma{direction}_cntlr_base_addr+16, total_descriptors_m1, 4);'
        if text.count(marker)!=1:
            raise ValueError('unexpected doorbell scope: '+direction)
        text=text.replace(marker,
            f'    // Program the two-entry ring before publishing its last descriptor.\n'
            f'    downstream_write(bar_table, 0, Dma{direction}_cntlr_base_addr+20, total_descriptors_m1, 4);\n'+marker)
    return text

def repair_checker(text):
    marker=' failures=[]'
    if text.count(marker)!=1: raise ValueError('unexpected checker')
    return text.replace(marker,marker+'''\n if re.search(r'(?m)^.*started at .* failed at .*$',text):failures.append('native assertion failure')''')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('original',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
    a.output.mkdir(exist_ok=False,parents=True)
    (a.output/'platform-bfm.sv').write_text(repair_bfm((a.original/'platform-bfm.sv').read_text()))
    (a.output/'check_result.py').write_text(repair_checker((a.original/'check_result.py').read_text()))
