`timescale 1ns / 1ps

module phys_player #(
    parameter signed [15:0] RUN_N  = 16'sd461,
    parameter signed [15:0] RUN_S  = 16'sd599,
    parameter signed [15:0] RUN_B  = 16'sd184,
    parameter signed [15:0] JUMP_N = 16'sd973,
    parameter signed [15:0] JUMP_S = 16'sd973,
    parameter signed [15:0] JUMP_B = 16'sd681,
    parameter signed [15:0] GUP_N  = 16'sd49,
    parameter signed [15:0] GUP_S  = 16'sd34,
    parameter signed [15:0] GUP_B  = 16'sd54,
    parameter signed [15:0] GDN_N  = 16'sd84,
    parameter signed [15:0] GDN_S  = 16'sd59,
    parameter signed [15:0] GDN_B  = 16'sd93,
    parameter signed [15:0] TERM   = 16'sd1536,
    parameter AC_FRAMES = 6,
    parameter DC_FRAMES = 3,
    parameter COYOTE = 3,
    parameter JBUF   = 5,
    parameter signed [11:0] SCREEN_W = 12'sd640,
    parameter EN_WALLJUMP = 1,
    parameter signed [15:0] WSL_N  = 16'sd307,
    parameter signed [15:0] WSL_S  = 16'sd307,
    parameter signed [15:0] WSL_B  = 16'sd307,
    parameter signed [15:0] WJ_N   = 16'sd717,
    parameter signed [15:0] WJ_S   = 16'sd896,
    parameter signed [15:0] WJ_B   = 16'sd502,
    parameter signed [11:0] WJ_MINH = 12'sd20,
    parameter WJ_LOCK = 17,
    parameter EN_SPRING = 1,
    parameter signed [11:0] SPR_W = 12'sd64,
    parameter signed [11:0] SPR_H = 12'sd96,
    parameter SPR_DLY = 24,
    parameter signed [15:0] LS_N = 16'sd2176,
    parameter signed [15:0] LS_S = 16'sd2176,
    parameter signed [15:0] LS_B = 16'sd2176,
    parameter signed [15:0] LP_V = 16'sd2048,
    parameter EN_WATER = 1,
    parameter signed [15:0] WGU_N  = 16'sd24,
    parameter signed [15:0] WGU_S  = 16'sd24,
    parameter signed [15:0] WGU_B  = 16'sd39,
    parameter signed [15:0] WGD_N  = 16'sd42,
    parameter signed [15:0] WGD_S  = 16'sd42,
    parameter signed [15:0] WGD_B  = 16'sd68,
    parameter signed [15:0] BUOY   = 16'sd42,
    parameter WDAMP_S = 7,
    parameter signed [15:0] WUP_S  = 16'sd640,
    parameter signed [15:0] WDN_S  = 16'sd384,
    parameter signed [15:0] WSINK  = 16'sd384
    )(
    input clk,
    input rst,
    input tick,
    input freeze,
    input load,
    input [1:0] size,
    input signed [11:0] act_x,
    input signed [11:0] act_y,
    input left_i,
    input right_i,
    input jump_i,
    output reg signed [11:0] ix,
    output reg signed [11:0] iy,
    output signed [11:0] spr_x,
    output signed [11:0] spr_y,
    output [4:0] hb_w,
    output [4:0] hb_h,
    output reg on_ground,
    output signed [15:0] vy,
    output signed [15:0] vx,
    output signed [11:0] q_x,
    output signed [11:0] q_y,
    input q_solid,
    input q_water,
    output in_water,
    input signed [11:0] bx,
    input signed [11:0] by,
    input signed [11:0] bw,
    input signed [11:0] bh,
    input signed [11:0] bx2,
    input signed [11:0] by2,
    input signed [11:0] bw2,
    input signed [11:0] bh2,
    output reg push_req,
    output reg push_right,
    output reg push_id,
    input sp0_en,
    input sp1_en,
    input signed [11:0] sp0_x,
    input signed [11:0] sp0_y,
    input signed [11:0] sp1_x,
    input signed [11:0] sp1_y,
    input [19:0] spr_top,
    input spr_launch,
    input spr_launch_id,
    output reg done,
    input arena,
    input run_a,
    input run_b,
    input left2_i,
    input right2_i,
    input jump2_i,
    input ld_a,
    input ld_b,
    input signed [11:0] ld_x,
    input signed [11:0] ld_y,
    input lp_a,
    input lp_b,
    input rs_a,
    input rs_b,
    input [1:0] rs_sa,
    input [1:0] rs_sb,
    output reg [1:0] sz_a,
    output reg signed [11:0] ix2,
    output reg signed [11:0] iy2,
    output reg [1:0] sz_b,
    output reg og2,
    output [1:0] cur_size
    );

    localparam S_IDLE = 5'd0;
    localparam S_VEL  = 5'd1;
    localparam S_XCHK = 5'd2;
    localparam S_XWT  = 5'd3;
    localparam S_YCHK = 5'd4;
    localparam S_YWT  = 5'd5;
    localparam S_GPRB = 5'd6;
    localparam S_GWT  = 5'd7;
    localparam S_N0   = 5'd8;
    localparam S_N1   = 5'd9;
    localparam S_N2   = 5'd10;
    localparam S_N3   = 5'd11;
    localparam S_DLY  = 5'd12;
    localparam S_CAR  = 5'd13;
    localparam S_W0   = 5'd14;
    localparam S_W1   = 5'd15;
    localparam S_W2   = 5'd16;
    localparam S_POS  = 5'd17;
    localparam S_JMP  = 5'd18;
    localparam S_BEG  = 5'd19;
    localparam S_RS1  = 5'd20;
    localparam S_END  = 5'd21;
    reg [4:0] st;

    reg bsel;

    reg left;
    reg right;
    reg jump;
    always @ (posedge clk) begin
        left <= bsel ? left2_i : left_i;
        right <= bsel ? right2_i : right_i;
        jump <= bsel ? jump2_i : jump_i;
    end

    reg signed [11:0] cx;
    reg signed [11:0] cy;
    reg [7:0] fxr;
    reg [7:0] fyr;
    reg signed [15:0] vyr;
    reg signed [15:0] vxr;
    reg [1:0] size_q;
    reg jhold;
    reg [3:0] coy;
    reg [3:0] jb;
    reg jprev;
    reg [4:0] lock;
    reg lj;
    reg in_w;
    reg [2:0] wet;
    reg ong;

    reg signed [11:0] s_cx;
    reg signed [11:0] s_cy;
    reg [7:0] s_fxr;
    reg [7:0] s_fyr;
    reg signed [15:0] s_vy;
    reg signed [15:0] s_vx;
    reg [1:0] s_sz;
    reg s_jh;
    reg [3:0] s_coy;
    reg [3:0] s_jb;
    reg s_jp;
    reg [4:0] s_lock;
    reg s_lj;
    reg s_inw;
    reg [2:0] s_wet;
    reg s_ong;

    reg signed [11:0] tx;
    reg signed [11:0] ty;
    reg wall_r;
    reg wall_l;
    reg near_g;
    reg [5:0] dly;
    reg signed [11:0] ts0;
    reg signed [11:0] ts1;
    reg ts_ok0;
    reg ts_ok1;
    reg pend_l;
    reg pend_id;
    reg lnch;
    reg lpk;
    reg xedge;
    reg [2:0] wk;
    reg [2:0] wn;
    reg wsel;
    reg signed [11:0] wx;
    reg signed [11:0] wy;

    reg lpp_a;
    reg lpp_b;
    reg rsp_a;
    reg rsp_b;
    reg [1:0] rss_a;
    reg [1:0] rss_b;
    reg rs_test;
    reg ldp_a;
    reg ldp_b;
    reg signed [11:0] ldx_a;
    reg signed [11:0] ldy_a;
    reg signed [11:0] ldx_b;
    reg signed [11:0] ldy_b;

    localparam signed [15:0] AC_N = (RUN_N + AC_FRAMES/2) / AC_FRAMES;
    localparam signed [15:0] AC_S = (RUN_S + AC_FRAMES/2) / AC_FRAMES;
    localparam signed [15:0] AC_B = (RUN_B + AC_FRAMES/2) / AC_FRAMES;
    localparam signed [15:0] DC_N = (RUN_N + DC_FRAMES/2) / DC_FRAMES;
    localparam signed [15:0] DC_S = (RUN_S + DC_FRAMES/2) / DC_FRAMES;
    localparam signed [15:0] DC_B = (RUN_B + DC_FRAMES/2) / DC_FRAMES;

    function [4:0] f_w;
        input [1:0] z;
        begin
            f_w = (z == 2'd1) ? 5'd6 : (z == 2'd2) ? 5'd24 : 5'd12;
        end
    endfunction
    function [4:0] f_h;
        input [1:0] z;
        begin
            f_h = (z == 2'd1) ? 5'd7 : (z == 2'd2) ? 5'd28 : 5'd14;
        end
    endfunction
    function [2:0] f_o;
        input [1:0] z;
        begin
            f_o = (z == 2'd1) ? 3'd1 : (z == 2'd2) ? 3'd4 : 3'd2;
        end
    endfunction
    function signed [15:0] f_run;
        input [1:0] z;
        begin
            f_run = (z == 2'd1) ? RUN_S : (z == 2'd2) ? RUN_B : RUN_N;
        end
    endfunction
    function signed [15:0] f_jump;
        input [1:0] z;
        begin
            f_jump = (z == 2'd1) ? JUMP_S : (z == 2'd2) ? JUMP_B : JUMP_N;
        end
    endfunction
    function signed [15:0] f_gup;
        input [1:0] z;
        begin
            f_gup = (z == 2'd1) ? GUP_S : (z == 2'd2) ? GUP_B : GUP_N;
        end
    endfunction
    function signed [15:0] f_gdn;
        input [1:0] z;
        begin
            f_gdn = (z == 2'd1) ? GDN_S : (z == 2'd2) ? GDN_B : GDN_N;
        end
    endfunction
    function signed [15:0] f_ac;
        input [1:0] z;
        begin
            f_ac = (z == 2'd1) ? AC_S : (z == 2'd2) ? AC_B : AC_N;
        end
    endfunction
    function signed [15:0] f_dc;
        input [1:0] z;
        begin
            f_dc = (z == 2'd1) ? DC_S : (z == 2'd2) ? DC_B : DC_N;
        end
    endfunction
    function signed [15:0] f_wsl;
        input [1:0] z;
        begin
            f_wsl = (z == 2'd1) ? WSL_S : (z == 2'd2) ? WSL_B : WSL_N;
        end
    endfunction
    function signed [15:0] f_wj;
        input [1:0] z;
        begin
            f_wj = (z == 2'd1) ? WJ_S : (z == 2'd2) ? WJ_B : WJ_N;
        end
    endfunction
    function signed [15:0] f_ls;
        input [1:0] z;
        begin
            f_ls = (z == 2'd1) ? LS_S : (z == 2'd2) ? LS_B : LS_N;
        end
    endfunction
    function signed [15:0] f_wgu;
        input [1:0] z;
        begin
            f_wgu = (z == 2'd1) ? WGU_S : (z == 2'd2) ? WGU_B : WGU_N;
        end
    endfunction
    function signed [15:0] f_wgd;
        input [1:0] z;
        begin
            f_wgd = (z == 2'd1) ? WGD_S : (z == 2'd2) ? WGD_B : WGD_N;
        end
    endfunction

    assign hb_w = f_w(sz_a);
    assign hb_h = f_h(sz_a);
    wire [2:0] off_a = f_o(sz_a);
    assign spr_x = ix - $signed({9'd0, off_a});
    assign spr_y = iy - $signed({9'd0, off_a});
    assign cur_size = size_q;
    assign vx = vxr;
    assign vy = vyr;

    wire [4:0] cw_q = f_w(size_q);
    wire [4:0] ch_q = f_h(size_q);
    wire [1:0] rs_sz = bsel ? rss_b : rss_a;
    wire [4:0] rw = f_w(rs_sz);
    wire [4:0] rh = f_h(rs_sz);
    wire [4:0] pw = rs_test ? rw : cw_q;
    wire [4:0] ph = rs_test ? rh : ch_q;
    wire signed [11:0] hbw_s = $signed({7'd0, pw});
    wire signed [11:0] hbh_s = $signed({7'd0, ph});
    wire signed [11:0] rs_nx = cx + $signed({8'd0, cw_q[4:1]}) - $signed({8'd0, rw[4:1]});
    wire signed [11:0] rs_ny = cy + $signed({7'd0, ch_q}) - $signed({7'd0, rh});

    wire inw = (EN_WATER != 0) && in_w;
    wire sm = (size_q == 2'd1);
    wire inw_s = (EN_WATER != 0) && sm && (wet != 3'd0);
    wire [7:0] wofs = {5'd0, wk[1:0], 1'b0};
    wire wmid = (wk == 3'd4) || !sm;
    assign in_water = inw;

    reg p_start;
    reg signed [11:0] p_x;
    reg signed [11:0] p_y;
    wire p_done;
    wire p_blocked;
    wire p_busy;
    wire signed [11:0] pq_x;
    wire signed [11:0] pq_y;
    assign q_x = wsel ? wx : pq_x;
    assign q_y = wsel ? wy : pq_y;
    phys_probe u_probe
        (.clk(clk), .rst(rst), .start(p_start), .x(p_x), .y(p_y), .w({1'b0, pw}), .h({1'b0, ph}),
         .q_x(pq_x), .q_y(pq_y), .q_solid(q_solid),
         .busy(p_busy), .done(p_done), .blocked(p_blocked));

    wire out_x = (p_x < 12'sd0) || (p_x + hbw_s > SCREEN_W);
    wire terr_blk = p_blocked | out_x;
    wire box_hit_p = (p_x < bx + bw) && (p_x + hbw_s > bx) && (p_y < by + bh) && (p_y + hbh_s > by);
    wire signed [11:0] t0 = {2'b00, spr_top[9:0]};
    wire signed [11:0] t1 = {2'b00, spr_top[19:10]};
    wire sp0_hit = sp0_en && (p_x < sp0_x + SPR_W) && (p_x + hbw_s > sp0_x) && (p_y < sp0_y + SPR_H) && (p_y + hbh_s > t0);
    wire sp1_hit = sp1_en && (p_x < sp1_x + SPR_W) && (p_x + hbw_s > sp1_x) && (p_y < sp1_y + SPR_H) && (p_y + hbh_s > t1);
    wire sp_hit_p = (EN_SPRING != 0) && (sp0_hit | sp1_hit);
    wire box_hit_p2 = (p_x < bx2 + bw2) && (p_x + hbw_s > bx2) && (p_y < by2 + bh2) && (p_y + hbh_s > by2);
    wire blocked_any = terr_blk | box_hit_p | box_hit_p2 | sp_hit_p;

    wire signed [11:0] feet = cy + hbh_s;
    wire ov0 = (EN_SPRING != 0) && sp0_en && ts_ok0 && (cx < sp0_x + SPR_W) && (cx + hbw_s > sp0_x);
    wire ov1 = (EN_SPRING != 0) && sp1_en && ts_ok1 && (cx < sp1_x + SPR_W) && (cx + hbw_s > sp1_x);
    wire rid0 = ov0 && (feet == ts0);
    wire rid1 = ov1 && (feet == ts1);
    wire signed [11:0] cr0 = (rid0 && t0 > ts0) ? (t0 - ts0) : (ov0 && t0 < feet && feet <= ts0) ? (t0 - feet) : 12'sd0;
    wire signed [11:0] cr1 = (rid1 && t1 > ts1) ? (t1 - ts1) : (ov1 && t1 < feet && feet <= ts1) ? (t1 - feet) : 12'sd0;
    wire signed [11:0] carry = (cr0 != 12'sd0) ? cr0 : cr1;
    wire do_launch = pend_l && !bsel && (pend_id ? rid1 : rid0);
    wire lpad = bsel ? lpp_b : lpp_a;

    wire [4:0] st_after_walls = (EN_WATER != 0) ? S_W0 : S_JMP;
    wire [4:0] st_after_car = (EN_WALLJUMP != 0) ? S_N0 : st_after_walls;

    wire signed [15:0] run_q = f_run(size_q);
    wire signed [15:0] ac_q = f_ac(size_q);
    wire signed [15:0] dc_q = f_dc(size_q);
    wire go_r = right && !left;
    wire go_l = left && !right;
    wire signed [15:0] up_r = vxr + ac_q;
    wire signed [15:0] dn_l = vxr - ac_q;
    wire signed [15:0] vx_r_n = (vxr >= run_q) ? vxr : ((up_r > run_q) ? run_q : up_r);
    wire signed [15:0] vx_l_n = (vxr <= -run_q) ? vxr : ((dn_l < -run_q) ? -run_q : dn_l);
    wire signed [15:0] vx_0_n = (vxr > 16'sd0) ? ((vxr <= dc_q) ? 16'sd0 : vxr - dc_q) :
                                (vxr < 16'sd0) ? ((vxr >= -dc_q) ? 16'sd0 : vxr + dc_q) : 16'sd0;
    wire signed [15:0] vx_base = go_r ? vx_r_n : go_l ? vx_l_n : vx_0_n;

    wire press = jump & ~jprev;
    wire [3:0] coy_n = ong ? COYOTE + 1 : ((coy != 0) ? coy - 4'd1 : 4'd0);
    wire [3:0] jb_n = press ? JBUF + 1 : ((jb != 0) ? jb - 4'd1 : 4'd0);
    wire fjump = inw_s && (wet <= 3'd2);
    wire do_jump_c = (jb_n != 0) && ((coy_n != 0) || fjump);
    reg do_jump;
    reg do_wj;
    reg jhold_n;
    reg lj_n;
    wire wall_any = wall_l | wall_r;
    wire do_wj_c = (EN_WALLJUMP != 0) && (jb_n != 0) && (coy_n == 0) && !fjump && wall_any && !near_g;
    wire anyj = do_jump | do_wj;

    wire [4:0] lock_n = (lock != 5'd0) ? lock - 5'd1 : 5'd0;
    wire locked = (lock_n != 5'd0);
    wire signed [15:0] wj_kick = (wall_r && !wall_l) ? -run_q : (wall_l && !wall_r) ? run_q : 16'sd0;
    wire signed [15:0] vx_n = do_wj ? wj_kick : locked ? vxr : vx_base;
    wire signed [19:0] xsum = $signed({cx, fxr}) + vxr;

    wire jhold_c = lnch ? 1'b0 : (do_jump_c | do_wj_c) ? 1'b1 : (jhold & jump & ~ong);
    wire lj_c = lnch ? 1'b1 : (lj && vyr < 16'sd0);
    wire signed [15:0] ls_q = lpk ? LP_V : f_ls(size_q);
    wire signed [15:0] vy_base = lnch ? -ls_q : do_jump ? -f_jump(size_q) : do_wj ? -f_wj(size_q) : vyr;
    wire signed [15:0] vy_drag = inw_s ? vy_base - (vy_base >>> WDAMP_S) : vy_base;
    reg signed [15:0] g_buoy;
    always @ (*) begin
        case (wet)
            3'd0: g_buoy = f_gdn(2'd1);
            3'd1: g_buoy = f_gdn(2'd1) - BUOY;
            3'd2: g_buoy = f_gdn(2'd1) - BUOY * 2;
            3'd3: g_buoy = f_gdn(2'd1) - BUOY * 3;
            default: g_buoy = f_gdn(2'd1) - BUOY * 4;
        endcase
    end
    wire signed [15:0] g_dry = (jhold_n | lj_n) ? f_gup(size_q) : f_gdn(size_q);
    wire signed [15:0] g_wet = (jhold_n | lj_n) ? f_wgu(size_q) : f_wgd(size_q);
    wire signed [15:0] grav = sm ? (inw_s ? g_buoy : g_dry) : inw ? g_wet : g_dry;
    wire signed [15:0] vy_raw = vy_drag + grav;
    wire signed [15:0] vy_c = (inw_s && vy_raw < -WUP_S) ? -WUP_S : (inw_s && vy_raw > WDN_S) ? WDN_S :
                              (vy_raw > TERM) ? TERM : (inw && !sm && vy_raw > WSINK) ? WSINK : vy_raw;
    wire signed [15:0] vy_n = (wall_any && vy_c > f_wsl(size_q)) ? f_wsl(size_q) : vy_c;
    wire signed [19:0] ysum = $signed({cy, fyr}) + vyr;

    wire ld_go = (st == S_IDLE) && arena && (ldp_a || ldp_b) && !load;

    always @ (posedge clk) begin
        if (rst) begin
            ix <= 12'sd0;
            iy <= 12'sd0;
            sz_a <= 2'd0;
            on_ground <= 0;
            ix2 <= 12'sd2000;
            iy2 <= 12'sd2000;
            sz_b <= 2'd0;
            og2 <= 0;
        end
        else if (!bsel) begin
            ix <= cx;
            iy <= cy;
            sz_a <= size_q;
            on_ground <= ong;
            if (ld_go && ldp_b) begin
                ix2 <= ldx_b;
                iy2 <= ldy_b;
                sz_b <= 2'd0;
                og2 <= 0;
            end
        end
        else begin
            ix2 <= cx;
            iy2 <= cy;
            sz_b <= size_q;
            og2 <= ong;
        end
    end

    always @ (posedge clk) begin
        p_start <= 0;
        done <= 0;
        if (rst || load) begin
            size_q <= size;
            cx <= act_x + $signed({9'd0, f_o(size)});
            cy <= act_y + $signed({9'd0, f_o(size)});
            fxr <= 8'd0;
            fyr <= 8'd0;
            vyr <= 16'sd0;
            vxr <= 16'sd0;
            jhold <= 0;
            xedge <= 0;
            coy <= 4'd0;
            jb <= 4'd0;
            wall_r <= 0;
            wall_l <= 0;
            near_g <= 0;
            lock <= 5'd0;
            dly <= 6'd0;
            ts0 <= 12'sd0;
            ts1 <= 12'sd0;
            ts_ok0 <= 0;
            ts_ok1 <= 0;
            pend_l <= 0;
            pend_id <= 0;
            lnch <= 0;
            lpk <= 0;
            lj <= 0;
            in_w <= 0;
            wk <= 0;
            wn <= 0;
            wet <= 0;
            wsel <= 0;
            wx <= 12'sd0;
            wy <= 12'sd0;
            ong <= 0;
            jprev <= jump;
            bsel <= 0;
            rs_test <= 0;
            lpp_a <= 0;
            lpp_b <= 0;
            rsp_a <= 0;
            rsp_b <= 0;
            ldp_a <= 0;
            ldp_b <= 0;
            s_cx <= 12'sd2000;
            s_cy <= 12'sd2000;
            s_fxr <= 8'd0;
            s_fyr <= 8'd0;
            s_vy <= 16'sd0;
            s_vx <= 16'sd0;
            s_sz <= 2'd0;
            s_jh <= 0;
            s_coy <= 4'd0;
            s_jb <= 4'd0;
            s_jp <= 1;
            s_lock <= 5'd0;
            s_lj <= 0;
            s_inw <= 0;
            s_wet <= 0;
            s_ong <= 0;
            st <= S_IDLE;
            push_req <= 0;
            push_right <= 0;
            push_id <= 0;
        end
        else begin
            case (st)
                S_IDLE: begin
                    if (ld_go) begin
                        if (ldp_a) begin
                            cx <= ldx_a;
                            cy <= ldy_a;
                            size_q <= 2'd0;
                            fxr <= 8'd0;
                            fyr <= 8'd0;
                            vyr <= 16'sd0;
                            vxr <= 16'sd0;
                            jhold <= 0;
                            coy <= 4'd0;
                            jb <= 4'd0;
                            jprev <= 1;
                            lock <= 5'd0;
                            lj <= 0;
                            in_w <= 0;
                            wet <= 0;
                            ong <= 0;
                            rsp_a <= 0;
                            lpp_a <= 0;
                        end
                        if (ldp_b) begin
                            s_cx <= ldx_b;
                            s_cy <= ldy_b;
                            s_sz <= 2'd0;
                            s_fxr <= 8'd0;
                            s_fyr <= 8'd0;
                            s_vy <= 16'sd0;
                            s_vx <= 16'sd0;
                            s_jh <= 0;
                            s_coy <= 4'd0;
                            s_jb <= 4'd0;
                            s_jp <= 1;
                            s_lock <= 5'd0;
                            s_lj <= 0;
                            s_inw <= 0;
                            s_wet <= 0;
                            s_ong <= 0;
                            rsp_b <= 0;
                            lpp_b <= 0;
                        end
                        ldp_a <= 0;
                        ldp_b <= 0;
                    end
                    else if (!arena && size != size_q) begin
                        size_q <= size;
                        cx <= act_x + $signed({9'd0, f_o(size)});
                        cy <= act_y + $signed({9'd0, f_o(size)});
                        fxr <= 8'd0;
                        fyr <= 8'd0;
                        vxr <= 16'sd0;
                        jhold <= 0;
                        lock <= 5'd0;
                        lj <= 0;
                    end
                    else if (tick && !freeze) begin
                        if (arena && !run_a) begin
                            st <= S_END;
                        end
                        else begin
                            st <= S_BEG;
                        end
                    end
                end

                S_BEG: begin
                    if (arena && (bsel ? rsp_b : rsp_a)) begin
                        rs_test <= 1;
                        p_x <= rs_nx;
                        p_y <= rs_ny;
                        p_start <= 1;
                        st <= S_RS1;
                    end
                    else begin
                        dly <= SPR_DLY;
                        st <= S_DLY;
                    end
                end
                S_RS1: begin
                    if (p_done == 1) begin
                        if (blocked_any == 0) begin
                            cx <= p_x;
                            cy <= p_y;
                            size_q <= rs_sz;
                            lock <= 5'd0;
                        end
                        rs_test <= 0;
                        if (bsel) begin
                            rsp_b <= 0;
                        end
                        else begin
                            rsp_a <= 0;
                        end
                        dly <= SPR_DLY;
                        st <= S_DLY;
                    end
                end

                S_DLY: begin
                    if (dly == 6'd0) begin
                        st <= S_CAR;
                    end
                    else begin
                        dly <= dly - 6'd1;
                    end
                end
                S_CAR: begin
                    cy <= cy + carry;
                    ts0 <= t0;
                    ts_ok0 <= sp0_en;
                    ts1 <= t1;
                    ts_ok1 <= sp1_en;
                    lnch <= do_launch | lpad;
                    lpk <= lpad;
                    if (!bsel) begin
                        pend_l <= 0;
                        lpp_a <= 0;
                    end
                    else begin
                        lpp_b <= 0;
                    end
                    st <= st_after_car;
                end

                S_N0: begin
                    p_x <= cx + 12'sd1;
                    p_y <= cy;
                    p_start <= 1;
                    st <= S_N1;
                end
                S_N1: begin
                    if (p_done == 1) begin
                        wall_r <= terr_blk;
                        p_x <= cx - 12'sd1;
                        p_y <= cy;
                        p_start <= 1;
                        st <= S_N2;
                    end
                end
                S_N2: begin
                    if (p_done == 1) begin
                        wall_l <= terr_blk;
                        p_x <= cx;
                        p_y <= cy + WJ_MINH;
                        p_start <= 1;
                        st <= S_N3;
                    end
                end
                S_N3: begin
                    if (p_done == 1) begin
                        near_g <= blocked_any;
                        st <= st_after_walls;
                    end
                end

                S_W0: begin
                    wx <= cx + $signed({8'd0, cw_q[4:1]});
                    if (wmid == 1) begin
                        wy <= cy + $signed({8'd0, ch_q[4:1]});
                    end
                    else begin
                        wy <= cy + $signed({4'd0, wofs});
                    end
                    wsel <= 1;
                    st <= S_W1;
                end
                S_W1: begin
                    st <= S_W2;
                end
                S_W2: begin
                    wsel <= 0;
                    if (wmid == 1) begin
                        in_w <= q_water;
                        if (sm == 0) begin
                            wet <= 0;
                        end
                        wk <= 0;
                        st <= S_JMP;
                    end
                    else begin
                        if (wk == 3'd3) begin
                            wet <= wn + (q_water ? 3'd1 : 3'd0);
                            wn <= 0;
                            wk <= 3'd4;
                        end
                        else begin
                            wn <= wn + (q_water ? 3'd1 : 3'd0);
                            wk <= wk + 3'd1;
                        end
                        st <= S_W0;
                    end
                end

                S_JMP: begin
                    do_jump <= do_jump_c;
                    do_wj <= do_wj_c;
                    jhold_n <= jhold_c;
                    lj_n <= lj_c;
                    st <= S_VEL;
                end

                S_VEL: begin
                    jprev <= jump;
                    push_req <= 0;
                    coy <= anyj ? 4'd0 : coy_n;
                    jb <= anyj ? 4'd0 : jb_n;
                    lock <= do_wj ? WJ_LOCK : lock_n;
                    vyr <= vy_n;
                    vxr <= vx_n;
                    jhold <= jhold_n;
                    lj <= lj_n;
                    lnch <= 0;
                    if (lnch == 1) begin
                        coy <= 4'd0;
                        jb <= 4'd0;
                        lock <= 5'd0;
                    end
                    st <= S_POS;
                end

                S_POS: begin
                    tx <= xsum[19:8];
                    fxr <= xsum[7:0];
                    ty <= ysum[19:8];
                    fyr <= ysum[7:0];
                    st <= S_XCHK;
                end

                S_XCHK: begin
                    if (cx == tx) begin
                        if (vxr != 16'sd0 && !xedge) begin
                            p_x <= (vxr > 16'sd0) ? cx + 12'sd1 : cx - 12'sd1;
                            p_y <= cy;
                            p_start <= 1;
                            xedge <= 1;
                            st <= S_XWT;
                        end
                        else begin
                            xedge <= 0;
                            st <= S_YCHK;
                        end
                    end
                    else begin
                        p_x <= (tx > cx) ? cx + 12'sd1 : cx - 12'sd1;
                        p_y <= cy;
                        p_start <= 1;
                        st <= S_XWT;
                    end
                end
                S_XWT: begin
                    if (p_done == 1) begin
                        if (blocked_any == 0) begin
                            if (xedge == 1) begin
                                st <= S_YCHK;
                            end
                            else begin
                                cx <= p_x;
                                st <= S_XCHK;
                            end
                            xedge <= 0;
                        end
                        else begin
                            xedge <= 0;
                            fxr <= 8'd0;
                            st <= S_YCHK;
                            if (terr_blk | sp_hit_p) begin
                                vxr <= 16'sd0;
                                lock <= 5'd0;
                            end
                            else begin
                                push_req <= 1;
                                push_right <= (p_x > cx);
                                push_id <= !box_hit_p;
                            end
                        end
                    end
                end

                S_YCHK: begin
                    if (cy == ty) begin
                        st <= S_GPRB;
                    end
                    else begin
                        p_x <= cx;
                        p_y <= (ty > cy) ? cy + 12'sd1 : cy - 12'sd1;
                        p_start <= 1;
                        st <= S_YWT;
                    end
                end
                S_YWT: begin
                    if (p_done == 1) begin
                        if (blocked_any == 0) begin
                            cy <= p_y;
                            st <= S_YCHK;
                        end
                        else begin
                            vyr <= 16'sd0;
                            fyr <= 8'd0;
                            st <= S_GPRB;
                        end
                    end
                end

                S_GPRB: begin
                    p_x <= cx;
                    p_y <= cy + 12'sd1;
                    p_start <= 1;
                    st <= S_GWT;
                end
                S_GWT: begin
                    if (p_done == 1) begin
                        ong <= blocked_any;
                        if (blocked_any && vyr >= 0) begin
                            vyr <= 16'sd0;
                            fyr <= 8'd0;
                        end
                        st <= S_END;
                    end
                end

                S_END: begin
                    if (arena) begin
                        cx <= s_cx;
                        cy <= s_cy;
                        fxr <= s_fxr;
                        fyr <= s_fyr;
                        vyr <= s_vy;
                        vxr <= s_vx;
                        size_q <= s_sz;
                        jhold <= s_jh;
                        coy <= s_coy;
                        jb <= s_jb;
                        jprev <= s_jp;
                        lock <= s_lock;
                        lj <= s_lj;
                        in_w <= s_inw;
                        wet <= s_wet;
                        ong <= s_ong;
                        s_cx <= cx;
                        s_cy <= cy;
                        s_fxr <= fxr;
                        s_fyr <= fyr;
                        s_vy <= vyr;
                        s_vx <= vxr;
                        s_sz <= size_q;
                        s_jh <= jhold;
                        s_coy <= coy;
                        s_jb <= jb;
                        s_jp <= jprev;
                        s_lock <= lock;
                        s_lj <= lj;
                        s_inw <= in_w;
                        s_wet <= wet;
                        s_ong <= ong;
                        bsel <= ~bsel;
                        if (bsel == 0) begin
                            st <= run_b ? S_BEG : S_END;
                        end
                        else begin
                            done <= 1;
                            st <= S_IDLE;
                        end
                    end
                    else begin
                        done <= 1;
                        st <= S_IDLE;
                    end
                end

                default: begin
                    st <= S_IDLE;
                end
            endcase
        end
        if (!rst && !load) begin
            if (spr_launch) begin
                pend_l <= 1;
                pend_id <= spr_launch_id;
            end
            if (lp_a) begin
                lpp_a <= 1;
            end
            if (lp_b) begin
                lpp_b <= 1;
            end
            if (rs_a && !(rs_test && !bsel)) begin
                rsp_a <= 1;
                rss_a <= rs_sa;
            end
            if (rs_b && !(rs_test && bsel)) begin
                rsp_b <= 1;
                rss_b <= rs_sb;
            end
            if (ld_a) begin
                ldp_a <= 1;
                ldx_a <= ld_x;
                ldy_a <= ld_y;
            end
            if (ld_b) begin
                ldp_b <= 1;
                ldx_b <= ld_x;
                ldy_b <= ld_y;
            end
        end
    end

endmodule
