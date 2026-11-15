
function [3:0] btn_index;
    input [9:0] xx;
    integer bk;
    reg [16:0] t;                                  // t[k] = 1 when xx >= 40*k (t[0] = 1, t[16] = 0)
    begin
        t = 17'd0;
        for (bk = 0; bk < 16; bk = bk + 1)
            t[bk] = (xx >= bk * 40);
        btn_index[3] = t[8];
        btn_index[2] = t[12] | (t[4] & ~t[8]);
        btn_index[1] = t[14] | (t[10] & ~t[12]) | (t[6] & ~t[8]) | (t[2] & ~t[4]);
        btn_index[0] = (t[1] & ~t[2]) | (t[3] & ~t[4]) | (t[5] & ~t[6]) | (t[7] & ~t[8]) |
                       (t[9] & ~t[10]) | (t[11] & ~t[12]) | (t[13] & ~t[14]) | t[15];
    end
endfunction
