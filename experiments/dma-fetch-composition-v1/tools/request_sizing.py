"""Isolated sizing derivative of source-verified generated fetch engine."""
def repair(text):
    start = "      case(rdsize_sel_reg)"
    if text.count(start) != 1:
        raise ValueError("request-size selector anchor differs")
    begin = text.index(start)
    end = text.index("      endcase", begin) + len("      endcase")
    body = text[begin:end]
    if "remain_dwcnt_reg[9:0]" not in body or "rd_dw_size   = max_rd;" not in body:
        raise ValueError("request-size selector body differs")
    replacement = """      // All operands describe the current request, including subdescriptor reload.
      rd_dw_size = max_rd;
      if (dw_to_4KB < {1'b0, max_rd})
        rd_dw_size = dw_to_4KB[9:0];
      if (remain_dwcnt_reg < {8'b0, rd_dw_size})
        rd_dw_size = remain_dwcnt_reg[9:0];"""
    return text[:begin] + replacement + text[end:]
