`timescale 1ns / 1ps


module arena_core #(
    parameter SIM_TICK_DIV = 0          // 0 on board (tick every frame), only for sim
    )(
    input clk,
    input rst,
    input [9:0] x,
    input [9:0] y,
    input video_on,
    input [6:0] terrain_in,             // map pixel from redrawn tilemap
    input start,                        // from main menu
    input [6:0] keys1,                  // 0 A, 1 D, 2 Space, 3 Shift, 4 R, 5 Esc, 6 Enter
    input [6:0] keys2,
    input [9:0] m1x,
    input [9:0] m1y,
    input [9:0] m2x,
    input [9:0] m2y,
    input m1l,                          // left = fire
    input m1r,                          // right = freeze
    input m2l,
    input m2r,
    input [8:0] match_sec,
    input inf_ammo,                     // sw4
    output reg [1:0] map,               // 0 bridges, 1 towers

    // crates (engine is in redrawn_core)
    output cr_tick,
    output cr_load_a,
    output cr_load_b,
    output reg signed [11:0] cr_ax,
    output reg signed [11:0] cr_ay,
    output reg signed [11:0] cr_bx,
    output reg signed [11:0] cr_by,
    output reg [1:0] sz_a,              // 0 normal 16, 1 small 8, 2 big 32
    output reg [1:0] sz_b,
    output reg cr_push,
    output reg cr_push_r,
    output reg cr_push_id,
    output [4:0] cr_p1w,                // players' hitbox sizes for the crate engine
    output [4:0] cr_p1h,
    output [4:0] cr_p2w,
    output [4:0] cr_p2h,
    output signed [11:0] cr_p1x,
    output signed [11:0] cr_p1y,
    output signed [11:0] cr_p2x,
    output signed [11:0] cr_p2y,
    input signed [11:0] ca_x,
    input signed [11:0] ca_y,
    input signed [11:0] cb_x,
    input signed [11:0] cb_y,
    output [11:0] rgb,

    output e_tick,
    output e_run1,
    output e_run2,
    output [2:0] e_k1,
    output [2:0] e_k2,
    output e_ld1,
    output e_ld2,
    output signed [11:0] e_sx,
    output signed [11:0] e_sy,
    output e_ln1,
    output e_ln2,
    output e_rq1,
    output e_rq2,
    output [1:0] e_rqs1,
    output [1:0] e_rqs2,
    output e_qs,
    output e_qw,
    input signed [11:0] e_qx,
    input signed [11:0] e_qy,
    input signed [11:0] e1x,
    input signed [11:0] e1y,
    input signed [11:0] e2x,
    input signed [11:0] e2y,
    input [1:0] e1s,
    input [1:0] e2s,
    input eg1,
    input eg2,

    // bounce pads (spring_gfx in redrawn_core)
    output [19:0] sp_x0,                // {pad1, pad0}, 1023 = none
    output [19:0] sp_y0,
    output [5:0] sp_frame,

    // for oled / 7seg / leds
    output [2:0] ui_screen,
    output [8:0] time_left,
    output [4:0] kills1,
    output [4:0] kills2,
    output [1:0] winner,
    output [6:0] hp1,
    output [6:0] hp2,
    output [3:0] af1,
    output [3:0] az1,
    output [3:0] af2,
    output [3:0] az2,
    output alive1,
    output alive2,
    output signed [11:0] p1x,
    output signed [11:0] p1y,
    output signed [11:0] p2x,
    output signed [11:0] p2y,

    // shared angle unit in game_top
    output ang_req,
    output signed [15:0] ang_vx,
    output signed [15:0] ang_vy,
    input ang_ack,
    input [15:0] ang_cz,
    input signed [15:0] ang_s,
    input signed [15:0] ang_c,

    // redraw effect (redraw.v inside redrawn's pixel_gen) when a crate changes size
    output reg rd_start,                // 1 clk: start the effect
    output reg [9:0] rd_cx,             // middle of the crate
    output reg [9:0] rd_cy,
    output reg [6:0] rd_rad,
    input rd_busy,
    input rd_swap,                      // 1 clk in the middle: change the size now
    input [3:0] rd_idx                  // effect pixel, same timing as terrain_in
    );

    `include "arena_data.vh"

    initial begin
        map = 0;
        cr_ax = 0;
        cr_ay = 0;
        cr_bx = 0;
        cr_by = 0;
        sz_a = 0;
        sz_b = 0;
        cr_push = 0;
        cr_push_r = 0;
        cr_push_id = 0;
    end

    // tick once per frame when vblank starts
    // tick = first clock where y >= 480 (start of vblank), so the game
    // updates while nothing is being drawn. sim_cnt only used in sim
    reg vb_q = 0;
    reg [20:0] sim_cnt = 0;
    always @ (posedge clk) begin
        vb_q <= (y >= 10'd480);
        if (sim_cnt == SIM_TICK_DIV - 1) begin
            sim_cnt <= 0;
        end
        else begin
            sim_cnt <= sim_cnt + 1;
        end
    end
    wire tick = (SIM_TICK_DIV == 0) ? ((y >= 10'd480) && !vb_q) : (sim_cnt == 0);

    wire ev_dead1;
    wire ev_dead2;
    wire gs_run;
    wire gs_reset;
    wire spawn1;
    wire spawn2;
    wire ui_sel;
    wire by_quit;
    wire [1:0] ui_count;
    wire [1:0] pause_owner;
    wire ui_map;

    // match fsm
    match_fsm u_fsm (
        .clk(clk), .rst(rst), .tick(tick), .keys1(keys1), .keys2(keys2),
        .ev_dead1(ev_dead1), .ev_dead2(ev_dead2), .match_sec(match_sec), .start(start),
        .gs_run(gs_run), .gs_reset(gs_reset), .spawn1(spawn1), .spawn2(spawn2),
        .alive1(alive1), .alive2(alive2), .ui_screen(ui_screen), .ui_count(ui_count),
        .ui_sel(ui_sel), .pause_owner(pause_owner), .time_left(time_left),
        .kills1(kills1), .kills2(kills2), .winner(winner), .by_quit(by_quit), .ui_map(ui_map));

    // map follows the choice on map screen (5)
    // map only changes on the map screen or at a new match, never mid game
    always @ (posedge clk) begin
        if (gs_reset == 1 || ui_screen == 3'd5) begin
            map <= {1'b0, ui_map};
        end
    end

    reg cqa_b = 0;
    reg cqb_b = 0;
    wire b_chk;
    wire b_chk_frz;
    wire b_chk_hitp;

    wire load1;
    wire load2;
    wire signed [11:0] sx;
    wire signed [11:0] sy;
    spawn_picker u_spawn (.clk(clk), .rst(rst), .req1(spawn1), .req2(spawn2), .map(map),
        .p1x(p1x), .p1y(p1y), .p2x(p2x), .p2y(p2y),
        .load1(load1), .load2(load2), .sx(sx), .sy(sy));

    wire frz1;
    wire frz2;
    // can move only if playing, alive and not frozen
    // frozen player still falls (tick still runs physics), just no keys
    wire can1 = gs_run && alive1 && !frz1;
    wire can2 = gs_run && alive2 && !frz2;

    reg ln1 = 0;                // pad launch
    reg ln2 = 0;
    wire og1 = eg1;
    wire og2 = eg2;
    // player sizes (6 Nov): any shot that hits a player resizes them (own shot
    // only after a mirror bounce, and it does no damage),
    // fire = one size bigger, freeze = one size smaller (small / normal / big)
    wire [1:0] psz1 = e1s;      // size now, 0 normal 1 small 2 big
    wire [1:0] psz2 = e2s;
    function [5:0] f_w6;
        input [1:0] z;
        begin
            f_w6 = (z == 2'd1) ? 6'd6 : (z == 2'd2) ? 6'd24 : 6'd12;
        end
    endfunction
    function [5:0] f_h6;
        input [1:0] z;
        begin
            f_h6 = (z == 2'd1) ? 6'd7 : (z == 2'd2) ? 6'd28 : 6'd14;
        end
    endfunction
    wire [5:0] w1 = f_w6(psz1);  // hitbox size now
    wire [5:0] h1 = f_h6(psz1);
    wire [5:0] w2 = f_w6(psz2);
    wire [5:0] h2 = f_h6(psz2);
    reg rq1 = 0;
    reg rq2 = 0;
    reg [1:0] rqs1 = 0;
    reg [1:0] rqs2 = 0;
    wire hf1;                   // hit by fire
    wire hz1;                   // hit by freeze
    wire hf2;
    wire hz2;
    wire sfa1;                  // own fire shot hit p1 (grow)
    wire sza1;                  // own freeze shot hit p1 (shrink)
    wire sfa2;
    wire sza2;
    // one step: grow small -> normal -> big, shrink big -> normal -> small
    function [1:0] grow;
        input [1:0] z;
        begin
            grow = (z == 2'd1) ? 2'd0 : 2'd2;
        end
    endfunction
    function [1:0] shrink;
        input [1:0] z;
        begin
            shrink = (z == 2'd2) ? 2'd0 : 2'd1;
        end
    endfunction
    always @ (posedge clk) begin
        // own bounced shot (no damage) or the other player's shot (damage too, sp 6 Nov)
        rq1 <= sfa1 || sza1 || hf1 || hz1;
        rq2 <= sfa2 || sza2 || hf2 || hz2;
        rqs1 <= (sfa1 || hf1) ? grow(psz1) : shrink(psz1);
        rqs2 <= (sfa2 || hf2) ? grow(psz2) : shrink(psz2);
    end

    assign p1x = e1x;
    assign p1y = e1y;
    assign p2x = e2x;
    assign p2y = e2y;
    assign e_tick = tick;
    assign e_run1 = gs_run && alive1;
    assign e_run2 = gs_run && alive2;
    assign e_k1 = {can1 && keys1[2], can1 && keys1[1], can1 && keys1[0]};
    assign e_k2 = {can2 && keys2[2], can2 && keys2[1], can2 && keys2[0]};
    assign e_ld1 = load1;
    assign e_ld2 = load2;
    assign e_sx = sx;
    assign e_sy = sy;
    assign e_ln1 = ln1;
    assign e_ln2 = ln2;
    assign e_rq1 = rq1;
    assign e_rq2 = rq2;
    assign e_rqs1 = rqs1;
    assign e_rqs2 = rqs2;

    level_collision_a2 u_col12 (.clk(clk), .map(map), .ax(e_qx), .ay(e_qy), .a_solid(e_qs), .a_boundary(),
        .bx(12'sd0), .by(12'sd0), .b_solid(), .b_boundary(), .a_water(e_qw), .b_water());

    // bounce pads, 2 per map
    // rest = frame 4, stand on it -> launch, pops 3 2 1 0 then back to 4
    // pc counts ticks after a launch, pfr turns that into the frame
    // 0-19, then back to 0 = ready again
    reg [4:0] pc0 = 0;          // pop counter, 0 = ready
    reg [4:0] pc1 = 0;

    // pop counter -> spring frame
    function [2:0] pfr;
        input [4:0] c;
        begin
            if (c == 0)
                pfr = 3'd4;
            else if (c <= 1)
                pfr = 3'd3;
            else if (c <= 2)
                pfr = 3'd2;
            else if (c <= 3)
                pfr = 3'd1;
            else if (c <= 7)
                pfr = 3'd0;
            else if (c <= 10)
                pfr = 3'd1;
            else if (c <= 13)
                pfr = 3'd2;
            else if (c <= 16)
                pfr = 3'd3;
            else
                pfr = 3'd4;
        end
    endfunction

    // pad spots for this map, {map, n} = index into the table
    wire [9:0] px0 = aspr_x({map, 1'b0});
    wire [9:0] py0 = aspr_y({map, 1'b0});
    wire [9:0] px1 = aspr_x({map, 1'b1});
    wire [9:0] py1 = aspr_y({map, 1'b1});
    wire pad_on = (ui_screen != 3'd0) && (ui_screen != 3'd5);
    assign sp_x0 = pad_on ? {px1, px0} : {10'd1023, 10'd1023};
    assign sp_y0 = pad_on ? {py1, py0} : {10'd1023, 10'd1023};
    assign sp_frame = {pfr(pc1), pfr(pc0)};

    // standing on pad: on ground, feet at pad top (box y + 64), overlapping in x
    // bx, by = pad box top left, top of the spring is 64 px down,
    // hy + 14 = player's feet
    function on_pad;
        input [9:0] bx;
        input [9:0] by;
        input signed [11:0] hx;
        input signed [11:0] hy;
        input og;
        input al;
        input [5:0] w;
        input [5:0] h;
        begin
            on_pad = al && og && (bx != 10'd1023) && (hy + $signed({6'd0, h}) == $signed({2'b0, by}) + 12'sd64) &&
                     (hx < $signed({2'b0, bx}) + 12'sd64) && (hx + $signed({6'd0, w}) > $signed({2'b0, bx}));
        end
    endfunction

    wire s10 = on_pad(px0, py0, p1x, p1y, og1, alive1, w1, h1);    // p1 on pad 0
    wire s20 = on_pad(px0, py0, p2x, p2y, og2, alive2, w2, h2);    // p2 on pad 0
    wire s11 = on_pad(px1, py1, p1x, p1y, og1, alive1, w1, h1);
    wire s21 = on_pad(px1, py1, p2x, p2y, og2, alive2, w2, h2);

    always @ (posedge clk) begin
        ln1 <= 0;
        ln2 <= 0;
        if (gs_reset == 1) begin
            pc0 <= 0;
            pc1 <= 0;
        end
        else if (tick == 1 && gs_run == 1) begin
            // pad 0
            if (pc0 == 0) begin
                if (s10 == 1 || s20 == 1) begin
                    pc0 <= 1;
                    if (s10 == 1) begin
                        ln1 <= 1;
                    end
                    if (s20 == 1) begin
                        ln2 <= 1;
                    end
                end
            end
            else if (pc0 >= 19) begin
                pc0 <= 0;
            end
            else begin
                pc0 <= pc0 + 1;
            end
            // pad 1
            if (pc1 == 0) begin
                if (s11 == 1 || s21 == 1) begin
                    pc1 <= 1;
                    if (s11 == 1) begin
                        ln1 <= 1;
                    end
                    if (s21 == 1) begin
                        ln2 <= 1;
                    end
                end
            end
            else if (pc1 >= 19) begin
                pc1 <= 0;
            end
            else begin
                pc1 <= pc1 + 1;
            end
        end
    end

    // sprite top left from the hitbox, bottoms line up:
    //   normal sprite 16 x 16, hitbox 12 x 14 -> 2 px up / left
    //   small  sprite  8 x 8,  hitbox  6 x 7  -> 1 px
    //   big    sprite 32 x 32, hitbox 24 x 28 -> 4 px
    function [9:0] sofs;
        input [1:0] z;
        begin
            sofs = (z == 2'd1) ? 10'd1 : (z == 2'd2) ? 10'd4 : 10'd2;
        end
    endfunction
    wire [9:0] s1x = p1x[9:0] - sofs(psz1);
    wire [9:0] s1y = p1y[9:0] - sofs(psz1);
    wire [9:0] s2x = p2x[9:0] - sofs(psz2);
    wire [9:0] s2y = p2y[9:0] - sofs(psz2);
    // gun is held at the body middle: aim_gun2 thinks in a 16 x 16 box, so give
    // it the top left of a 16 x 16 box around the hitbox middle
    wire [9:0] g1x = p1x[9:0] + {4'd0, w1[5:1]} - 10'd8;
    wire [9:0] g1y = p1y[9:0] + {4'd0, h1[5:1]} - 10'd8;
    wire [9:0] g2x = p2x[9:0] + {4'd0, w2[5:1]} - 10'd8;
    wire [9:0] g2y = p2y[9:0] + {4'd0, h2[5:1]} - 10'd8;
    wire vis1 = alive1 && (ui_screen != 3'd0) && (ui_screen != 3'd5);
    wire vis2 = alive2 && (ui_screen != 3'd0) && (ui_screen != 3'd5);

    // aim, 1 shared angle unit for both
    wire [3:0] gun1_idx;
    wire [3:0] gun2_idx;
    wire face1;
    wire face2;
    wire signed [15:0] c1;
    wire signed [15:0] s1;
    wire signed [15:0] c2;
    wire signed [15:0] s2;
    wire [9:0] mz1x;
    wire [9:0] mz1y;
    wire [9:0] mz2x;
    wire [9:0] mz2y;
    // aim_gun2: angle from player to mouse, gun sprite, gun tip (mz)
    // and cos / sin (c, s) for the shot direction
    aim_gun2 u_aim (.clk(clk), .x(x), .y(y), .upd(tick), .m1x(m1x), .m1y(m1y), .m2x(m2x), .m2y(m2y),
        .vis1(vis1), .vis2(vis2), .p1x(g1x), .p1y(g1y), .p2x(g2x), .p2y(g2y),
        .gun1_idx(gun1_idx), .gun2_idx(gun2_idx), .face1(face1), .face2(face2),
        .c1(c1), .s1(s1), .c2(c2), .s2(s2), .mz1x(mz1x), .mz1y(mz1y), .mz2x(mz2x), .mz2y(mz2y),
        .ang_req(ang_req), .ang_vx(ang_vx), .ang_vy(ang_vy), .ang_ack(ang_ack), .ang_cz(ang_cz),
        .ang_s(ang_s), .ang_c(ang_c));

    // hp, ammo, shooting
    wire pk1;                   // took ammo box
    wire pk2;
    wire sf1;                   // shoot fire
    wire sz1;                   // shoot freeze
    wire sf2;
    wire sz2;
    // m1l / m1r = mouse 1 left / right, m2 = mouse 2 (from the link)
    player_stats u_st1 (.clk(clk), .tick(tick), .run(gs_run), .spawn(spawn1), .alive(alive1),
        .btn_fire(m1l), .btn_freeze(m1r),
        .hit_fire(hf1), .hit_freeze(hz1), .pickup(pk1), .inf_ammo(inf_ammo),
        .hp(hp1), .ammo_fire(af1), .ammo_freeze(az1), .frozen(frz1),
        .ev_dead(ev_dead1), .shoot_fire(sf1), .shoot_freeze(sz1));
    player_stats u_st2 (.clk(clk), .tick(tick), .run(gs_run), .spawn(spawn2), .alive(alive2),
        .btn_fire(m2l), .btn_freeze(m2r),
        .hit_fire(hf2), .hit_freeze(hz2), .pickup(pk2), .inf_ammo(inf_ammo),
        .hp(hp2), .ammo_fire(af2), .ammo_freeze(az2), .frozen(frz2),
        .ev_dead(ev_dead2), .shoot_fire(sf2), .shoot_freeze(sz2));

    // shots
    wire signed [11:0] qbx;
    wire signed [11:0] qby;
    wire qbs;
    wire qbb;
    wire [3:0] b_on;
    wire [3:0] b_frz;
    wire [39:0] b_x;
    wire [39:0] b_y;
    wire sk_on;                 // hit spark
    wire sk_frz;
    wire [2:0] sk_t;
    wire [9:0] sk_x;
    wire [9:0] sk_y;
    wire qbm;                   // mirror tile
    wire qbv;                   // mirror is vertical
    // crates count as solid, a mirror under a crate doesnt bounce
    bullets u_bullets (.clk(clk), .reset(gs_reset), .tick(tick), .run(gs_run),
        .shoot_fire1(sf1), .shoot_freeze1(sz1), .shoot_fire2(sf2), .shoot_freeze2(sz2),
        .mz1x(mz1x), .mz1y(mz1y), .mz2x(mz2x), .mz2y(mz2y), .c1(c1), .s1(s1), .c2(c2), .s2(s2),
        .p1x(p1x), .p1y(p1y), .p2x(p2x), .p2y(p2y), .alive1(alive1), .alive2(alive2),
        .w1(w1), .h1(h1), .w2(w2), .h2(h2),
        .self_fire1(sfa1), .self_freeze1(sza1), .self_fire2(sfa2), .self_freeze2(sza2),
        .col_px(qbx), .col_py(qby), .col_solid(qbs | cqa_b | cqb_b), .col_bnd(qbb),
        .col_mir(qbm & ~cqa_b & ~cqb_b), .col_mvert(qbv),
        .hit_fire1(hf1), .hit_freeze1(hz1), .hit_fire2(hf2), .hit_freeze2(hz2),
        .b_on(b_on), .b_frz(b_frz), .b_x(b_x), .b_y(b_y),
        .chk(b_chk), .chk_frz(b_chk_frz), .chk_hitp(b_chk_hitp),
        .sk_on(sk_on), .sk_frz(sk_frz), .sk_t(sk_t), .sk_x(sk_x), .sk_y(sk_y));

    // map lookup for shots (port b not used)
    level_collision_a2 u_colbm (.clk(clk), .map(map), .ax(qbx), .ay(qby), .a_solid(qbs), .a_boundary(qbb),
        .bx(12'sd0), .by(12'sd0), .b_solid(), .b_boundary(), .a_mir(qbm), .a_mvert(qbv));

    // ammo boxes
    wire k0_on;
    wire k1_on;
    wire [9:0] k0_x;
    wire [9:0] k0_y;
    wire [9:0] k1_x;
    wire [9:0] k1_y;
    pickups u_pick (.clk(clk), .reset(gs_reset), .tick(tick), .run(gs_run), .map(map),
        .p1x(p1x), .p1y(p1y), .p2x(p2x), .p2y(p2y), .alive1(alive1), .alive2(alive2),
        .w1(w1), .h1(h1), .w2(w2), .h2(h2),
        .pick1(pk1), .pick2(pk2), .on0(k0_on), .on1(k1_on),
        .x0(k0_x), .y0(k0_y), .x1(k1_x), .y1(k1_y));

    // crates, 2 per map, normal size at match start
    // small crate only solid for shots
    // fire shot -> bigger, freeze shot -> smaller, keeps bottom centre

    // crate width from size
    // width (= height) of a crate in px from its size
    function [5:0] cw;
        input [1:0] sz;
        begin
            case (sz)
                2'd2: cw = 6'd32;
                2'd1: cw = 6'd8;
                default: cw = 6'd16;
            endcase
        end
    endfunction

    // point inside crate
    function in_box;
        input signed [11:0] qx;
        input signed [11:0] qy;
        input signed [11:0] bx;
        input signed [11:0] by;
        input [1:0] sz;
        begin
            in_box = (qx >= bx) && (qx < bx + $signed({6'd0, cw(sz)})) &&
                     (qy >= by) && (qy < by + $signed({6'd0, cw(sz)}));
        end
    endfunction

    // crate overlaps player hitbox (pw x ph)
    function hits_pl;
        input signed [11:0] bx;
        input signed [11:0] by;
        input [5:0] w;
        input signed [11:0] px;
        input signed [11:0] py;
        input al;
        input [5:0] pw;
        input [5:0] ph;
        begin
            hits_pl = al && (bx < px + $signed({6'd0, pw})) && (bx + $signed({6'd0, w}) > px) &&
                      (by < py + $signed({6'd0, ph})) && (by + $signed({6'd0, w}) > py);
        end
    endfunction

    // sz 1 = tiny crate: normal / big players walk through it (and kick it),
    // a small player stops against it, like single player. shots still hit it
    wire crates_on = (ui_screen != 3'd0) && (ui_screen != 3'd5);    // not on menu / map screen
    wire sa = crates_on && (sz_a != 2'd1);      // solid for normal / big players
    wire sb = crates_on && (sz_b != 2'd1);
    wire sm1 = (psz1 == 2'd1);                  // player is small
    wire sm2 = (psz2 == 2'd1);

    // registered because the map memory answer also takes 1 clock
    always @ (posedge clk) begin
        cqa_b <= crates_on && in_box(qbx, qby, ca_x, ca_y, sz_a);
        cqb_b <= crates_on && in_box(qbx, qby, cb_x, cb_y, sz_b);
    end

    // crate engine only runs while playing (pause freezes crates too)
    assign cr_tick = tick && gs_run;
    // dead player moved far away so crates ignore him
    assign cr_p1w = w1[4:0];
    assign cr_p1h = h1[4:0];
    assign cr_p2w = w2[4:0];
    assign cr_p2h = h2[4:0];
    assign cr_p1x = (alive1 == 1) ? p1x : 12'sd2000;
    assign cr_p1y = (alive1 == 1) ? p1y : 12'sd2000;
    assign cr_p2x = (alive2 == 1) ? p2x : 12'sd2000;
    assign cr_p2y = (alive2 == 1) ? p2y : 12'sd2000;

    // pushing, player 0-1 px from crate side and walking into it
    // adj = {touching, crate on right}
    // gr / gl = gap between player side and crate side, 0 or 1 = touching
    function [1:0] adj;
        input signed [11:0] px;
        input signed [11:0] py;
        input signed [11:0] bx;
        input signed [11:0] by;
        input [5:0] w;
        input [5:0] pw;                     // player hitbox size
        input [5:0] ph;
        reg signed [11:0] ws;
        reg signed [11:0] gr;
        reg signed [11:0] gl;
        begin
            ws = $signed({6'd0, w});
            gr = bx - (px + $signed({6'd0, pw}));   // gap if crate on right
            gl = px - (bx + ws);            // gap if crate on left
            adj[0] = (gr >= 0) && (gr <= 1);
            adj[1] = ((gr >= 0 && gr <= 1) || (gl >= 0 && gl <= 1)) && (py < by + ws) && (py + $signed({6'd0, ph}) > by);
        end
    endfunction

    wire [1:0] a1a = adj(p1x, p1y, ca_x, ca_y, cw(sz_a), w1, h1);
    wire [1:0] a1b = adj(p1x, p1y, cb_x, cb_y, cw(sz_b), w1, h1);
    wire [1:0] a2a = adj(p2x, p2y, ca_x, ca_y, cw(sz_a), w2, h2);
    wire [1:0] a2b = adj(p2x, p2y, cb_x, cb_y, cw(sz_b), w2, h2);
    wire w1r = can1 && keys1[1] && !keys1[0];      // p1 walking right
    wire w1l = can1 && keys1[0] && !keys1[1];
    wire w2r = can2 && keys2[1] && !keys2[0];
    wire w2l = can2 && keys2[0] && !keys2[1];
    // push only if walking towards the crate (right key and crate on right)
    // a small player never pushes (like single player)
    wire p1a = !sm1 && sa && a1a[1] && (a1a[0] ? w1r : w1l);   // p1 pushes crate a
    wire p1b = !sm1 && sb && a1b[1] && (a1b[0] ? w1r : w1l);
    wire p2a = !sm2 && sa && a2a[1] && (a2a[0] ? w2r : w2l);
    wire p2b = !sm2 && sb && a2b[1] && (a2b[0] ? w2r : w2l);

    // p1 first, crate a first
    // engine can only push 1 crate per clock: cr_push_id 0 = crate a,
    // 1 = crate b, cr_push_r 1 = push to the right
    always @ (posedge clk) begin
        cr_push <= p1a || p1b || p2a || p2b;
        cr_push_id <= !(p1a || (!p1b && p2a));
        if (p1a == 1) begin
            cr_push_r <= a1a[0];
        end
        else if (p1b == 1) begin
            cr_push_r <= a1b[0];
        end
        else if (p2a == 1) begin
            cr_push_r <= a2a[0];
        end
        else begin
            cr_push_r <= a2b[0];
        end
    end

    // resize when shot hits crate
    // b_chk_hitp = shot hit a player or left the screen, not a crate
    wire hit_a = b_chk && !b_chk_hitp && cqa_b;
    wire hit_b = b_chk && !b_chk_hitp && !cqa_b && cqb_b;
    // like single player: a hit starts the redraw effect, the size really changes at
    // its middle (rd_swap), when the crate is hidden under the checks.
    // rp_* = the hit waiting for that. if the effect is already busy (2 hits close
    // together) the new hit just resizes straight away, no effect
    reg rp_on = 0;              // a resize is waiting for rd_swap
    reg rp_a = 0;               // which crate (1 = a)
    reg rp_frz = 0;             // freeze shot (shrink)
    wire sw_go = rp_on && rd_swap;
    wire live = (hit_a || hit_b) && !sw_go;
    wire sel_a = sw_go ? rp_a : hit_a;
    wire frz_h = sw_go ? rp_frz : b_chk_frz;
    wire [1:0] sz_h = (sel_a == 1) ? sz_a : sz_b;
    wire signed [11:0] hx = (sel_a == 1) ? ca_x : cb_x;
    wire signed [11:0] hy = (sel_a == 1) ? ca_y : cb_y;
    // fire 1 -> 0 -> 2, freeze 2 -> 0 -> 1
    wire [1:0] sz_n = frz_h ? ((sz_h == 2'd2) ? 2'd0 : 2'd1) : ((sz_h == 2'd1) ? 2'd0 : 2'd2);
    // bigger of old / new width, for the effect size
    wire [5:0] wold = cw(sz_h);
    wire [5:0] wbig = (wold > cw(sz_n)) ? wold : cw(sz_n);

    initial begin
        rd_start = 0;
        rd_cx = 0;
        rd_cy = 0;
        rd_rad = 0;
    end
    always @ (posedge clk) begin
        rd_start <= 0;
        if (gs_reset == 1) begin
            rp_on <= 0;
        end
        else if (sw_go == 1) begin
            rp_on <= 0;
        end
        else if (live && !rd_busy && !rp_on && sz_n != sz_h) begin
            // start the effect over the crate, middle of its old box
            rp_on <= 1;
            rp_a <= hit_a;
            rp_frz <= b_chk_frz;
            rd_start <= 1;
            rd_cx <= hx[9:0] + {5'd0, wold[5:1]};
            rd_cy <= hy[9:0] + {4'd0, wold} - {5'd0, wbig[5:1]};   // bottom stays, middle of the bigger box
            // same size rule as the editor: big/2 + big/4 + 4
            rd_rad <= {2'd0, wbig[5:1]} + {3'd0, wbig[5:2]} + 7'd4;
        end
    end
    // dw = old width - new width, move top left by dw/2 in x and dw in y
    // so the crate keeps its bottom middle (stays on the floor)
    wire signed [11:0] dw = $signed({6'd0, cw(sz_h)}) - $signed({6'd0, cw(sz_n)});   // old - new
    wire signed [11:0] nx0 = hx + (dw >>> 1);
    wire signed [11:0] ny0 = hy + dw;

    // new spot registered first, player check next clk (timing)
    // split over 2 clocks so the long add + compare path is shorter (timing)
    reg rq_go = 0;
    reg rq_a = 0;
    reg rq_grow = 0;
    reg signed [11:0] nx = 0;
    reg signed [11:0] ny = 0;
    reg [1:0] rq_sz = 0;
    always @ (posedge clk) begin
        // resize now: at the effect middle, or a hit while the effect is busy
        rq_go <= (sw_go || (live && (rd_busy || rp_on))) && (sz_n != sz_h);
        rq_a <= sel_a;
        rq_grow <= (dw < 0);
        nx <= nx0;
        ny <= ny0;
        rq_sz <= sz_n;
    end

    // dont grow into a player
    // growing into a player would trap them, so it is just ignored
    wire grow_blocked = hits_pl(nx, ny, cw(rq_sz), p1x, p1y, alive1, w1, h1) || hits_pl(nx, ny, cw(rq_sz), p2x, p2y, alive2, w2, h2);
    wire do_rs = rq_go && !(rq_grow && grow_blocked);

    // ld0 = 1 clock after gs_reset (map is set by then), ld1 = 1 more,
    // the engine loads the new spot / size the clock after they are set
    reg ld0 = 0;
    reg ld1 = 0;
    reg rs_a = 0;
    reg rs_b = 0;
    always @ (posedge clk) begin
        ld0 <= gs_reset;
        ld1 <= ld0;
        rs_a <= 0;
        rs_b <= 0;
        if (ld0 == 1) begin
            // new match, crates back to start (map already set)
            cr_ax <= {2'b00, crate_x({map, 1'b0})};
            cr_ay <= {2'b00, crate_y({map, 1'b0})};
            cr_bx <= {2'b00, crate_x({map, 1'b1})};
            cr_by <= {2'b00, crate_y({map, 1'b1})};
            sz_a <= 0;
            sz_b <= 0;
        end
        else if (do_rs == 1 && rq_a == 1) begin
            cr_ax <= nx;
            cr_ay <= ny;
            sz_a <= rq_sz;
            rs_a <= 1;
        end
        else if (do_rs == 1) begin
            cr_bx <= nx;
            cr_by <= ny;
            sz_b <= rq_sz;
            rs_b <= 1;
        end
    end
    assign cr_load_a = ld1 || rs_a;
    assign cr_load_b = ld1 || rs_b;

    // picture
    // everything that is drawn goes in here
    arena_render u_render (
        .clk(clk), .x(x), .y(y), .video_on(video_on), .terrain_in(terrain_in),
        .vis1(vis1), .vis2(vis2), .p1x(s1x), .p1y(s1y), .p2x(s2x), .p2y(s2y),
        .face1(face1), .face2(face2), .frz1(frz1), .frz2(frz2),
        .gun1_idx(gun1_idx), .gun2_idx(gun2_idx),
        .m1x(m1x), .m1y(m1y), .m2x(m2x), .m2y(m2y),
        .b_on(b_on), .b_frz(b_frz), .b_x(b_x), .b_y(b_y),
        .k0_on(k0_on), .k1_on(k1_on), .k0_x(k0_x), .k0_y(k0_y), .k1_x(k1_x), .k1_y(k1_y),
        .map(map),
        .cr_on(crates_on), .ca_x(ca_x[9:0]), .ca_y(ca_y[9:0]), .cb_x(cb_x[9:0]), .cb_y(cb_y[9:0]),
        .sz_a(sz_a), .sz_b(sz_b),
        .hp1(hp1), .hp2(hp2), .af1(af1), .az1(az1), .af2(af2), .az2(az2),
        .kills1(kills1), .kills2(kills2), .time_left(time_left),
        .ui_screen(ui_screen), .ui_count(ui_count), .ui_sel(ui_sel), .ui_map(ui_map), .pause_owner(pause_owner),
        .winner(winner), .by_quit(by_quit),
        .psz1(psz1), .psz2(psz2), .sk_on(sk_on), .sk_frz(sk_frz), .sk_t(sk_t), .sk_x(sk_x), .sk_y(sk_y), .rd_idx(rd_idx),
        .rgb(rgb));

endmodule
