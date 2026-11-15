`timescale 1ns / 1ps


module phys_box2 #(
    parameter signed [15:0] GRAV   = 16'sd56,       // 0.22
    parameter signed [15:0] TERM   = 16'sd1536,     // max fall 6 px/frame
    parameter signed [15:0] FRIC   = 16'sd13,       // 0.05 per frame
    parameter signed [15:0] PUSH_V = 16'sd128,      // 0.5 px/frame
    // tiny crate
    parameter EN_TINY = 1,
    parameter signed [15:0] FRIC_T = 16'sd20,       // 0.08
    parameter signed [15:0] KICK_X = 16'sd1024,     // 4 px/frame
    parameter signed [15:0] KICK_Y = 16'sd768,      // 3 px/frame up
    parameter signed [15:0] TERM_T = 16'sd2560,     // 10 px/frame limit
    parameter KICK_WAIT = 15,                       // frames before it can be kicked again
    parameter SETTLE = 8,                           // still frames before settled
    // water
    parameter EN_WATER = 1,
    parameter signed [15:0] WG_T   = -16'sd14,      // tiny 0.22 x -0.25
    parameter signed [15:0] WG_N   = 16'sd28,       // normal x 0.5
    parameter signed [15:0] WG_B   = 16'sd45,       // big x 0.8
    parameter signed [15:0] WDRIFT = 16'sd51,       // tiny drifts up 0.2
    parameter WDRAG_T = 2,                          // tiny loses 1/4 speed per frame
    parameter signed [15:0] WUP_T  = 16'sd160,      // tiny rises max 0.625
    parameter signed [15:0] FLT_V  = 16'sd512,      // tiny leaving slower than 2 floats
    parameter signed [11:0] SPR_W  = 12'sd64,
    parameter signed [11:0] SPR_H  = 12'sd96,
    parameter signed [11:0] OFF_Y  = 12'sd480,
    parameter signed [15:0] LS_V   = 16'sd2176
    )(
    input clk,
    input rst,
    input tick,                         // 1 per frame (the player's done)
    input freeze,                       // redraw effect, skip frames
    input load_a,                       // (re)place crate A / B
    input load_b,
    input en_a,
    input en_b,
    input signed [11:0] spawn_ax,       // sprite top left
    input signed [11:0] spawn_ay,
    input signed [11:0] spawn_bx,
    input signed [11:0] spawn_by,
    input big_a,
    input tiny_a,
    input big_b,
    input tiny_b,
    input push_req,                     // from the player
    input push_right,
    input push_id,                      // 0 = A, 1 = B
    input [1:0] player_size,            // 0 normal, 1 small, 2 big
    input signed [11:0] plx_i,          // player hitbox top left
    input signed [11:0] ply_i,
    input [4:0] plw_i,                  // player hitbox size
    input [4:0] plh_i,
    input signed [11:0] pl2x_i,         // 2nd player (arena), far away when not used
    input signed [11:0] pl2y_i,
    input [4:0] pl2w_i,                 // 2nd player hitbox size (arena players can be resized)
    input [4:0] pl2h_i,
    input sp0_en,
    input sp1_en,
    input signed [11:0] sp0_x,
    input signed [11:0] sp0_y,
    input signed [11:0] sp1_x,
    input signed [11:0] sp1_y,
    input [19:0] spr_top,
    input spr_launch,
    input spr_launch_id,
    output signed [11:0] a_ix,          // crate A top left, size, as the player sees it
    output signed [11:0] a_iy,
    output signed [11:0] a_bw,
    output signed [11:0] a_pbx,
    output signed [11:0] a_pby,
    output signed [11:0] b_ix,          // crate B
    output signed [11:0] b_iy,
    output signed [11:0] b_bw,
    output signed [11:0] b_pbx,
    output signed [11:0] b_pby,
    output reg done,                    // both crates done this frame
    output signed [11:0] q_x,           // map lookup
    output signed [11:0] q_y,
    input q_solid,
    input q_water
    );

    localparam S_IDLE = 4'd0;
    localparam S_VEL  = 4'd1;           // kick / push / gravity
    localparam S_XCHK = 4'd2;           // move x
    localparam S_XWT  = 4'd3;
    localparam S_YCHK = 4'd4;           // move y
    localparam S_YWT  = 4'd5;
    localparam S_GPRB = 4'd6;           // ground check
    localparam S_GWT  = 4'd7;
    localparam S_SWAP = 4'd8;           // swap A and B
    localparam S_KICK = 4'd9;           // decide kick / push
    localparam S_FRIC = 4'd10;          // friction
    localparam S_POS  = 4'd11;          // target position
    localparam S_W0   = 4'd12;          // water at the crate middle
    localparam S_W1   = 4'd13;
    localparam S_W2   = 4'd14;
    localparam S_CAR  = 4'd15;
    reg [3:0] st;

    // player positions come from far away, register them first (timing)
    // 1 clk late is fine, they change once per frame
    reg signed [11:0] plx;
    reg signed [11:0] ply;
    reg signed [11:0] pl2x;
    reg signed [11:0] pl2y;
    reg [4:0] pl2w;
    reg [4:0] pl2h;
    reg [4:0] plw;
    reg [4:0] plh;
    always @ (posedge clk) begin
        plx <= plx_i;
        ply <= ply_i;
        plw <= plw_i;
        plh <= plh_i;
        pl2x <= pl2x_i;
        pl2y <= pl2y_i;
        pl2w <= pl2w_i;
        pl2h <= pl2h_i;
    end

    // speed update split over 4 clk (S_KICK, S_VEL, S_FRIC, S_POS) for timing
    reg kq;                             // kick now
    reg krq;                            // kick to the right
    reg pmq;                            // push now
    reg prq;                            // push right

    // working set (the crate running now, crate A otherwise)
    reg signed [11:0] ix;
    reg signed [11:0] iy;
    reg on_ground;
    reg settled;
    reg signed [15:0] vx;
    reg signed [15:0] vy;
    // shadow set (the other crate)
    reg signed [11:0] ix_s;
    reg signed [11:0] iy_s;
    reg [7:0] fxr_s;
    reg [7:0] fyr_s;
    reg signed [15:0] vx_s;
    reg signed [15:0] vy_s;
    reg big_s;
    reg tiny_s;
    reg ong_s;
    reg settled_s;
    reg [4:0] still_s;
    reg [4:0] kc_s;
    reg cur;                            // 0 working = A, 1 working = B
    // water, working + shadow
    reg in_w = 0;
    reg flt = 0;
    reg in_w_s = 0;
    reg flt_s = 0;
    reg wsel = 0;                       // 1 = lookup is the water point
    reg signed [11:0] wx = 0;
    reg signed [11:0] wy = 0;

    reg [7:0] fxr;                      // fraction of the position
    reg [7:0] fyr;
    reg signed [11:0] tx;               // target this frame
    reg signed [11:0] ty;
    reg big_q;                          // size in use
    reg tiny_q;
    reg [4:0] still;                    // frames still on the ground
    reg [4:0] kc;                       // tiny: frames before next kick

    reg signed [11:0] ts0;
    reg signed [11:0] ts1;
    reg tsv0;
    reg tsv1;
    reg pend_l;
    reg pend_id;
    reg lq;

    wire tiny_ai = (EN_TINY != 0) && tiny_a;
    wire tiny_bi = (EN_TINY != 0) && tiny_b;

    wire signed [11:0] bw = tiny_q ? 12'sd8 : big_q ? 12'sd32 : 12'sd16;
    wire signed [11:0] bh = bw;
    wire signed [11:0] bw_s = tiny_s ? 12'sd8 : big_s ? 12'sd32 : 12'sd16;
    // the player physics only sees a tiny crate when the player is small (it stops against it),
    // other sizes walk through and kick it (moved far away)
    wire hide_q = tiny_q && (player_size != 2'd1);
    wire hide_s = tiny_s && (player_size != 2'd1);
    wire signed [11:0] pbx = hide_q ? 12'sd2000 : ix;
    wire signed [11:0] pby = hide_q ? 12'sd2000 : iy;
    wire signed [11:0] pbx_s = hide_s ? 12'sd2000 : ix_s;
    wire signed [11:0] pby_s = hide_s ? 12'sd2000 : iy_s;
    assign a_ix = cur ? ix_s : ix;
    assign b_ix = cur ? ix : ix_s;
    assign a_iy = cur ? iy_s : iy;
    assign b_iy = cur ? iy : iy_s;
    assign a_bw = cur ? bw_s : bw;
    assign b_bw = cur ? bw : bw_s;
    assign a_pbx = cur ? pbx_s : pbx;
    assign b_pbx = cur ? pbx : pbx_s;
    assign a_pby = cur ? pby_s : pby;
    assign b_pby = cur ? pby : pby_s;
    // the other crate as an obstacle (far away if it doesnt exist)
    wire en_s = cur ? en_a : en_b;
    wire signed [11:0] ob_x = en_s ? pbx_s : 12'sd2000;
    wire signed [11:0] ob_y = en_s ? pby_s : 12'sd2000;
    wire signed [11:0] ob_w = bw_s;
    wire signed [11:0] ob_h = bw_s;
    wire push_me = push_req && (push_id == cur);
    wire set_vx_en = 1'b0;              // not used
    wire signed [15:0] set_vx = 16'sd0;
    wire [5:0] w6 = tiny_q ? 6'd8 : big_q ? 6'd32 : 6'd16;

    // probe, same one the player uses
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
        (.clk(clk), .rst(rst), .start(p_start), .x(p_x), .y(p_y), .w(w6), .h(w6),
         .q_x(pq_x), .q_y(pq_y), .q_solid(q_solid),
         .busy(p_busy), .done(p_done), .blocked(p_blocked));

    wire signed [11:0] t0 = {2'b00, spr_top[9:0]};
    wire signed [11:0] t1 = {2'b00, spr_top[19:10]};
    wire sp0_hit = sp0_en && (p_x < sp0_x + SPR_W) && (p_x + bw > sp0_x) && (p_y < sp0_y + SPR_H) && (p_y + bh > t0);
    wire sp1_hit = sp1_en && (p_x < sp1_x + SPR_W) && (p_x + bw > sp1_x) && (p_y < sp1_y + SPR_H) && (p_y + bh > t1);

    wire signed [11:0] feet = iy + bh;
    wire ov0 = sp0_en && tsv0 && (ix < sp0_x + SPR_W) && (ix + bw > sp0_x);
    wire ov1 = sp1_en && tsv1 && (ix < sp1_x + SPR_W) && (ix + bw > sp1_x);
    wire rid0 = ov0 && (feet == ts0);
    wire rid1 = ov1 && (feet == ts1);
    wire signed [11:0] cr0 = (rid0 && t0 > ts0) ? (t0 - ts0) : (ov0 && t0 < feet && feet <= ts0) ? (t0 - feet) : 12'sd0;
    wire signed [11:0] cr1 = (rid1 && t1 > ts1) ? (t1 - ts1) : (ov1 && t1 < feet && feet <= ts1) ? (t1 - feet) : 12'sd0;
    wire signed [11:0] carry = (cr0 != 12'sd0) ? cr0 : cr1;

    // crate at the probed spot overlaps a player / the other crate?
    wire signed [11:0] plw_s = $signed({7'd0, plw});
    wire signed [11:0] plh_s = $signed({7'd0, plh});
    wire pl_hit_p = (p_x < plx + plw_s) && (p_x + bw > plx) && (p_y < ply + plh_s) && (p_y + bh > ply);
    wire ob_hit_p = (p_x < ob_x + ob_w) && (p_x + bw > ob_x) && (p_y < ob_y + ob_h) && (p_y + bh > ob_y);
    wire signed [11:0] pl2w_s = $signed({7'd0, pl2w});
    wire signed [11:0] pl2h_s = $signed({7'd0, pl2h});
    wire pl2_hit_p = (p_x < pl2x + pl2w_s) && (p_x + bw > pl2x) && (p_y < pl2y + pl2h_s) && (p_y + bh > pl2y);
    // small player = 6 px wide hitbox (same in single player and arena), so arena p2 works too
    wire s1 = (plw == 5'd6);
    wire s2 = (pl2w == 5'd6);
    // tiny crate: only a small player is solid for it, others pass through
    wire blocked_any = p_blocked | ((pl_hit_p & (~tiny_q | s1)) | (pl2_hit_p & (~tiny_q | s2))) | ob_hit_p | sp0_hit | sp1_hit;

    // tiny crate: who is touching it and from which side (small player cant kick)
    wire pl_touch = (ix < plx + plw_s) && (ix + bw > plx) && (iy < ply + plh_s) && (iy + bh > ply);
    wire pl2_touch = (ix < pl2x + pl2w_s) && (ix + bw > pl2x) && (iy < pl2y + pl2h_s) && (iy + bh > pl2y);
    wire k1 = !s1 && pl_touch;
    wire k2 = !s2 && pl2_touch;
    wire kick_ok = tiny_q && (kc == 5'd0) && (k1 || k2);
    wire signed [11:0] kx = k1 ? plx : pl2x;       // kicker (first one if both)
    wire signed [11:0] kw = k1 ? plw_s : pl2w_s;
    // crate middle right of the player middle -> kick right (x2 so no /2 needed)
    wire kick_right = ($signed({ix, 1'b0}) + bw) >= ($signed({kx, 1'b0}) + kw);

    // x: push / kick sets the speed, friction slows it every frame
    wire can_push = !big_q && !tiny_q && (player_size != 2'd1);
    wire signed [15:0] vx_kick = kq ? (krq ? vx + KICK_X : vx - KICK_X) : vx;
    wire signed [15:0] vx_lim = (vx_kick > TERM_T) ? TERM_T : (vx_kick < -TERM_T) ? -TERM_T : vx_kick;
    wire signed [15:0] vx_pre = set_vx_en ? set_vx :
                                tiny_q ? vx_lim :
                                pmq ? (prq ? PUSH_V : -PUSH_V) : vx;
    wire signed [15:0] fric = tiny_q ? FRIC_T : FRIC;
    wire signed [15:0] vx_n = (vx > fric) ? vx - fric : (vx < -fric) ? vx + fric : 16'sd0;
    wire signed [19:0] xsum = $signed({ix, fxr}) + vx;     // used in S_POS

    // y: gravity and the kick pop
    wire inw = (EN_WATER != 0) && in_w;
    wire signed [15:0] vy0 = lq ? -LS_V : vy;
    wire signed [15:0] vy_pk = kq ? vy0 - KICK_Y : vy0;
    wire signed [15:0] vy_pre = (inw && tiny_q && WDRAG_T != 0) ? vy_pk - (vy_pk >>> WDRAG_T) : vy_pk;
    wire signed [15:0] g_box = !inw ? GRAV : tiny_q ? WG_T : big_q ? WG_B : WG_N;
    wire signed [15:0] vy_raw = vy_pre + g_box;
    wire signed [15:0] vy_t = (inw && vy_raw < -WUP_T) ? -WUP_T : vy_raw;
    wire signed [15:0] vy_n = tiny_q ? ((vy_t > TERM_T) ? TERM_T : (vy_t < -TERM_T) ? -TERM_T : vy_t)
                                     : ((vy_raw > TERM) ? TERM : vy_raw);
    wire signed [15:0] drift = (inw && tiny_q) ? WDRIFT : 16'sd0;
    wire signed [19:0] ysum = $signed({iy, fyr}) + vy - drift;

    reg signed [11:0] fx0;              // position at frame start, for "still"
    reg signed [11:0] fy0;

    always @ (posedge clk) begin
        p_start <= 0;
        done <= 0;
        if (rst == 1) begin
            ix <= 12'sd0;
            iy <= 12'sd0;
            ix_s <= 12'sd2000;
            iy_s <= 12'sd2000;
            tiny_q <= 0;
            big_q <= 0;
            tiny_s <= 0;
            big_s <= 0;
            fxr <= 8'd0;
            fyr <= 8'd0;
            vx <= 16'sd0;
            vy <= 16'sd0;
            kc <= 5'd0;
            fxr_s <= 8'd0;
            fyr_s <= 8'd0;
            vx_s <= 16'sd0;
            vy_s <= 16'sd0;
            kc_s <= 5'd0;
            on_ground <= 0;
            still <= 5'd0;
            settled <= 0;
            ong_s <= 0;
            still_s <= 5'd0;
            settled_s <= 0;
            cur <= 0;
            st <= S_IDLE;
            in_w <= 0;
            flt <= 0;
            in_w_s <= 0;
            flt_s <= 0;
            wsel <= 0;
            ts0 <= 12'sd0;
            ts1 <= 12'sd0;
            tsv0 <= 0;
            tsv1 <= 0;
            pend_l <= 0;
            pend_id <= 0;
            lq <= 0;
        end
        else if (load_a || load_b) begin
            // after a load the working set is crate A again (a run in progress is dropped)
            wsel <= 0;
            if (load_a == 1) begin
                ix <= spawn_ax;
                iy <= spawn_ay;
                tiny_q <= tiny_ai;
                big_q <= big_a & ~tiny_ai;
                fxr <= 8'd0;
                fyr <= 8'd0;
                vx <= 16'sd0;
                vy <= 16'sd0;
                kc <= 5'd0;
                on_ground <= 0;
                still <= 5'd0;
                settled <= 0;
                in_w <= 0;
                flt <= 0;
            end
            else if (cur == 1) begin
                // A was in the shadow set, bring it back
                ix <= ix_s;
                iy <= iy_s;
                tiny_q <= tiny_s;
                big_q <= big_s;
                fxr <= fxr_s;
                fyr <= fyr_s;
                vx <= vx_s;
                vy <= vy_s;
                kc <= kc_s;
                on_ground <= ong_s;
                still <= still_s;
                settled <= settled_s;
                in_w <= in_w_s;
                flt <= flt_s;
            end
            if (load_b == 1) begin
                ix_s <= spawn_bx;
                iy_s <= spawn_by;
                tiny_s <= tiny_bi;
                big_s <= big_b & ~tiny_bi;
                fxr_s <= 8'd0;
                fyr_s <= 8'd0;
                vx_s <= 16'sd0;
                vy_s <= 16'sd0;
                kc_s <= 5'd0;
                ong_s <= 0;
                still_s <= 5'd0;
                settled_s <= 0;
                in_w_s <= 0;
                flt_s <= 0;
            end
            else if (cur == 1) begin
                // B was in the working set, move it to the shadow
                ix_s <= ix;
                iy_s <= iy;
                tiny_s <= tiny_q;
                big_s <= big_q;
                fxr_s <= fxr;
                fyr_s <= fyr;
                vx_s <= vx;
                vy_s <= vy;
                kc_s <= kc;
                ong_s <= on_ground;
                still_s <= still;
                settled_s <= settled;
                in_w_s <= in_w;
                flt_s <= flt;
            end
            cur <= 0;
            st <= S_IDLE;
        end
        else begin
            case (st)
                S_IDLE: begin
                    if (tick && !freeze) begin
                        st <= S_CAR;
                    end
                end

                S_CAR: begin
                    iy <= iy + carry;
                    lq <= pend_l && (pend_id ? rid1 : rid0);
                    st <= S_W0;
                end

                // water at the middle (floating: 2 px below it), answer 2 clk later
                S_W0: begin
                    wx <= ix + (bw >>> 1);
                    wy <= iy + (bh >>> 1) + (flt ? 12'sd2 : 12'sd0);
                    wsel <= 1;
                    st <= S_W1;
                end
                S_W1: begin
                    st <= S_W2;
                end
                S_W2: begin
                    wsel <= 0;
                    if (EN_WATER == 0) begin
                        in_w <= 0;
                        flt <= 0;
                    end
                    else if (flt == 1) begin
                        in_w <= 0;
                        flt <= q_water && tiny_q;
                    end
                    else begin
                        in_w <= q_water;
                        // came up out of the water slowly -> float
                        if (tiny_q && in_w && !q_water && vy <= 16'sd0 && vy > -FLT_V) begin
                            flt <= 1;
                        end
                    end
                    st <= S_KICK;
                end

                S_KICK: begin
                    kq <= kick_ok;
                    krq <= kick_right;
                    pmq <= push_me && can_push;
                    prq <= push_right;
                    st <= S_VEL;
                end

                S_VEL: begin
                    fx0 <= ix;
                    fy0 <= iy;
                    vx <= vx_pre;
                    vy <= (flt && !kq && !lq) ? 16'sd0 : vy_n;     // floating = held still, a kick ends it
                    if (kq == 1 || lq == 1) begin
                        flt <= 0;
                    end
                    kc <= kq ? KICK_WAIT : ((kc != 5'd0) ? kc - 5'd1 : 5'd0);
                    st <= S_FRIC;
                end

                S_FRIC: begin
                    vx <= vx_n;
                    st <= S_POS;
                end

                S_POS: begin
                    tx <= xsum[19:8];
                    fxr <= xsum[7:0];
                    ty <= ysum[19:8];
                    fyr <= ysum[7:0];
                    st <= S_XCHK;
                end

                // 1 px at a time like the player
                S_XCHK: begin
                    if (ix == tx) begin
                        st <= S_YCHK;
                    end
                    else begin
                        p_x <= (tx > ix) ? ix + 12'sd1 : ix - 12'sd1;
                        p_y <= iy;
                        p_start <= 1;
                        st <= S_XWT;
                    end
                end
                S_XWT: begin
                    if (p_done == 1) begin
                        if (blocked_any == 0) begin
                            ix <= p_x;
                            st <= S_XCHK;
                        end
                        else begin
                            // wall: tiny bounces back at half speed, others stop
                            vx <= tiny_q ? -(vx / 16'sd2) : 16'sd0;
                            fxr <= 8'd0;
                            st <= S_YCHK;
                        end
                    end
                end

                S_YCHK: begin
                    if (iy == ty || iy >= OFF_Y) begin
                        st <= S_GPRB;
                    end
                    else begin
                        p_x <= ix;
                        p_y <= (ty > iy) ? iy + 12'sd1 : iy - 12'sd1;
                        p_start <= 1;
                        st <= S_YWT;
                    end
                end
                S_YWT: begin
                    if (p_done == 1) begin
                        if (blocked_any == 0) begin
                            iy <= p_y;
                            st <= S_YCHK;
                        end
                        else begin
                            vy <= 16'sd0;
                            fyr <= 8'd0;
                            st <= S_GPRB;
                        end
                    end
                end

                S_GPRB: begin
                    p_x <= ix;
                    p_y <= iy + 12'sd1;
                    p_start <= 1;
                    st <= S_GWT;
                end
                S_GWT: begin
                    if (p_done == 1) begin
                        on_ground <= blocked_any;
                        if (blocked_any && vy >= 0) begin
                            vy <= 16'sd0;
                            fyr <= 8'd0;
                        end
                        // settled = on the ground, didnt move, no speed, SETTLE frames
                        if (blocked_any && ix == fx0 && iy == fy0 && vx == 16'sd0) begin
                            if (still != SETTLE) begin
                                still <= still + 5'd1;
                            end
                            settled <= (still + 5'd1 >= SETTLE);
                        end
                        else begin
                            still <= 5'd0;
                            settled <= 0;
                        end
                        st <= S_SWAP;
                    end
                end

                // swap the 2 crates
                S_SWAP: begin
                    ix <= ix_s;
                    iy <= iy_s;
                    tiny_q <= tiny_s;
                    big_q <= big_s;
                    fxr <= fxr_s;
                    fyr <= fyr_s;
                    vx <= vx_s;
                    vy <= vy_s;
                    kc <= kc_s;
                    on_ground <= ong_s;
                    still <= still_s;
                    settled <= settled_s;
                    in_w <= in_w_s;
                    flt <= flt_s;
                    ix_s <= ix;
                    iy_s <= iy;
                    tiny_s <= tiny_q;
                    big_s <= big_q;
                    fxr_s <= fxr;
                    fyr_s <= fyr;
                    vx_s <= vx;
                    vy_s <= vy;
                    kc_s <= kc;
                    ong_s <= on_ground;
                    still_s <= still;
                    settled_s <= settled;
                    in_w_s <= in_w;
                    flt_s <= flt;
                    cur <= ~cur;
                    if (cur == 0) begin
                        st <= S_CAR;            // A done, now B
                    end
                    else begin
                        done <= 1;              // B done, frame finished
                        ts0 <= t0;
                        ts1 <= t1;
                        tsv0 <= sp0_en;
                        tsv1 <= sp1_en;
                        pend_l <= 0;
                        st <= S_IDLE;
                    end
                end

                default: begin
                    st <= S_IDLE;
                end
            endcase
        end
        if (rst == 0 && spr_launch == 1) begin
            pend_l <= 1;
            pend_id <= spr_launch_id;
        end
    end

endmodule
