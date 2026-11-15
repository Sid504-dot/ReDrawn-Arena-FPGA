`timescale 1ns / 1ps


module redrawn_core(
    input clk,
    input btnC,                         // reset
    input [9:0] x,
    input [9:0] y,
    input video_on,
    input active,                       // 1 = this game is on screen (mouse and keys reach it)
    input [9:0] mx,
    input [9:0] my,
    input mleft,
    input mright,
    input key_l,
    input key_r,
    input key_jump,
    input key_ent,                      // Enter: next level on the clear panel
    input key_rst,                      // R: restart the level

    // arena borrows the tilemap
    input arena_view,                   // 1 = arena on screen, tilemap shows the arena map
    output [6:0] terrain_out,           // tilemap pixel for the arena renderer
    input [19:0] ar_spx0,               // arena bounce pads (spring_gfx box top left)
    input [19:0] ar_spy0,
    input [5:0] ar_spf,                 // and their frames

    // arena borrows the crate engine (phys_box2)
    input [1:0] ar_map,                 // arena map (tilemap slot 8 + map)
    input ar_tick,                      // 1 clk per arena frame while a match runs
    input ar_load_a,                    // (re)place an arena crate...
    input ar_load_b,
    input signed [11:0] ar_ax,          // ...at this sprite top left
    input signed [11:0] ar_ay,
    input signed [11:0] ar_bx,
    input signed [11:0] ar_by,
    input [1:0] ar_sza,                 // ...with this size (0 normal, 1 small, 2 big)
    input [1:0] ar_szb,
    input ar_push,                      // a player pushes a crate
    input ar_push_r,
    input ar_push_id,
    input [4:0] ar_p1w,                 // arena players' hitbox sizes (they can be resized)
    input [4:0] ar_p1h,
    input [4:0] ar_p2w,
    input [4:0] ar_p2h,
    input signed [11:0] ar_p1x,         // arena players' hitboxes, top left
    input signed [11:0] ar_p1y,
    input signed [11:0] ar_p2x,
    input signed [11:0] ar_p2y,
    output signed [11:0] ar_cax,        // arena crates' sprite top left
    output signed [11:0] ar_cay,
    output signed [11:0] ar_cbx,
    output signed [11:0] ar_cby,

    input ar_etick,
    input ar_run1,
    input ar_run2,
    input [2:0] ar_k1,
    input [2:0] ar_k2,
    input ar_ld1,
    input ar_ld2,
    input signed [11:0] ar_sx,
    input signed [11:0] ar_sy,
    input ar_ln1,
    input ar_ln2,
    input ar_rq1,
    input ar_rq2,
    input [1:0] ar_rqs1,
    input [1:0] ar_rqs2,
    input ar_qs,
    input ar_qw,
    output signed [11:0] ar_qx,
    output signed [11:0] ar_qy,
    output signed [11:0] ar_e1x,
    output signed [11:0] ar_e1y,
    output signed [11:0] ar_e2x,
    output signed [11:0] ar_e2y,
    output [1:0] ar_e1s,
    output [1:0] ar_e2s,
    output ar_eg1,
    output ar_eg2,

    input [11:0] sw,                    // sw0 scale preview, sw1 boxes, sw2 stripes, sw3/4 grow/shrink
    output [11:0] rgb,

    // shared gun angle unit (angle_unit.v in game_top, port a)
    output ang_req,
    output signed [15:0] ang_vx,
    output signed [15:0] ang_vy,
    output ang_zero,
    output ang_ovr_en,
    output [7:0] ang_ovr,
    input ang_ack,
    input [15:0] ang_cz,
    input signed [15:0] ang_s,
    input signed [15:0] ang_c,

    // arena borrows the redraw effect (crate resize in the arena)
    input ar_rd_start,
    input [9:0] ar_rd_cx,
    input [9:0] ar_rd_cy,
    input [6:0] ar_rd_rad,
    output rd_busy,                     // effect running
    output rd_swap,                     // effect middle, 1 clk
    output [3:0] rd_idx                 // effect pixel, same timing as terrain_out
    );

    `include "obj_slots.vh"


    //----------------------------------------------------------------------
    // level clear + single player game fsm
    // PLAY -> flag reached (cleared) -> Enter -> next level ... -> all 7 done = WON
    // done_mask remembers which built-in levels were cleared this run (any order)
    // when all 7 are done the panel says YOU WON and Enter starts a new run at level 1
    //----------------------------------------------------------------------
    reg cleared = 1'b0;                 // flag reached, physics stops, panel shows
    wire go_next;
    wire go_restart;
    wire flag_hit;
    reg [6:0] done_mask = 7'd0;
    wire [2:0] n_done = done_mask[0] + done_mask[1] + done_mask[2] + done_mask[3] + done_mask[4] + done_mask[5] + done_mask[6];
    wire [2:0] n_left = 3'd7 - n_done;
    // only the 7 built-in levels count, clearing the editor level (U1) never wins the run
    wire won = (done_mask == 7'h7F) && cleared && (level < N_BUILT);
    wire [11:0] rgb_pg;                 // pixel_gen's picture, the panel goes on top of it

    // scale -> doors (made in the physics part below)
    wire [13:0] door_open;              // pixel_gen's door animation, physics reads it
    reg scale_loaded = 1'b0;            // enough weight on the scale (see "scale weight")

    // redraw effect handshake (editor <-> pixel_gen)
    // in the arena the arena drives the effect and the editor doesn't see it
    // (otherwise the editor would take the arena's swap pulse as its own)
    wire rd_start;
    wire [9:0] rd_cx;
    wire [9:0] rd_cy;
    wire [6:0] rd_rad;

    // springs
    wire [5:0] spr_frame;
    wire [19:0] spr_top;                // {spring 1, spring 0} platform top row
    wire [11:0] spr_dy;                 // {spring 1, spring 0} signed top movement at the last update
    wire [3:0] spr_state;
    wire spr_launch;
    wire spr_launch_hold;
    wire spr_launch_id;
    wire [6:0] spr_launch_px;           // wanted launch height, physics makes the speed

    // gun shots: bullet hits a crate/player -> editor resizes that slot
    wire shot_hit;
    wire shot_grow;
    wire b_on;
    wire [4:0] shot_slot;
    wire [9:0] b_px;
    wire [9:0] b_py;
    wire [3:0] shot_idx;


    //----------------------------------------------------------------------
    // editor / level manager (holds the object table and the tile ram)
    //----------------------------------------------------------------------
    wire mode_edit;
    wire table_load;                    // 1 clk when a level's table is (re)loaded
    wire brush2;
    wire rect_mode;
    wire sel_on;
    wire sel_bnd;
    wire ghost_on;
    wire ghost_ok;
    wire hov_on;
    wire hov_bad;
    wire val_busy;
    wire [15:0] obj_bad;
    wire [1:0] lvl_bad;
    wire [3:0] level;
    wire [2:0] verified;
    wire [2:0] copy_from;
    wire [3:0] tool;
    wire [1:0] crate_sz;
    // physics write port, driven by the write back fsm at the bottom
    reg phys_req = 1'b0;
    reg [4:0] phys_slot = 5'd0;
    reg [29:0] phys_entry = 30'd0;
    wire phys_ack;
    wire phys_ok;
    wire resize_busy;
    wire [4:0] resize_slot;
    wire [4:0] sel_slot;
    wire [4:0] ghost_slot;
    wire [9:0] hov_x0;
    wire [9:0] hov_y0;
    wire [9:0] hov_x1;
    wire [9:0] hov_y1;
    wire [16*30-1:0] objs;              // the object table, 30 bits per slot
    wire [15:0] t_addr;                 // tile ram port (in pixel_gen's tilemap)
    wire t_we;
    wire [15:0] t_wdata;
    wire [15:0] t_rdata;
    wire [15:0] c_addr;                 // writes into the collision copies
    wire c_we;
    wire [3:0] c_type;

    editor #(.TEST_MOVE(0)) editor_unit (
        .clk(clk),
        .rst(btnC),
        .mx(mx),
        .my(my),
        .mleft(mleft & active),
        .mright(mright & active),
        .y(y),
        .level_cleared(flag_hit),
        .go_next(go_next && !won),
        .go_first(go_next && won),      // all won: Enter goes back to level 1
        .go_restart(go_restart),
        .grow_sw(sw[3]),
        .shrink_sw(sw[4]),
        .btn_l(1'b0),
        .btn_r(1'b0),
        .tmove_step(5'd1),
        .rd_busy(rd_busy && !arena_view),
        .rd_swap(rd_swap && !arena_view),
        .rd_start(rd_start),
        .rd_cx(rd_cx),
        .rd_cy(rd_cy),
        .rd_rad(rd_rad),
        .mode_edit(mode_edit),
        .level(level),
        .copy_from(copy_from),
        .objs(objs),
        .table_load(table_load),
        .tool(tool),
        .crate_sz(crate_sz),
        .brush2(brush2),
        .rect_mode(rect_mode),
        .verified(verified),
        .sel_on(sel_on),
        .sel_slot(sel_slot),
        .ghost_on(ghost_on),
        .ghost_ok(ghost_ok),
        .ghost_slot(ghost_slot),
        .hov_on(hov_on),
        .hov_x0(hov_x0),
        .hov_y0(hov_y0),
        .hov_x1(hov_x1),
        .hov_y1(hov_y1),
        .hov_bad(hov_bad),
        .sel_bnd(sel_bnd),
        .obj_bad(obj_bad),
        .lvl_bad(lvl_bad),
        .val_busy(val_busy),
        .t_addr(t_addr),
        .t_we(t_we),
        .t_wdata(t_wdata),
        .t_rdata(t_rdata),
        .c_addr(c_addr),
        .c_we(c_we),
        .c_type(c_type),
        .phys_req(phys_req),
        .phys_slot(phys_slot),
        .phys_entry(phys_entry),
        .phys_ack(phys_ack),
        .phys_ok(phys_ok),
        .resize_busy(resize_busy),
        .resize_slot(resize_slot),
        .spr_top(spr_top),
        .shot_hit(shot_hit),
        .shot_slot(shot_slot),
        .shot_grow(shot_grow)
        );


    //----------------------------------------------------------------------
    // springs: state, platform tops, launch event for physics
    //----------------------------------------------------------------------
    spring_ctrl spring_unit (
        .clk(clk),
        .y(y),
        .mode_edit(mode_edit),
        .table_load(table_load),
        .objs(objs),
        .frame(spr_frame),
        .spr_top(spr_top),
        .spr_dy(spr_dy),
        .spr_state(spr_state),
        .launch(spr_launch),
        .launch_hold(spr_launch_hold),
        .launch_id(spr_launch_id),
        .launch_px(spr_launch_px)
        );
    wire [16*30-1:0] objs_g = objs;     // (used to be the table with springs masked off)


    //----------------------------------------------------------------------
    // aiming: angle, rotated gun, traced shot path, bullet
    //----------------------------------------------------------------------
    wire [3:0] gun_idx;
    wire [3:0] path_idx;
    wire face_left;
    wire col_busy;                      // aim is using the collision lookup
    wire col_solid;
    wire col_bnd;
    wire col_mir;
    wire col_mvert;
    wire signed [11:0] col_px;
    wire signed [11:0] col_py;
    wire signed [11:0] a_px;
    wire signed [11:0] a_py;
    wire signed [11:0] g_px;
    wire signed [11:0] g_py;
    wire gun_held;
    wire gd_left;
    wire gun_busy;                      // gun is using the collision lookup
    wire gun_dropped;
    wire gun_picked;
    wire gun_err;
    wire [9:0] gd_x;
    wire [9:0] gd_y;
    wire [9:0] clip_l;
    wire [9:0] clip_r;

    aim aim_unit (
        .clk(clk),
        .x(x),
        .y(y),
        .mx(mx),
        .my(my),
        .mode_edit(mode_edit),
        .objs(objs_g),
        .gun_held(gun_held),
        .gd_x(gd_x),
        .gd_y(gd_y),
        .gd_left(gd_left),
        .clip_l(clip_l),
        .clip_r(clip_r),
        .col_px(a_px),
        .col_py(a_py),
        .col_solid(col_solid),
        .col_bnd(col_bnd),
        .col_mir(col_mir),
        .col_mvert(col_mvert),
        .col_busy(col_busy),
        .spr_top(spr_top),
        .door_open(door_open),
        .mleft(mleft & active),
        .mright(mright & active),
        .table_load(table_load),
        .shot_hit(shot_hit),
        .shot_slot(shot_slot),
        .shot_grow(shot_grow),
        .b_on(b_on),
        .b_px(b_px),
        .b_py(b_py),
        .shot_idx(shot_idx),
        .gun_idx(gun_idx),
        .path_idx(path_idx),
        .face_left(face_left),
        .ang_req(ang_req),
        .ang_vx(ang_vx),
        .ang_vy(ang_vy),
        .ang_zero(ang_zero),
        .ang_ovr_en(ang_ovr_en),
        .ang_ovr(ang_ovr),
        .ang_ack(ang_ack),
        .ang_cz(ang_cz),
        .ang_s(ang_s),
        .ang_c(ang_c)
        );

    // who has the gun: boundaries keep it on its side (see gun.v)
    gun gun_unit (
        .clk(clk),
        .y(y),
        .mode_edit(mode_edit),
        .table_load(table_load),
        .objs(objs_g),
        .spr_top(spr_top),
        .door_open(door_open),
        .face_left(face_left),
        .aim_busy(col_busy),
        .busy(gun_busy),
        .col_px(g_px),
        .col_py(g_py),
        .col_solid(col_solid),
        .col_bnd(col_bnd),
        .gun_held(gun_held),
        .gd_x(gd_x),
        .gd_y(gd_y),
        .gd_left(gd_left),
        .clip_l(clip_l),
        .clip_r(clip_r),
        .gun_dropped(gun_dropped),
        .gun_picked(gun_picked),
        .gun_err(gun_err)
        );

    // collision lookup port a: aim first (start of blank), then gun (from row 500)
    assign col_px = gun_busy ? g_px : a_px;
    assign col_py = gun_busy ? g_py : a_py;


    //----------------------------------------------------------------------
    // renderer
    // play_block greys out the play test button: level has bad stuff,
    // check still running, or no player / flag placed
    // (lvl_bad index: level 8 would be U2, which is unused, U1 is level 7)
    //----------------------------------------------------------------------
    pixel_gen pixel_gen_unit (
        .clk(clk),
        .x(x),
        .y(y),
        .video_on(video_on),
        .level(level),
        .copy_from(copy_from),
        .objs(objs_g),
        .table_load(table_load),
        .ghost_on(ghost_on),
        .ghost_ok(ghost_ok),
        .ghost_slot(ghost_slot),
        .mx(mx),
        .my(my),
        .gun_idx(gun_idx),
        .path_idx(path_idx),
        .shot_idx(shot_idx),
        .spr_frame(spr_frame),
        .face_left(face_left),
        .gun_held(gun_held),
        .rd_start(arena_view ? ar_rd_start : rd_start),
        .rd_cx(arena_view ? ar_rd_cx : rd_cx),
        .rd_cy(arena_view ? ar_rd_cy : rd_cy),
        .rd_rad(arena_view ? ar_rd_rad : rd_rad),
        .rd_busy(rd_busy),
        .rd_swap(rd_swap),
        .mode_edit(mode_edit),
        .tool(tool),
        .crate_sz(crate_sz),
        .brush2(brush2),
        .rect_mode(rect_mode),
        .verified(verified),
        .lvl_bad(lvl_bad),
        .obj_bad(obj_bad),
        .sel_on(sel_on),
        .sel_bnd(sel_bnd),
        .sel_slot(sel_slot),
        .play_block(lvl_bad[level == 4'd8] || val_busy || !objs[0*30 + 29] || !objs[1*30 + 29]),
        .hov_on(hov_on),
        .hov_x0(hov_x0),
        .hov_y0(hov_y0),
        .hov_x1(hov_x1),
        .hov_y1(hov_y1),
        .hov_bad(hov_bad),
        .weight_on(sw[0] | scale_loaded),
        .show_boxes(sw[1]),
        .no_stripes(sw[2]),
        .ed_addr(t_addr),
        .ed_we(t_we),
        .ed_wdata(t_wdata),
        .ed_rdata(t_rdata),
        .rgb(rgb_pg),
        .door_open(door_open),
        .arena_view(arena_view),
        .arena_map(ar_map),
        .terrain_out(terrain_out),
        .ar_spx0(ar_spx0),
        .ar_spy0(ar_spy0),
        .ar_spf(ar_spf),
        .redraw_idx(rd_idx)
        );


    //----------------------------------------------------------------------
    // collision copy of the terrain (editor keeps it in sync)
    // port a: aim / gun tracer, port b: the character's physics
    //----------------------------------------------------------------------
    wire signed [11:0] pq_x;
    wire signed [11:0] pq_y;
    wire pq_solid;
    wire pq_water;

    level_collision_dp collision_unit (
        .clk(clk),
        .level(level),
        .ax(col_px),
        .ay(col_py),
        .a_solid(col_solid),
        .a_boundary(col_bnd),
        .a_mirror(col_mir),
        .a_mvert(col_mvert),
        .bx(pq_x),
        .by(pq_y),
        .b_solid(pq_solid),
        .b_water(pq_water),
        .wr_addr(c_addr),
        .wr_en(c_we),
        .wr_type(c_type)
        );


    //======================================================================
    // PHYSICS, connected to the object table
    // table entry k = objs[k*30 +: 30] = {vis, x[9:0], y[9:0], p[8:0]}
    //======================================================================
    wire [29:0] e_pl = objs[SLOT_PLAYER * 30 +: 30];
    wire [29:0] e_fl = objs[SLOT_FLAG * 30 +: 30];
    wire [29:0] e_bx = objs[SLOT_BOX0 * 30 +: 30];            // crate 1
    wire [29:0] e_s0 = objs[SLOT_SPRING0 * 30 +: 30];
    wire [29:0] e_s1 = objs[(SLOT_SPRING0 + 1) * 30 +: 30];
    wire [29:0] e_sc = objs[SLOT_SCALE * 30 +: 30];
    wire [29:0] e_d0 = objs[SLOT_DOOR0 * 30 +: 30];
    wire [29:0] e_d1 = objs[(SLOT_DOOR0 + 1) * 30 +: 30];

    //----------------------------------------------------------------------
    // scale and doors are solid, like blocks of ground
    // scale: its whole 40 x 28 rectangle, so bodies stand on the plate
    //        instead of falling into the notch under it
    // door:  24 px wide, closed = whole door solid (2*H px tall, H in art px)
    //        so even the small character can't slip under. as the panel slides
    //        up (2 px per art px) the solid part shrinks from the bottom, fully
    //        open only the top box (20 px) is left and bodies walk under it
    // the answer is registered so it comes with level_collision's (1 clk)
    //----------------------------------------------------------------------
    wire signed [11:0] sc_x = {2'b00, e_sc[28:19]};
    wire signed [11:0] sc_y = {2'b00, e_sc[18:9]};
    wire signed [11:0] d0_x = {2'b00, e_d0[28:19]};
    wire signed [11:0] d0_y = {2'b00, e_d0[18:9]};
    wire signed [11:0] d1_x = {2'b00, e_d1[28:19]};
    wire signed [11:0] d1_y = {2'b00, e_d1[18:9]};
    // door solid bottom = top + 2*height - 2*open
    wire signed [11:0] d0_b = d0_y + $signed({4'd0, e_d0[8:2], 1'b0}) - $signed({4'd0, door_open[6:0], 1'b0});
    wire signed [11:0] d1_b = d1_y + $signed({4'd0, e_d1[8:2], 1'b0}) - $signed({4'd0, door_open[13:7], 1'b0});

    // is point (qx, qy) inside the scale or a closed part of a door
    function in_scale;
        input signed [11:0] qx;
        input signed [11:0] qy;
        begin
            in_scale = (e_sc[29] && (qx >= sc_x) && (qx < sc_x + 12'sd40) && (qy >= sc_y) && (qy < sc_y + 12'sd28)) ||
                       (e_d0[29] && (qx >= d0_x) && (qx < d0_x + 12'sd24) && (qy >= d0_y) && (qy < d0_b)) ||
                       (e_d1[29] && (qx >= d1_x) && (qx < d1_x + 12'sd24) && (qy >= d1_y) && (qy < d1_b));
        end
    endfunction
    reg sc_pl = 1'b0;                   // character's lookup point is in the scale / a door
    reg sc_bx = 1'b0;                   // crate engine's lookup point is

    // one tick per frame at the start of vertical blank, play mode only
    // stopped on the clear screen, paused during the redraw effect
    reg vb_q = 0;
    always @ (posedge clk) begin
        vb_q <= (y >= 10'd480);
    end
    wire ptick = (y >= 10'd480) && !vb_q && !mode_edit && active && !cleared;
    wire pfreeze = rd_busy;

    reg ar_q = 1'b0;
    always @ (posedge clk) begin
        ar_q <= arena_view;
    end
    wire ar_exit = ar_q && !arena_view;

    // the 2 crates as the other bodies see them (missing crates parked far off screen)
    wire [29:0] e_b2 = objs[(SLOT_BOX0 + 1) * 30 +: 30];      // crate 2
    wire box2_on = e_b2[29];
    wire box_on = e_bx[29];
    wire signed [11:0] b2_ix;           // crate 2 hitbox top left
    wire signed [11:0] b2_iy;
    wire signed [11:0] b2_pbx;          // crate 2 box as the player sees it
    wire signed [11:0] b2_pby;
    wire signed [11:0] b2_bw;           // crate 2 size (square)
    wire signed [11:0] b2_bh;
    wire signed [11:0] bx_ix;           // same for crate 1
    wire signed [11:0] bx_iy;
    wire signed [11:0] bx_pbx;
    wire signed [11:0] bx_pby;
    wire signed [11:0] bx_bw;
    wire signed [11:0] bx_bh;
    wire [1:0] pl_cs;
    wire hide_a = (ar_sza == SZ_SMALL) && (pl_cs != SZ_SMALL);
    wire hide_b = (ar_szb == SZ_SMALL) && (pl_cs != SZ_SMALL);
    wire signed [11:0] c1_px = arena_view ? (hide_a ? -12'sd1000 : bx_ix) : box_on ? bx_pbx : -12'sd1000;
    wire signed [11:0] c1_py = arena_view ? (hide_a ? -12'sd1000 : bx_iy) : box_on ? bx_pby : -12'sd1000;
    wire signed [11:0] c2_px = arena_view ? (hide_b ? -12'sd1000 : b2_ix) : box2_on ? b2_pbx : -12'sd1000;
    wire signed [11:0] c2_py = arena_view ? (hide_b ? -12'sd1000 : b2_iy) : box2_on ? b2_pby : -12'sd1000;


    //----------------------------------------------------------------------
    // the character
    // springs only matter in redrawn (arena has its own pads)
    //----------------------------------------------------------------------
    wire signed [11:0] pl_ix;           // hitbox top left
    wire signed [11:0] pl_iy;
    wire signed [11:0] pl_sx;           // sprite top left (goes back into the table)
    wire signed [11:0] pl_sy;
    wire [4:0] pl_w;
    wire [4:0] pl_h;
    wire [1:0] pl_sz;
    wire pl_og;
    wire push_req;                      // character pushes a crate
    wire push_right;
    wire push_id;                       // which crate
    wire pl_done;
    wire signed [11:0] box_px;
    wire signed [11:0] box_py;
    wire signed [11:0] box_w;
    wire signed [11:0] box_h;

    phys_player u_pl (
        .clk(clk),
        .rst(btnC),
        .tick(arena_view ? ar_etick : ptick),
        .freeze(pfreeze && !arena_view),
        .load((table_load && !arena_view) || ar_exit),
        .size(e_pl[1:0]),
        .act_x({2'b00, e_pl[28:19]}),
        .act_y({2'b00, e_pl[18:9]}),
        .left_i(arena_view ? ar_k1[0] : (key_l & active)),
        .right_i(arena_view ? ar_k1[1] : (key_r & active)),
        .jump_i(arena_view ? ar_k1[2] : (key_jump & active)),
        .ix(pl_ix),
        .iy(pl_iy),
        .spr_x(pl_sx),
        .spr_y(pl_sy),
        .hb_w(pl_w),
        .hb_h(pl_h),
        .on_ground(pl_og),
        .vy(),
        .vx(),
        .q_x(pq_x),
        .q_y(pq_y),
        .q_solid(arena_view ? ar_qs : (pq_solid | sc_pl)),
        .q_water(arena_view ? ar_qw : pq_water),
        .in_water(),
        .bx(box_px),
        .by(box_py),
        .bw(box_w),
        .bh(box_h),
        .bx2(c2_px),
        .by2(c2_py),
        .bw2(b2_bw),
        .bh2(b2_bh),
        .push_req(push_req),
        .push_right(push_right),
        .push_id(push_id),
        .sp0_en(e_s0[29] && !arena_view),
        .sp1_en(e_s1[29] && !arena_view),
        .sp0_x({2'b00, e_s0[28:19]}),
        .sp0_y({2'b00, e_s0[18:9]}),
        .sp1_x({2'b00, e_s1[28:19]}),
        .sp1_y({2'b00, e_s1[18:9]}),
        .spr_top(spr_top),
        .spr_launch(spr_launch),
        .spr_launch_id(spr_launch_id),
        .done(pl_done),
        .arena(arena_view),
        .run_a(ar_run1),
        .run_b(ar_run2),
        .left2_i(ar_k2[0]),
        .right2_i(ar_k2[1]),
        .jump2_i(ar_k2[2]),
        .ld_a(ar_ld1),
        .ld_b(ar_ld2),
        .ld_x(ar_sx),
        .ld_y(ar_sy),
        .lp_a(ar_ln1),
        .lp_b(ar_ln2),
        .rs_a(ar_rq1),
        .rs_b(ar_rq2),
        .rs_sa(ar_rqs1),
        .rs_sb(ar_rqs2),
        .sz_a(pl_sz),
        .ix2(ar_e2x),
        .iy2(ar_e2y),
        .sz_b(ar_e2s),
        .og2(ar_eg2),
        .cur_size(pl_cs)
        );
    assign ar_qx = pq_x;
    assign ar_qy = pq_y;
    assign ar_e1x = pl_ix;
    assign ar_e1y = pl_iy;
    assign ar_e1s = pl_sz;
    assign ar_eg1 = pl_og;


    //----------------------------------------------------------------------
    // the crates (slots 3 and 4, if the level has them)
    //----------------------------------------------------------------------
    wire signed [11:0] bq_x;            // crate engine's collision lookup
    wire signed [11:0] bq_y;
    wire bq_solid;
    wire bq_water;
    wire bx_done;

    always @ (posedge clk) begin
        sc_pl <= in_scale(pq_x, pq_y);
        sc_bx <= in_scale(bq_x, bq_y);
    end

    //----------------------------------------------------------------------
    // scale weight: doors open only with enough weight on the plate
    // weight by size: small 0, normal 1, big 2. loaded at 2 or more
    // (1 big crate, 2 normal crates, big character, or normal character + normal crate)
    // a body counts when its bottom = scale top and it overlaps the scale sideways
    //----------------------------------------------------------------------
    function [1:0] wt;
        input [1:0] sz;
        begin
            wt = (sz == SZ_BIG) ? 2'd2 : (sz == SZ_NORMAL) ? 2'd1 : 2'd0;
        end
    endfunction
    wire pl_on_sc = e_pl[29] && (pl_iy + $signed({7'd0, pl_h}) == sc_y) &&
                    (pl_ix < sc_x + 12'sd40) && (pl_ix + $signed({7'd0, pl_w}) > sc_x);
    wire bx_on_sc = box_on && (bx_iy + bx_bh == sc_y) && (bx_ix < sc_x + 12'sd40) && (bx_ix + bx_bw > sc_x);
    wire b2_on_sc = box2_on && (b2_iy + b2_bh == sc_y) && (b2_ix < sc_x + 12'sd40) && (b2_ix + b2_bw > sc_x);
    wire [2:0] sc_weight = (pl_on_sc ? {1'b0, wt(e_pl[1:0])} : 3'd0) +
                           (bx_on_sc ? {1'b0, wt(e_bx[1:0])} : 3'd0) +
                           (b2_on_sc ? {1'b0, wt(e_b2[1:0])} : 3'd0);
    always @ (posedge clk) begin
        scale_loaded <= e_sc[29] && !mode_edit && !arena_view && (sc_weight >= 3'd2);
    end

    //----------------------------------------------------------------------
    // when to restart a crate's physics from its table entry
    // phys_box2 only reads size / position at load, so after a shot resizes a
    // crate (editor already moved it) it must reload, else it keeps the old size
    // and hangs in the air. same when a crate appears, a level loads, or we
    // leave the arena (the engine was holding the arena crates)
    //----------------------------------------------------------------------
    reg [2:0] bsz_q = 3'd0;
    reg [2:0] b2sz_q = 3'd0;
    always @ (posedge clk) begin
        bsz_q <= {box_on, e_bx[1:0]};
        b2sz_q <= {box2_on, e_b2[1:0]};
    end
    wire bx_reload = table_load || ar_exit || (box_on && {box_on, e_bx[1:0]} != bsz_q);
    wire b2_reload = table_load || ar_exit || (box2_on && {box2_on, e_b2[1:0]} != b2sz_q);

    // arena on screen: every engine input comes from the arena instead
    wire ar = arena_view;
    wire [1:0] sza = ar ? ar_sza : e_bx[1:0];
    wire [1:0] szb = ar ? ar_szb : e_b2[1:0];

    // one engine for both crates, runs them one after the other (saves a whole copy)
    // redrawn: ticks after the character is done. arena: ar_tick
    phys_box2 u_box (
        .clk(clk),
        .rst(btnC),
        .tick(ar ? ar_tick : pl_done),
        .freeze(pfreeze && !ar),
        .load_a(ar ? ar_load_a : bx_reload),
        .load_b(ar ? ar_load_b : b2_reload),
        .en_a(ar || box_on),
        .en_b(ar || box2_on),
        .spawn_ax(ar ? ar_ax : {2'b00, e_bx[28:19]}),
        .spawn_ay(ar ? ar_ay : {2'b00, e_bx[18:9]}),
        .spawn_bx(ar ? ar_bx : {2'b00, e_b2[28:19]}),
        .spawn_by(ar ? ar_by : {2'b00, e_b2[18:9]}),
        .big_a(sza == SZ_BIG),
        .tiny_a(sza == SZ_SMALL),
        .big_b(szb == SZ_BIG),
        .tiny_b(szb == SZ_SMALL),
        .push_req(ar ? ar_push : push_req),
        .push_right(ar ? ar_push_r : push_right),
        .push_id(ar ? ar_push_id : push_id),
        .player_size(ar ? SZ_NORMAL : e_pl[1:0]),
        .plx_i(ar ? ar_p1x : pl_ix),
        .ply_i(ar ? ar_p1y : pl_iy),
        .plw_i(ar ? ar_p1w : pl_w),
        .plh_i(ar ? ar_p1h : pl_h),
        .pl2x_i(ar ? ar_p2x : 12'sd2000),       // redrawn has no 2nd player, park it far away
        .pl2y_i(ar ? ar_p2y : 12'sd2000),
        .pl2w_i(ar_p2w),
        .pl2h_i(ar_p2h),
        .sp0_en(e_s0[29] && !ar),
        .sp1_en(e_s1[29] && !ar),
        .sp0_x({2'b00, e_s0[28:19]}),
        .sp0_y({2'b00, e_s0[18:9]}),
        .sp1_x({2'b00, e_s1[28:19]}),
        .sp1_y({2'b00, e_s1[18:9]}),
        .spr_top(spr_top),
        .spr_launch(spr_launch),
        .spr_launch_id(spr_launch_id),
        .a_ix(bx_ix),
        .a_iy(bx_iy),
        .a_bw(bx_bw),
        .a_pbx(bx_pbx),
        .a_pby(bx_pby),
        .b_ix(b2_ix),
        .b_iy(b2_iy),
        .b_bw(b2_bw),
        .b_pbx(b2_pbx),
        .b_pby(b2_pby),
        .done(bx_done),
        .q_x(bq_x),
        .q_y(bq_y),
        .q_solid(bq_solid | (sc_bx & ~ar)),     // scale / doors only in redrawn
        .q_water(bq_water)
        );
    assign ar_cax = bx_ix;
    assign ar_cay = bx_iy;
    assign ar_cbx = b2_ix;
    assign ar_cby = b2_iy;
    assign bx_bh = bx_bw;               // crates are square
    assign b2_bh = b2_bw;
    wire b2_done = bx_done;

    // crates' own collision copy, also holds the arena maps (slots 8-10)
    level_collision #(.ARENA(1)) u_col_bx (
        .clk(clk),
        .level(ar ? 4'd8 + {2'b00, ar_map} : level),
        .px(bq_x),
        .py(bq_y),
        .solid(bq_solid),
        .water(bq_water),
        .boundary(),
        .mirror(),
        .mvert(),
        .wr_addr(c_addr),
        .wr_en(c_we),
        .wr_type(c_type)
        );
    assign box_px = c1_px;
    assign box_py = c1_py;
    assign box_w = bx_bw;
    assign box_h = bx_bh;


    //----------------------------------------------------------------------
    // flag reached: character sprite overlaps the flag (16 wide x 24 tall, the whole
    // flag down to the ground, so the small character touches it without jumping)
    //----------------------------------------------------------------------
    wire [9:0] pside = (e_pl[1:0] == SZ_SMALL) ? 10'd8 : (e_pl[1:0] == SZ_BIG) ? 10'd32 : 10'd16;
    assign flag_hit = !mode_edit && e_pl[29] && e_fl[29] &&
                      (e_pl[28:19] < e_fl[28:19] + 10'd16) && (e_pl[28:19] + pside > e_fl[28:19]) &&
                      (e_pl[18:9] < e_fl[18:9] + 10'd24) && (e_pl[18:9] + pside > e_fl[18:9]);

    reg ke_q = 1'b0;                    // last Enter / R, for edge detect
    reg kr_q = 1'b0;

    always @ (posedge clk) begin
        if (btnC || table_load || mode_edit) begin
            cleared <= 1'b0;
        end
        else if (flag_hit) begin
            cleared <= 1'b1;
        end
    end

    // tick off this level (built-in levels 0-6 only, not the user level)
    always @ (posedge clk) begin
        if (btnC || (cleared && won && key_ent && !ke_q)) begin
            done_mask <= 7'd0;          // new run
        end
        else if (flag_hit && !cleared && level < 4'd7) begin
            done_mask <= done_mask | (7'd1 << level[2:0]);
        end
    end

    always @ (posedge clk) begin
        ke_q <= key_ent;
        kr_q <= key_rst;
    end
    wire fell = ptick && e_pl[29] && (pl_iy >= 12'sd480);
    // user level (editor): no next level, only R restart
    wire built = (level < N_BUILT);
    assign go_next = active && cleared && built && key_ent && !ke_q;
    assign go_restart = active && !mode_edit && ((key_rst && !kr_q) || fell);


    //----------------------------------------------------------------------
    // the clear panel: box in the middle with 3 text lines
    // text_cell + text_glyph take 2 clk, the box is delayed 2 clk too,
    // then 1 more register lines both up with pixel_gen (3 clk)
    //----------------------------------------------------------------------
    localparam [9:0] CX0 = 10'd200;
    localparam [9:0] CX1 = 10'd439;
    localparam [9:0] CY0 = 10'd196;
    localparam [9:0] CY1 = 10'd307;
    wire [13:0] c_t1;
    wire [13:0] c_t2;
    wire [13:0] c_t3;
    wire c_on;

    text_cell #(.LEN(11), .SHIFT(2)) u_clr1 (
        .clk(clk),
        .x(x),
        .y(y),
        .x0(10'd232),
        .y0(10'd208),
        .str(won ? "YOU WON    " : "LEVEL CLEAR"),
        .en(cleared),
        .cq(c_t1)
        );
    text_cell #(.LEN(21), .SHIFT(1)) u_clr2 (
        .clk(clk),
        .x(x),
        .y(y),
        .x0(10'd236),
        .y0(10'd248),
        .str(won ? "ENTER PLAY AGAIN     " : built ? "ENTER NEXT  R RESTART" : "      R RESTART      "),
        .en(cleared),
        .cq(c_t2)
        );
    // "DONE n  LEFT m", 8'h30 + n turns a number into its ascii digit
    text_cell #(.LEN(14), .SHIFT(1)) u_clr3 (
        .clk(clk),
        .x(x),
        .y(y),
        .x0(10'd264),
        .y0(10'd276),
        .str({"DONE ", 8'h30 + {5'd0, n_done}, "  LEFT ", 8'h30 + {5'd0, n_left}}),
        .en(cleared && built),          // count only for the 7 built-in levels
        .cq(c_t3)
        );
    // one font lookup for all 3 lines (they never overlap)
    text_glyph u_clrf (
        .clk(clk),
        .cq(c_t1 | c_t2 | c_t3),
        .on(c_on)
        );

    reg [1:0] pan_q = 2'd0;
    reg [1:0] edg_q = 2'd0;
    reg pan3 = 1'b0;
    reg edg3 = 1'b0;
    reg txt3 = 1'b0;
    wire in_pan = cleared && x >= CX0 && x <= CX1 && y >= CY0 && y <= CY1;
    wire in_edg = x < CX0 + 3 || x > CX1 - 3 || y < CY0 + 3 || y > CY1 - 3;    // 3 px border
    always @ (posedge clk) begin
        pan_q <= {pan_q[0], in_pan};
        edg_q <= {edg_q[0], in_edg};
        pan3 <= pan_q[1];
        edg3 <= edg_q[1];
        txt3 <= c_on;
    end
    assign rgb = !pan3 ? rgb_pg : (edg3 || txt3) ? 12'h223 : 12'hFFF;


    //----------------------------------------------------------------------
    // write the new positions back into the object table
    // after both crates are done: character, crate 1, crate 2
    // handshake: hold phys_req until phys_ack, then drop it for a clk
    // the size bits (p) are latched with the positions, so if a resize lands
    // before the write the editor sees p differ and throws the old write away
    //----------------------------------------------------------------------
    localparam W_IDLE = 3'd0;
    localparam W_PL   = 3'd1;
    localparam W_GAP  = 3'd2;
    localparam W_BX   = 3'd3;
    localparam W_GAP2 = 3'd4;
    localparam W_B2   = 3'd5;
    localparam W_END  = 3'd6;
    reg [2:0] wst = W_IDLE;
    reg signed [11:0] lat_px;
    reg signed [11:0] lat_py;
    reg signed [11:0] lat_bx;
    reg signed [11:0] lat_by;
    reg signed [11:0] lat_cx;
    reg signed [11:0] lat_cy;
    reg [8:0] lat_pp;
    reg [8:0] lat_bp;
    reg [8:0] lat_cp;

    always @ (posedge clk) begin
        if (btnC || table_load) begin
            wst <= W_IDLE;
            phys_req <= 1'b0;
        end
        else begin
            case (wst)
                W_IDLE: begin
                    // arena crates are never written to the table
                    if (b2_done && !ar) begin
                        lat_px <= pl_sx;
                        lat_py <= pl_sy;
                        lat_bx <= bx_ix;
                        lat_by <= bx_iy;
                        lat_cx <= b2_ix;
                        lat_cy <= b2_iy;
                        lat_pp <= e_pl[8:0];
                        lat_bp <= e_bx[8:0];
                        lat_cp <= e_b2[8:0];
                        wst <= W_PL;
                    end
                end
                W_PL: begin
                    phys_slot <= SLOT_PLAYER;
                    phys_entry <= {1'b1, lat_px[9:0], lat_py[9:0], lat_pp};
                    phys_req <= e_pl[29];
                    if (!e_pl[29]) begin
                        wst <= W_GAP;
                    end
                    else if (phys_ack) begin
                        phys_req <= 1'b0;
                        wst <= W_GAP;
                    end
                end
                W_GAP: begin
                    wst <= W_BX;        // phys_req low for 1 clk
                end
                W_BX: begin
                    phys_slot <= SLOT_BOX0;
                    phys_entry <= {1'b1, lat_bx[9:0], lat_by[9:0], lat_bp};
                    phys_req <= box_on;
                    if (!box_on) begin
                        wst <= W_GAP2;
                    end
                    else if (phys_ack) begin
                        phys_req <= 1'b0;
                        wst <= W_GAP2;
                    end
                end
                W_GAP2: begin
                    wst <= W_B2;
                end
                W_B2: begin
                    phys_slot <= SLOT_BOX0 + 1;
                    phys_entry <= {1'b1, lat_cx[9:0], lat_cy[9:0], lat_cp};
                    phys_req <= box2_on;
                    if (!box2_on) begin
                        wst <= W_END;
                    end
                    else if (phys_ack) begin
                        phys_req <= 1'b0;
                        wst <= W_END;
                    end
                end
                default: begin
                    phys_req <= 1'b0;
                    wst <= W_IDLE;
                end
            endcase
        end
    end

endmodule
