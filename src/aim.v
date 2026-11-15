`timescale 1ns / 1ps

module aim (
    input clk,
    input [9:0] x,
    input [9:0] y,
    input [9:0] mx,                     // mouse
    input [9:0] my,
    input mode_edit,
    input [16*30-1:0] objs,             // object table
    // gun state from gun.v
    input gun_held,
    input [9:0] gd_x,                   // dropped gun 8 x 8 box top left
    input [9:0] gd_y,
    input gd_left,
    input [9:0] clip_l,
    input [9:0] clip_r,
    // map lookup
    output reg signed [11:0] col_px,
    output reg signed [11:0] col_py,
    input col_solid,
    input col_bnd,
    input col_mir,                      // mirror tile
    input col_mvert,                    // mirror is vertical
    output reg col_busy,
    input [19:0] spr_top,               // spring tops (spring_ctrl)
    input [13:0] door_open,             // {door 1, door 0} how far the panel went up
    // shooting
    input mleft,
    input mright,
    input table_load,                   // level loaded, remove bullet and spark
    output reg shot_hit,                // 1 clk: bullet hit player / crate
    output reg [4:0] shot_slot,         // which slot
    output reg shot_grow,               // 1 grow, 0 shrink
    output reg b_on,                    // bullet flying
    output reg [9:0] b_px,              // bullet middle
    output reg [9:0] b_py,
    output reg [3:0] shot_idx,          // bullet / spark pixel
    // pixels
    output reg [3:0] gun_idx,
    output reg [3:0] path_idx,
    output reg face_left,
    // shared angle unit (port a)
    output reg ang_req,
    output reg signed [15:0] ang_vx,
    output reg signed [15:0] ang_vy,
    output reg ang_zero,
    output reg ang_ovr_en,
    output reg [7:0] ang_ovr,
    input ang_ack,
    input [15:0] ang_cz,
    input signed [15:0] ang_s,
    input signed [15:0] ang_c
    );
    `include "sprite_data.vh"
    `include "obj_slots.vh"
    `include "aim_tables.vh"

    initial begin
        col_px = 0;
        col_py = 0;
        col_busy = 0;
        shot_hit = 0;
        shot_slot = 0;
        shot_grow = 0;
        b_on = 0;
        b_px = 0;
        b_py = 0;
        shot_idx = 0;
        gun_idx = 0;
        path_idx = 0;
        face_left = 0;
        ang_req = 0;
        ang_vx = 0;
        ang_vy = 0;
        ang_zero = 0;
        ang_ovr_en = 0;
        ang_ovr = 0;
    end

    localparam NSEG = 4;                            // segments = shot + 3 bounces
    localparam [10:0] MAX_STEPS = 11'd1800;         // path / bullet range in px
    localparam BULLET_STEP = 6;                     // bullet px per frame
    localparam signed [27:0] HALF = 28'sd8192;     // 0.5, for rounding

    // per frame results used for drawing
    reg signed [15:0] c = 16'sd16384;               // aim cos / sin * 16384
    reg signed [15:0] s = 16'sd0;
    reg signed [25:0] Au = 0;                       // gun rotation start values
    reg signed [25:0] Av = 0;
    reg gun_on = 0;
    reg flipv = 0;
    // 1 entry per path segment
    reg seg_on [0:NSEG-1];
    reg signed [15:0] seg_c [0:NSEG-1];             // direction
    reg signed [15:0] seg_s [0:NSEG-1];
    reg [10:0] seg_len [0:NSEG-1];
    reg signed [25:0] seg_Aal [0:NSEG-1];           // lin_eval start values (along / across)
    reg signed [25:0] seg_App [0:NSEG-1];

    // player from the object table
    wire pl_vis = objs[SLOT_PLAYER*30 + 29];
    wire [9:0] pl_x = objs[SLOT_PLAYER*30 + 19 +: 10];
    wire [9:0] pl_y = objs[SLOT_PLAYER*30 + 9 +: 10];
    wire [1:0] pl_sz = objs[SLOT_PLAYER*30 +: 2];   // 0 normal, 1 small, 2 big
    // body middle (8 / 16 / 32 square)
    wire [9:0] bc_x = pl_x + ((pl_sz == 2'd1) ? 10'd4 : (pl_sz == 2'd2) ? 10'd16 : 10'd8);
    wire [9:0] bc_y = pl_y + ((pl_sz == 2'd1) ? 10'd4 : (pl_sz == 2'd2) ? 10'd16 : 10'd8);

    // start of vblank
    reg y480_q = 0;
    wire fs = (y >= 10'd480) && !y480_q;
    always @ (posedge clk) begin
        y480_q <= (y >= 10'd480);
    end

    // 1 multiplier used one after another
    reg signed [15:0] ma = 0;
    reg signed [15:0] mb = 0;
    reg signed [27:0] prod = 0;
    always @ (posedge clk) begin
        prod <= ma * mb;
    end

    // fsm states
    localparam F_IDLE    = 0;
    localparam F_CORDIC  = 1;           // wait for angle_unit
    localparam F_TABLE   = 2;           // not used
    localparam F_MUL     = 3;           // lin_eval start values
    localparam F_TRACE   = 4;           // 1 px step
    localparam F_T_WAIT  = 5;           // send point to the map lookup
    localparam F_T_CHECK = 6;           // look at the answer
    localparam F_SEGINIT = 7;           // next segment's start values
    localparam F_ANCHOR  = 8;           // move hand out
    localparam F_START   = 9;
    localparam F_BLOAD   = 10;          // move the bullet first
    localparam HAND_OUT = 5;
    localparam GUN_PX = 1;              // gun art pixel in the hand (back of barrel)
    localparam GUN_PY = 3;
    localparam TIP = 7 - GUN_PX;        // hand -> gun tip, 6 px

    reg [3:0] fst = F_IDLE;
    reg [15:0] cz = 0;                  // angle, 65536 = 360 deg
    reg [3:0] ci = 0;
    reg [9:0] pvx = 0;                  // the hand
    reg [9:0] pvy = 0;
    reg [2:0] mstep = 0;
    reg [2:0] ev = 0;                   // 0 = gun, 1+ = segments
    reg signed [27:0] p1 = 0;
    reg signed [27:0] p2 = 0;
    reg signed [27:0] p3 = 0;
    // tracer
    reg signed [27:0] tx = 0;           // position, 14 bit fraction
    reg signed [27:0] ty = 0;
    reg signed [15:0] tc = 0;           // direction now
    reg signed [15:0] ts = 0;
    reg [10:0] steps = 0;               // steps in this segment
    reg [10:0] total = 0;               // steps in the whole path
    reg [2:0] nseg = 0;
    reg [1:0] skip = 0;                 // steps to ignore mirrors after a bounce
    reg play = 0;                       // draw a path this frame
    reg tab2 = 0;
    reg [1:0] psz = 0;                  // player size this frame
    reg held = 1;                       // gun in hand this frame
    reg dleft = 0;
    reg face = 0;
    // bullet, saved between frames
    reg signed [27:0] b_tx = 0;
    reg signed [27:0] b_ty = 0;
    reg signed [15:0] b_tc = 0;
    reg signed [15:0] b_ts = 0;
    reg [10:0] b_total = 0;
    reg [2:0] b_nseg = 0;
    reg [1:0] b_skip = 0;
    reg b_lb = 0;                       // bullet left the body
    reg b_g = 0;                        // grow bullet
    reg bmode = 0;                      // tracing the bullet (not the preview)
    reg b_arm = 0;                      // start a bullet on this trace
    reg [2:0] bstep = 0;
    reg ml_q = 0;
    reg mr_q = 0;
    reg fire_pend = 0;
    reg fire_g = 0;
    // spark
    reg sp_on = 0;
    reg sp_g = 0;
    reg [2:0] sp_t = 0;
    reg [9:0] sp_x = 0;
    reg [9:0] sp_y = 0;
    // hand at the edge of the body, gun the same size for all
    wire [4:0] hand_out = (psz == 2'd1) ? 5'd3 : (psz == 2'd2) ? 5'd10 : 5'd5;
    wire [5:0] tip_len = TIP;
    reg [9:0] seg_sx = 0;               // start of the segment being traced
    reg [9:0] seg_sy = 0;
    reg [9:0] seg_sx_mem [0:NSEG-1];
    reg [9:0] seg_sy_mem [0:NSEG-1];
    // tracer point in whole px
    wire signed [11:0] ipx = (tx + HALF) >>> 14;
    wire signed [11:0] ipy = (ty + HALF) >>> 14;

    // crate side from its size code
    function [6:0] csz;
        input [1:0] code;
        begin
            csz = (code == 2'd1) ? 7'd8 : (code == 2'd2) ? 7'd32 : 7'd16;
        end
    endfunction

    // what objects are at the tracer point
    reg hit_block;                      // stops the path
    reg hit_res;                        // player / crate (can be resized), slot hit_sl
    reg [4:0] hit_sl;
    reg lb = 0;                         // point has left the player's body
    wire [6:0] pl_side = csz(pl_sz);
    wire in_pl = pl_vis && ipx >= $signed({2'b0, pl_x}) && ipx < $signed({2'b0, pl_x}) + $signed({5'b0, pl_side}) &&
                 ipy >= $signed({2'b0, pl_y}) && ipy < $signed({2'b0, pl_y}) + $signed({5'b0, pl_side});
    integer j;
    always @ (*) begin
        hit_block = 0;
        hit_res = 0;
        hit_sl = SLOT_PLAYER;
        // crates
        for (j = SLOT_BOX0; j < SLOT_BOX0 + N_BOX; j = j + 1) begin
            if (objs[j*30 + 29]) begin
                if (ipx >= $signed({2'b0, objs[j*30 + 19 +: 10]}) && ipx < $signed({2'b0, objs[j*30 + 19 +: 10]}) + $signed({5'b0, csz(objs[j*30 +: 2])}) &&
                    ipy >= $signed({2'b0, objs[j*30 + 9 +: 10]}) && ipy < $signed({2'b0, objs[j*30 + 9 +: 10]}) + $signed({5'b0, csz(objs[j*30 +: 2])})) begin
                    hit_block = 1;
                    hit_res = 1;
                    hit_sl = j;
                end
            end
        end
        // doors, only the part of the panel still down blocks
        // (opened by the scale -> shots go under it)
        for (j = SLOT_DOOR0; j < SLOT_DOOR0 + N_DOOR; j = j + 1) begin
            if (objs[j*30 + 29]) begin
                if (ipx >= $signed({2'b0, objs[j*30 + 19 +: 10]}) + 6 && ipx < $signed({2'b0, objs[j*30 + 19 +: 10]}) + 18 &&
                    ipy >= $signed({2'b0, objs[j*30 + 9 +: 10]}) && ipy < $signed({2'b0, objs[j*30 + 9 +: 10]}) + $signed({4'b0, objs[j*30 + 2 +: 7], 1'b0})
                                                                - $signed({4'b0, door_open[(j - SLOT_DOOR0)*7 +: 7], 1'b0})) begin
                    hit_block = 1;
                end
            end
        end
        // springs, from the top now to the base
        for (j = SLOT_SPRING0; j < SLOT_SPRING0 + N_SPRING; j = j + 1) begin
            if (objs[j*30 + 29]) begin
                if (ipx >= $signed({2'b0, objs[j*30 + 19 +: 10]}) && ipx < $signed({2'b0, objs[j*30 + 19 +: 10]}) + 64 &&
                    ipy >= $signed({2'b0, spr_top[(j - SLOT_SPRING0)*10 +: 10]}) && ipy < $signed({2'b0, objs[j*30 + 9 +: 10]}) + 96) begin
                    hit_block = 1;
                end
            end
        end
        // player, only after the shot left the body
        if (in_pl && lb) begin
            hit_block = 1;
            hit_res = 1;
            hit_sl = SLOT_PLAYER;
        end
    end
    wire off_level = (ipx < 0) || (ipx >= 640) || (ipy < 64) || (ipy >= 424);

    integer k;
    initial begin
        for (k = 0; k < NSEG; k = k + 1) begin
            seg_on[k] = 0;
            seg_c[k] = 0;
            seg_s[k] = 0;
            seg_len[k] = 0;
            seg_Aal[k] = 0;
            seg_App[k] = 0;
            seg_sx_mem[k] = 0;
            seg_sy_mem[k] = 0;
        end
    end

    always @ (posedge clk) begin
        shot_hit <= 0;
        // fire: mouse button just pressed, mouse in the level, play mode
        ml_q <= mleft;
        mr_q <= mright;
        if (!mode_edit && my >= 10'd64 && my < 10'd424 && ((mleft && !ml_q) || (mright && !mr_q))) begin
            fire_pend <= 1;
            fire_g <= mleft && !ml_q;
        end
        // spark lasts 8 frames
        if (fs && sp_on) begin
            if (sp_t == 3'd7) begin
                sp_on <= 0;
            end
            sp_t <= sp_t + 3'd1;
        end
        if (mode_edit || table_load) begin
            b_on <= 0;
            sp_on <= 0;
            fire_pend <= 0;
            b_arm <= 0;
        end

        case (fst)
            F_IDLE: begin
                if (fs == 1) begin
                    fst <= (b_on && !mode_edit && !table_load) ? F_BLOAD : F_START;
                end
            end

            // move the bullet BULLET_STEP px first
            F_BLOAD: begin
                tx <= b_tx;
                ty <= b_ty;
                tc <= b_tc;
                ts <= b_ts;
                total <= b_total;
                nseg <= b_nseg;
                skip <= b_skip;
                lb <= b_lb;
                bmode <= 1;
                bstep <= 3'd0;
                col_busy <= 1;
                fst <= F_TRACE;
            end

            F_START: begin
                psz <= pl_sz;
                held <= gun_held || mode_edit;
                dleft <= gd_left;
                // held: start at the body middle (moved to the hand later)
                // dropped: the grip pixel
                pvx <= (gun_held || mode_edit) ? bc_x : (gd_left ? gd_x + 10'd7 - GUN_PX : gd_x + GUN_PX);
                pvy <= (gun_held || mode_edit) ? bc_y : gd_y + GUN_PY;
                play <= !mode_edit && pl_vis && gun_held;   // path only with gun in hand
                gun_on <= pl_vis;
                // ask angle_unit
                ang_req <= 1;
                ang_vx <= $signed({6'b0, mx}) - $signed({6'b0, bc_x});
                ang_vy <= $signed({6'b0, my}) - $signed({6'b0, bc_y});
                ang_zero <= mode_edit;              // edit mode points right
                ang_ovr_en <= !(gun_held || mode_edit);     // dropped gun lies flat
                ang_ovr <= gd_left ? 8'd128 : 8'd0;
                fst <= F_CORDIC;
            end

            F_CORDIC: begin
                if (ang_ack == 1) begin
                    ang_req <= 0;
                    cz <= ang_cz;
                    s <= ang_s;
                    c <= ang_c;
                    // player faces the mouse (with or without gun), 90-270 deg = left
                    face = !mode_edit && pl_vis && (ang_cz[15:8] + {7'd0, ang_cz[7]} > 8'd64) && (ang_cz[15:8] + {7'd0, ang_cz[7]} < 8'd192);
                    face_left <= face;
                    flipv <= held ? (play && face) : dleft;
                    ev <= 0;
                    mstep <= 0;
                    fst <= F_ANCHOR;
                end
            end

            // hand = body middle + hand_out along the aim
            F_ANCHOR: begin
                if (held == 1) begin
                    pvx <= (($signed({18'b0, pvx}) <<< 14) + $signed({1'b0, hand_out}) * c + HALF) >>> 14;
                    pvy <= (($signed({18'b0, pvy}) <<< 14) + $signed({1'b0, hand_out}) * s + HALF) >>> 14;
                end
                fst <= F_MUL;
            end

            // lin_eval start values: A_along = -(sx*c + sy*s), A_across = sx*s - sy*c
            // ev 0 = the gun (around the hand), ev 1+ = path segments
            F_MUL: begin
                mstep <= mstep + 1;
                case (mstep)
                    3'd0: begin
                        ma <= (ev == 0) ? $signed({6'b0, pvx}) : $signed({6'b0, seg_sx});
                        mb <= (ev == 0) ? c : seg_c[ev-1];
                    end
                    3'd1: begin
                        ma <= (ev == 0) ? $signed({6'b0, pvy}) : $signed({6'b0, seg_sy});
                        mb <= (ev == 0) ? s : seg_s[ev-1];
                    end
                    3'd2: begin
                        p1 <= prod;
                        ma <= (ev == 0) ? $signed({6'b0, pvx}) : $signed({6'b0, seg_sx});
                        mb <= (ev == 0) ? s : seg_s[ev-1];
                    end
                    3'd3: begin
                        p2 <= prod;
                        ma <= (ev == 0) ? $signed({6'b0, pvy}) : $signed({6'b0, seg_sy});
                        mb <= (ev == 0) ? c : seg_c[ev-1];
                    end
                    3'd4: begin
                        p3 <= prod;
                    end
                    default: begin
                        if (ev == 0) begin
                            Au <= -(p1 + p2);
                            Av <= p3 - prod;
                            // start tracing at the gun tip
                            tx <= ($signed({18'b0, pvx}) <<< 14) + $signed({1'b0, tip_len}) * c;
                            ty <= ($signed({18'b0, pvy}) <<< 14) + $signed({1'b0, tip_len}) * s;
                            tc <= c;
                            ts <= s;
                            steps <= 0;
                            total <= 0;
                            nseg <= 0;
                            skip <= 0;
                            lb <= 0;
                            for (k = 0; k < NSEG; k = k + 1) begin
                                seg_on[k] <= 0;
                            end
                            // fire waiting -> the bullet starts on this path
                            b_arm <= fire_pend && play && !b_on;
                            if (fire_pend && play && !b_on) begin
                                b_g <= fire_g;
                            end
                            fire_pend <= 0;         // 1 click = 1 shot, ignored while one flies
                            col_busy <= 1;
                            fst <= play ? F_TRACE : F_IDLE;
                            if (play == 0) begin
                                col_busy <= 0;
                            end
                        end
                        else begin
                            seg_Aal[ev-1] <= -(p1 + p2);
                            seg_App[ev-1] <= p3 - prod;
                            ev <= ev + 1;
                            fst <= F_SEGINIT;
                        end
                        mstep <= 0;
                    end
                endcase
            end

            // trace, 1 px step every 3 clk
            F_TRACE: begin
                if (total == 0 && !bmode) begin
                    seg_sx <= ipx[9:0];             // first segment starts at the tip
                    seg_sy <= ipy[9:0];
                end
                if (total == 0 && !bmode && b_arm) begin
                    // new bullet starts here
                    b_arm <= 0;
                    b_on <= 1;
                    b_tx <= tx;
                    b_ty <= ty;
                    b_tc <= tc;
                    b_ts <= ts;
                    b_total <= 0;
                    b_nseg <= 0;
                    b_skip <= 0;
                    b_lb <= 0;
                    b_px <= ipx[9:0];
                    b_py <= ipy[9:0];
                end
                tx <= tx + tc;
                ty <= ty + ts;
                steps <= steps + 1;
                total <= total + 1;
                fst <= F_T_WAIT;
            end

            F_T_WAIT: begin
                col_px <= ipx;
                col_py <= ipy;
                fst <= F_T_CHECK;
                mstep <= 0;
            end

            F_T_CHECK: begin
                if (mstep == 0) begin
                    mstep <= 1;                     // map answer comes next clk
                end
                else if (bmode == 1) begin
                    // bullet step
                    mstep <= 0;
                    if (!in_pl) begin
                        lb <= 1;
                    end
                    if (off_level || (col_solid && !col_mir) || hit_block || total >= MAX_STEPS ||
                        (col_mir && skip == 0 && nseg == NSEG - 1)) begin
                        // bullet stops
                        b_on <= 0;
                        bmode <= 0;
                        fst <= F_START;
                        if (!off_level && total < MAX_STEPS) begin
                            // hit something: spark (+ report the hit)
                            sp_on <= 1;
                            sp_t <= 3'd0;
                            sp_g <= b_g;
                            sp_x <= ipx[9:0];
                            sp_y <= ipy[9:0];
                            if (hit_res == 1) begin
                                shot_hit <= 1;
                                shot_slot <= hit_sl;
                                shot_grow <= b_g;
                            end
                        end
                    end
                    else begin
                        if (skip == 0 && col_mir) begin
                            // bounce, same as the preview
                            nseg <= nseg + 1;
                            skip <= 2'd3;
                            if (col_mvert == 1) begin
                                tc <= -tc;
                            end
                            else begin
                                ts <= -ts;
                            end
                        end
                        else if (skip != 0) begin
                            skip <= skip - 1;
                        end
                        if (bstep == BULLET_STEP - 1) begin
                            // moved enough this frame, save the bullet
                            // (values after this step's bounce)
                            b_tx <= tx;
                            b_ty <= ty;
                            b_total <= total;
                            b_lb <= !in_pl || lb;
                            b_nseg <= (skip == 0 && col_mir) ? nseg + 1 : nseg;
                            b_skip <= (skip == 0 && col_mir) ? 2'd3 : (skip != 0) ? skip - 1 : 2'd0;
                            b_tc <= (skip == 0 && col_mir && col_mvert) ? -tc : tc;
                            b_ts <= (skip == 0 && col_mir && !col_mvert) ? -ts : ts;
                            b_px <= ipx[9:0];
                            b_py <= ipy[9:0];
                            bmode <= 0;
                            fst <= F_START;
                        end
                        else begin
                            bstep <= bstep + 3'd1;
                            fst <= F_TRACE;
                        end
                    end
                end
                else begin
                    // preview step
                    mstep <= 0;
                    if (!in_pl) begin
                        lb <= 1;
                    end
                    if (off_level || (col_solid && !col_mir) || hit_block || total >= MAX_STEPS ||
                        (col_mir && skip == 0 && nseg == NSEG - 1)) begin
                        // end of the path, save the last segment
                        seg_on[nseg] <= 1;
                        seg_c[nseg] <= tc;
                        seg_s[nseg] <= ts;
                        seg_len[nseg] <= steps;
                        seg_sx_mem[nseg] <= seg_sx;
                        seg_sy_mem[nseg] <= seg_sy;
                        ev <= 1;
                        fst <= F_SEGINIT;
                    end
                    else if (skip == 0 && col_mir) begin
                        // bounce: close this segment, next one starts here
                        seg_on[nseg] <= 1;
                        seg_c[nseg] <= tc;
                        seg_s[nseg] <= ts;
                        seg_len[nseg] <= steps;
                        seg_sx_mem[nseg] <= seg_sx;
                        seg_sy_mem[nseg] <= seg_sy;
                        nseg <= nseg + 1;
                        if (col_mvert == 1) begin
                            tc <= -tc;
                        end
                        else begin
                            ts <= -ts;
                        end
                        seg_sx <= ipx[9:0];
                        seg_sy <= ipy[9:0];
                        steps <= 0;
                        skip <= 2'd3;
                        fst <= F_TRACE;
                    end
                    else begin
                        if (skip != 0) begin
                            skip <= skip - 1;
                        end
                        fst <= F_TRACE;
                    end
                end
            end

            // start values for every segment, ev = 1 .. nseg + 1
            F_SEGINIT: begin
                col_busy <= 0;
                if (ev > nseg + 1) begin
                    fst <= F_IDLE;
                end
                else begin
                    seg_sx <= seg_sx_mem[ev-1];
                    seg_sy <= seg_sy_mem[ev-1];
                    mstep <= 0;
                    fst <= F_MUL;
                end
            end

            default: begin
                fst <= F_IDLE;
            end
        endcase
    end

    // drawing
    // gun: u along the barrel, v across
    wire signed [25:0] u;
    wire signed [25:0] v;
    lin_eval ev_u (.clk(clk), .x(x), .y(y), .A(Au), .a(c), .b(s), .val(u));
    lin_eval ev_v (.clk(clk), .x(x), .y(y), .A(Av), .a(-s), .b(c), .val(v));
    wire signed [13:0] upx = (u + HALF) >>> 14;
    wire signed [13:0] vpx = (v + HALF) >>> 14;
    wire signed [13:0] gcol = upx + GUN_PX;
    wire signed [13:0] grow = (flipv ? -vpx : vpx) + GUN_PY;
    // held gun never drawn past a boundary
    wire in_gun = gun_on && gcol >= 0 && gcol < 8 && grow >= 0 && grow < 8 &&
                  (!held || mode_edit || (x >= clip_l && x < clip_r));

    // path: distance along / across each segment, dot every 8 px
    // (along 0-2 of every 8 lit, across within 1.25 px of the line)
    wire signed [25:0] al [0:NSEG-1];
    wire signed [25:0] pp [0:NSEG-1];
    reg [NSEG-1:0] dot;
    genvar gi;
    generate
        for (gi = 0; gi < NSEG; gi = gi + 1) begin : g_seg
            lin_eval ev_al (.clk(clk), .x(x), .y(y), .A(seg_Aal[gi]), .a(seg_c[gi]), .b(seg_s[gi]), .val(al[gi]));
            lin_eval ev_pp (.clk(clk), .x(x), .y(y), .A(seg_App[gi]), .a(-seg_s[gi]), .b(seg_c[gi]), .val(pp[gi]));
            wire signed [13:0] alpx = al[gi] >>> 14;
            wire on = seg_on[gi] && alpx >= 2 && alpx < $signed({3'b0, seg_len[gi]}) &&
                      pp[gi] > -26'sd20480 && pp[gi] < 26'sd20480 && (alpx[2:0] < 3'd3);
            always @ (posedge clk) begin
                dot[gi] <= on;
            end
        end
    endgenerate

    // bullet (6 x 6 ammo art) and spark
    wire [10:0] bdx = {1'b0, x} - {1'b0, b_px} + 11'd3;
    wire [10:0] bdy = {1'b0, y} - {1'b0, b_py} + 11'd3;
    wire in_b = b_on && bdx < 11'd6 && bdy < 11'd6;
    wire [9:0] sax = (x > sp_x) ? x - sp_x : sp_x - x;
    wire [9:0] say = (y > sp_y) ? y - sp_y : sp_y - y;
    wire [9:0] smx_ = (sax > say) ? sax : say;
    wire [9:0] smn = (sax > say) ? say : sax;
    wire [10:0] sd = smx_ + (smn >> 2) + (smn >> 3);   // about the distance (max + 3/8 min)
    wire [10:0] srad = 11'd3 + sp_t;                    // 3 -> 10 px over 8 frames
    // rim blue = grow, red = shrink, flashing middle for the first 4 frames
    wire [3:0] sp_pix = (!sp_on || sd >= srad) ? 4'h0 :
                        (sd + 11'd2 >= srad) ? (sp_g ? 4'hA : 4'h9) :
                        (sp_t < 3'd4) ? ((x[1] ^ y[1]) ? 4'hF : 4'h2) : 4'h0;
    reg in_b_q = 0;
    reg b_g_q = 0;
    reg [2:0] bc_q = 0;
    reg [2:0] br_q = 0;
    reg [3:0] sp_q = 0;
    always @ (posedge clk) begin
        in_b_q <= in_b;
        bc_q <= bdx[2:0];
        br_q <= bdy[2:0];
        b_g_q <= b_g;
        sp_q <= sp_pix;
        // row * 6 = row * 4 + row * 2
        if (in_b_q == 1) begin
            if (b_g_q == 1) begin
                shot_idx <= SPR_AMMO_GROW[({br_q, 2'b0} + {br_q, 1'b0} + bc_q) * 4 +: 4];
            end
            else begin
                shot_idx <= SPR_AMMO_SHRINK[({br_q, 2'b0} + {br_q, 1'b0} + bc_q) * 4 +: 4];
            end
        end
        else begin
            shot_idx <= sp_q;
        end
    end

    reg in_gun_q = 0;
    reg [2:0] gc_q = 0;
    reg [2:0] gr_q = 0;
    always @ (posedge clk) begin
        in_gun_q <= in_gun;
        gc_q <= gcol[2:0];
        gr_q <= grow[2:0];
        if (in_gun_q == 1) begin
            gun_idx <= SPR_GUN[({gr_q, 3'b0} + gc_q) * 4 +: 4];
        end
        else begin
            gun_idx <= 4'h0;
        end
        path_idx <= (|dot) ? 4'h2 : 4'h0;
    end

endmodule
