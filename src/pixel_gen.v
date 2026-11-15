`timescale 1ns / 1ps


module pixel_gen(
    input clk,
    input [9:0] x,
    input [9:0] y,
    input video_on,
    input [3:0] level,
    input [2:0] copy_from,
    input [16*30-1:0] objs,             // object table, 30 bits per slot
    input table_load,                   // new table loaded -> snap doors to their end state
    input ghost_on,
    input ghost_ok,
    input [4:0] ghost_slot,
    input [9:0] mx,
    input [9:0] my,

    // from aim.v: rotated gun, aim path, shot
    input [3:0] gun_idx,
    input gun_held,                     // 0 = no gun -> arrow pointer instead of crosshair
    input [3:0] path_idx,
    input [3:0] shot_idx,               // bullet + spark, drawn over the path
    input [5:0] spr_frame,              // spring frames {spring 1, spring 0} from spring_ctrl
    input face_left,

    // redraw effect (editor starts it when something changes size)
    input rd_start,
    input [9:0] rd_cx,
    input [9:0] rd_cy,
    input [6:0] rd_rad,
    output rd_busy,
    output rd_swap,

    // editor ui state, passed on to editor_ui
    input mode_edit,
    input [3:0] tool,
    input [1:0] crate_sz,               // crate tool size (icon on bottom button 5)
    input brush2,
    input rect_mode,
    input [2:0] verified,
    input [1:0] lvl_bad,
    input play_block,
    input [15:0] obj_bad,               // edit mode: these objects get a red tint
    input sel_on,
    input sel_bnd,
    input [4:0] sel_slot,
    input hov_on,
    input [9:0] hov_x0,
    input [9:0] hov_y0,
    input [9:0] hov_x1,
    input [9:0] hov_y1,
    input hov_bad,

    // switches
    input weight_on,                    // scale is loaded (something stands on it)
    input show_boxes,                   // sw1: tint the sprite boxes
    input no_stripes,                   // sw2: plain paper

    // editor access to the tile ram (tilemap port b, only in vertical blank)
    input [15:0] ed_addr,
    input ed_we,
    input [15:0] ed_wdata,
    output [15:0] ed_rdata,

    output reg [11:0] rgb,
    output [13:0] door_open,            // {door 1, door 0}: how far each panel slid up (art px), physics needs it

    // arena borrows this tilemap
    input arena_view,                   // 1 = arena on screen: show slot 8 + arena_map
    input [1:0] arena_map,              // arena map 0-2
    output [6:0] terrain_out,           // {idx[3:0], shadow, water surface, water body}, 2 clk delay
    input [19:0] ar_spx0,               // arena bounce pads, drawn by the spring renderer in the arena
    input [19:0] ar_spy0,
    input [5:0] ar_spf,
    output [3:0] redraw_idx             // the redraw effect's pixel, same timing as terrain_out (arena uses it)
    );

    `include "sprite_data.vh"
    `include "obj_slots.vh"

    // colours that are not in the palette
    localparam [11:0] PAPER   = 12'hEDB;
    localparam [11:0] STRIPE  = 12'hDCA;
    localparam [11:0] SHADOWC = 12'hCB9;
    localparam [11:0] BOXTINT = 12'hFCD;
    localparam [11:0] WATER   = 12'h4AE;
    localparam [11:0] SURFACE = 12'h9CE;
    localparam [11:0] BAD     = 12'hF33;
    localparam [9:0]  HIDE    = 10'd1023;     // off-screen spot for empty slots

    // 50/50 mix of two colours (see-through look)
    function [11:0] blend;
        input [11:0] a;
        input [11:0] b;
        reg [4:0] r;
        reg [4:0] g;
        reg [4:0] bl;
        begin
            r = a[11:8] + b[11:8];
            g = a[7:4] + b[7:4];
            bl = a[3:0] + b[3:0];
            blend = {r[4:1], g[4:1], bl[4:1]};
        end
    endfunction


    //----------------------------------------------------------------------
    // split the object table into slots
    // each slot: [29] visible, [28:19] x, [18:9] y, [8:0] extra (size, height...)
    // hidden slots get moved off screen so their sprite never hits
    //----------------------------------------------------------------------
    wire v [0:NSLOT-1];
    wire [9:0] ox [0:NSLOT-1];
    wire [9:0] oy [0:NSLOT-1];
    wire [8:0] op [0:NSLOT-1];
    genvar gi;
    generate
        for (gi = 0; gi < NSLOT; gi = gi + 1) begin : g_dec
            assign v[gi] = objs[gi*30 + 29];
            assign ox[gi] = v[gi] ? objs[gi*30 + 19 +: 10] : HIDE;
            assign oy[gi] = v[gi] ? objs[gi*30 + 9  +: 10] : HIDE;
            assign op[gi] = objs[gi*30 +: 9];
        end
    endgenerate


    //----------------------------------------------------------------------
    // frame tick + door animation
    // new_frame = first clk of vertical blank
    // each frame a door panel moves 1 art px toward its target
    // target open = door's flip bit (p[0]) xor scale loaded
    //----------------------------------------------------------------------
    reg [7:0] frame = 0;
    reg vb_q = 0;
    wire new_frame = (y >= 10'd480) && !vb_q;
    always @ (posedge clk) begin
        vb_q <= (y >= 10'd480);
    end

    reg [6:0] dopen [0:1];
    assign door_open = {dopen[1], dopen[0]};
    wire [6:0] dmax0 = op[SLOT_DOOR0][8:2] - 7'd10;       // fully open = height - 10
    wire [6:0] dmax1 = op[SLOT_DOOR0+1][8:2] - 7'd10;
    wire dtgt0 = op[SLOT_DOOR0][0] ^ weight_on;
    wire dtgt1 = op[SLOT_DOOR0+1][0] ^ weight_on;
    reg load_pend = 1;                  // 1 = jump straight to the target next frame (no slide)

    always @ (posedge clk) begin
        if (table_load == 1) begin
            load_pend <= 1'b1;
        end
        if (new_frame == 1) begin
            frame <= frame + 1;
            if (load_pend == 1) begin
                load_pend <= 1'b0;
                dopen[0] <= dtgt0 ? dmax0 : 7'd0;
                dopen[1] <= dtgt1 ? dmax1 : 7'd0;
            end
            else begin
                if (dtgt0 && dopen[0] < dmax0) begin
                    dopen[0] <= dopen[0] + 1;
                end
                else if (!dtgt0 && dopen[0] != 0) begin
                    dopen[0] <= dopen[0] - 1;
                end
                if (dtgt1 && dopen[1] < dmax1) begin
                    dopen[1] <= dopen[1] + 1;
                end
                else if (!dtgt1 && dopen[1] != 0) begin
                    dopen[1] <= dopen[1] - 1;
                end
            end
        end
    end


    //----------------------------------------------------------------------
    // one renderer per slot, each gives a palette index (0 = nothing)
    // and box (pixel is inside its sprite rectangle, for sw1 / red tint)
    // all renderers have 2 clk delay
    //----------------------------------------------------------------------
    wire [3:0] s_idx [0:NSLOT-1];
    wire [NSLOT-1:0] bx;
    wire [3:0] i_sce;
    wire [3:0] i_sch;

    // character: p[1:0] = size (0 normal 16 px, 1 small 8 px, 2 big 32 px)
    // one renderer for all 3: normal art 1x, small art 1x, normal art 2x
    wire [1:0] psz = op[SLOT_PLAYER][1:0];
    sprite_sz #(.W(SPR_PLAYER_W), .H(SPR_PLAYER_H), .DATA(SPR_PLAYER),
                .AW(SPR_PLAYER_SMALL_W), .AH(SPR_PLAYER_SMALL_H), .ADATA(SPR_PLAYER_SMALL), .HAS_ALT(1)) u_player (
        .clk(clk),
        .x(x),
        .y(y),
        .x0(ox[SLOT_PLAYER]),
        .y0(oy[SLOT_PLAYER]),
        .sz(psz),
        .flip(face_left),
        .idx(s_idx[SLOT_PLAYER]),
        .box(bx[SLOT_PLAYER])
        );

    sprite #(.W(SPR_FLAG_W), .H(SPR_FLAG_H), .SHIFT(0), .DATA(SPR_FLAG)) u_flag (
        .clk(clk),
        .x(x),
        .y(y),
        .x0(ox[SLOT_FLAG]),
        .y0(oy[SLOT_FLAG]),
        .flip(1'b0),
        .idx(s_idx[SLOT_FLAG]),
        .box(bx[SLOT_FLAG])
        );

    // gun is drawn by aim.v (always in the hand), its slot draws nothing
    assign s_idx[SLOT_GUN] = 4'h0;
    assign bx[SLOT_GUN] = 1'b0;

    // crates: p[1:0] = size like the character (0 normal 1x, 1 small 8x8 art, 2 big 2x)
    // the extra renderer (gi == N_BOX) is for SLOT_XGHOST, which only holds the
    // editor's crate ghost (shown red when both crate slots are used)
    generate
        for (gi = 0; gi <= N_BOX; gi = gi + 1) begin : g_box
            localparam integer SL = (gi == N_BOX) ? SLOT_XGHOST : SLOT_BOX0 + gi;
            sprite_sz #(.W(SPR_CRATE_W), .H(SPR_CRATE_H), .DATA(SPR_CRATE),
                        .AW(SPR_CRATE_SMALL_W), .AH(SPR_CRATE_SMALL_H), .ADATA(SPR_CRATE_SMALL), .HAS_ALT(1)) u_box (
                .clk(clk),
                .x(x),
                .y(y),
                .x0(ox[SL]),
                .y0(oy[SL]),
                .sz(op[SL][1:0]),
                .flip(1'b0),
                .idx(s_idx[SL]),
                .box(bx[SL])
                );
        end
    endgenerate

    // only N_BOX (2) crate slots are used, any others up to the scale draw nothing
    generate
        for (gi = SLOT_BOX0 + N_BOX; gi < SLOT_SCALE; gi = gi + 1) begin : g_nobox
            assign s_idx[gi] = 4'h0;
            assign bx[gi] = 1'b0;
        end
    endgenerate

    // scale: 2 pictures (empty / pressed down), pick by weight_on
    sprite #(.W(SPR_SCALE_EMPTY_W), .H(SPR_SCALE_EMPTY_H), .SHIFT(1), .DATA(SPR_SCALE_EMPTY)) u_sce (
        .clk(clk),
        .x(x),
        .y(y),
        .x0(ox[SLOT_SCALE]),
        .y0(oy[SLOT_SCALE]),
        .flip(1'b0),
        .idx(i_sce),
        .box(bx[SLOT_SCALE])
        );
    sprite #(.W(SPR_SCALE_HEAVY_W), .H(SPR_SCALE_HEAVY_H), .SHIFT(1), .DATA(SPR_SCALE_HEAVY)) u_sch (
        .clk(clk),
        .x(x),
        .y(y),
        .x0(ox[SLOT_SCALE]),
        .y0(oy[SLOT_SCALE]),
        .flip(1'b0),
        .idx(i_sch),
        .box()
        );
    // weight_on delayed 2 clk so it lines up with the sprite outputs
    reg [1:0] wt_d;
    always @ (posedge clk) begin
        wt_d <= {wt_d[0], weight_on};
    end
    assign s_idx[SLOT_SCALE] = wt_d[1] ? i_sch : i_sce;

    // doors: height in p[8:2], panel position from the animation above
    generate
        for (gi = 0; gi < N_DOOR; gi = gi + 1) begin : g_door
            door #(.SHIFT(1)) u_door (
                .clk(clk),
                .x(x),
                .y(y),
                .x0(ox[SLOT_DOOR0+gi]),
                .y0(oy[SLOT_DOOR0+gi]),
                .height(op[SLOT_DOOR0+gi][8:2]),
                .open(dopen[gi]),
                .idx(s_idx[SLOT_DOOR0+gi])
                );
            assign bx[SLOT_DOOR0+gi] = 1'b0;
        end
    endgenerate

    // mirrors are tile types now (tilemap.v draws them), old slots stay empty
    generate
        for (gi = 0; gi < N_MIR; gi = gi + 1) begin : g_mir
            assign s_idx[SLOT_MIR0+gi] = 4'h0;
            assign bx[SLOT_MIR0+gi] = 1'b0;
        end
    endgenerate

    // springs: 5 frames from one shared rom (spring_gfx.v)
    // edit mode always shows them fully up (frame 0)
    // in the arena the same renderer draws the bounce pads instead
    wire [7:0] i_spr;
    spring_gfx u_springs (
        .clk(clk),
        .x(x),
        .y(y),
        .x0(arena_view ? ar_spx0 : {ox[SLOT_SPRING0+1], ox[SLOT_SPRING0]}),
        .y0(arena_view ? ar_spy0 : {oy[SLOT_SPRING0+1], oy[SLOT_SPRING0]}),
        .frame(arena_view ? ar_spf : mode_edit ? 6'd0 : spr_frame),
        .idx(i_spr),
        .box({bx[SLOT_SPRING0+1], bx[SLOT_SPRING0]})
        );
    assign s_idx[SLOT_SPRING0] = i_spr[3:0];
    assign s_idx[SLOT_SPRING0+1] = i_spr[7:4];

    // trees, every 2nd one mirrored so they don't look copy-pasted
    generate
        for (gi = 0; gi < N_TREE; gi = gi + 1) begin : g_tree
            sprite #(.W(SPR_TREE_W), .H(SPR_TREE_H), .SHIFT(1), .DATA(SPR_TREE)) u_tree (
                .clk(clk),
                .x(x),
                .y(y),
                .x0(ox[SLOT_TREE0+gi]),
                .y0(oy[SLOT_TREE0+gi]),
                .flip(gi[0]),
                .idx(s_idx[SLOT_TREE0+gi]),
                .box(bx[SLOT_TREE0+gi])
                );
        end
    endgenerate


    //----------------------------------------------------------------------
    // wires from the scale to each door (just decoration)
    // each wire = down from the scale, across, then up/down to the door
    // every run is a 2 px wide rectangle so plain range checks are enough
    //----------------------------------------------------------------------
    wire [9:0] sxc = ox[SLOT_SCALE] + 10'd20;     // scale middle x
    wire [9:0] sbot = oy[SLOT_SCALE] + 10'd28;    // scale bottom
    wire [9:0] wy = sbot + 10'd20;                // height of the across run
    reg wire_px;
    integer wk;
    reg [9:0] dxc;
    reg [9:0] dbot;
    reg [9:0] xa;
    reg [9:0] xb;
    reg [9:0] ya;
    reg [9:0] yb;

    always @ (*) begin
        wire_px = 1'b0;
        // drop down from the scale
        if (v[SLOT_SCALE] && (v[SLOT_DOOR0] || v[SLOT_DOOR0+1]) &&
            x >= sxc && x <= sxc + 10'd1 && y >= sbot && y <= wy + 10'd1) begin
            wire_px = 1'b1;
        end
        for (wk = 0; wk < N_DOOR; wk = wk + 1) begin
            dxc = ox[SLOT_DOOR0+wk] + 10'd12;                         // door middle x
            dbot = oy[SLOT_DOOR0+wk] + {op[SLOT_DOOR0+wk][8:2], 1'b0};  // door bottom (height is 2x)
            xa = (dxc < sxc) ? dxc : sxc;
            xb = (dxc < sxc) ? sxc : dxc;
            ya = (dbot < wy) ? dbot : wy;
            yb = (dbot < wy) ? wy : dbot;
            if (v[SLOT_SCALE] && v[SLOT_DOOR0+wk]) begin
                // across
                if (y >= wy && y <= wy + 10'd1 && x >= xa && x <= xb + 10'd1) begin
                    wire_px = 1'b1;
                end
                // up / down to the door
                if (x >= dxc && x <= dxc + 10'd1 && y >= ya && y <= yb + 10'd1) begin
                    wire_px = 1'b1;
                end
            end
        end
    end

    // delay 2 clk to line up with the sprite renderers
    reg [1:0] wire_d;
    always @ (posedge clk) begin
        wire_d <= {wire_d[0], wire_px};
    end
    wire [3:0] i_wire = wire_d[1] ? 4'hC : 4'h0;


    //----------------------------------------------------------------------
    // redraw effect (checker circle when something changes size)
    //----------------------------------------------------------------------
    wire [3:0] i_redraw;
    assign redraw_idx = i_redraw;
    redraw u_redraw (
        .clk(clk),
        .x(x),
        .y(y),
        .new_frame(new_frame),
        .start(rd_start),
        .cx(rd_cx),
        .cy(rd_cy),
        .rad(rd_rad),
        .busy(rd_busy),
        .swap(rd_swap),
        .idx(i_redraw)
        );


    //----------------------------------------------------------------------
    // terrain from the tilemap
    // arena: level slot 8 + map number, bounce pads drawn over it
    // terrain_out goes to the arena renderer
    //----------------------------------------------------------------------
    wire [3:0] i_terrain;
    wire sh_terrain;
    wire w_surf;
    wire w_body;
    wire [3:0] i_pad = (i_spr[3:0] != 4'h0) ? i_spr[3:0] : i_spr[7:4];
    assign terrain_out = {(i_pad != 4'h0) ? i_pad : i_terrain, sh_terrain, w_surf, w_body};

    tilemap #(.Y_OFS(64)) u_tiles (
        .clk(clk),
        .x(x),
        .y(y),
        .level(arena_view ? 4'd8 + {2'b00, arena_map} : level),
        .frame(frame),
        .idx(i_terrain),
        .shadow(sh_terrain),
        .water_surf(w_surf),
        .water_body(w_body),
        .ed_addr(ed_addr),
        .ed_we(ed_we),
        .ed_wdata(ed_wdata),
        .ed_rdata(ed_rdata)
        );


    //----------------------------------------------------------------------
    // editor buttons + mouse cursor
    //----------------------------------------------------------------------
    wire [3:0] i_ui;
    wire [3:0] i_cursor;
    editor_ui u_ui (
        .clk(clk),
        .x_i(x),
        .y_i(y),
        .mode_edit(mode_edit),
        .level(level),
        .copy_from(copy_from),
        .tool(tool),
        .crate_sz(crate_sz),
        .brush2(brush2),
        .rect_mode(rect_mode),
        .verified(verified),
        .lvl_bad(lvl_bad),
        .play_block(play_block),
        .sel_on(sel_on),
        .sel_bnd(sel_bnd),
        .sel_slot(sel_slot),
        .objs(objs),
        .ghost_on(ghost_on),
        .ghost_slot(ghost_slot),
        .hov_on(hov_on),
        .hov_x0(hov_x0),
        .hov_y0(hov_y0),
        .hov_x1(hov_x1),
        .hov_y1(hov_y1),
        .hov_bad(hov_bad),
        .idx(i_ui)
        );

    // arrow pointer (edit mode, or play mode without the gun)
    wire [3:0] i_arrow;
    sprite #(.W(SPR_CURSOR_W), .H(SPR_CURSOR_H), .SHIFT(0), .DATA(SPR_CURSOR)) u_cursor (
        .clk(clk),
        .x(x),
        .y(y),
        .x0(mx),
        .y0(my),
        .flip(1'b0),
        .idx(i_arrow),
        .box()
        );

    // play mode crosshair: white lines with a dark outline, gap in the middle
    wire [9:0] adx = (x > mx) ? x - mx : mx - x;
    wire [9:0] ady = (y > my) ? y - my : my - y;
    wire cross_w = ((ady == 0 && adx >= 2 && adx <= 6) || (adx == 0 && ady >= 2 && ady <= 6));
    wire cross_k = ((ady <= 1 && adx >= 1 && adx <= 7) || (adx <= 1 && ady >= 1 && ady <= 7));
    reg [3:0] cross_q1;
    reg [3:0] cross_q2;
    always @ (posedge clk) begin
        cross_q1 <= cross_w ? 4'h2 : cross_k ? 4'h1 : 4'h0;
        cross_q2 <= cross_q1;
    end
    assign i_cursor = (mode_edit || !gun_held) ? i_arrow : cross_q2;


    //----------------------------------------------------------------------
    // background bits, delayed 2 clk to line up
    // stripe = diagonal paper stripes, grid = edit mode dots every 8 px
    //----------------------------------------------------------------------
    wire [10:0] diag = x + y;
    reg [1:0] stripe_d;
    reg [1:0] von_d;
    reg [1:0] grid_d;
    always @ (posedge clk) begin
        stripe_d <= {stripe_d[0], (diag[3:2] == 2'b00)};
        von_d <= {von_d[0], video_on};
        grid_d <= {grid_d[0], mode_edit && x[2:0] == 3'd0 && y[2:0] == 3'd0 && y >= 10'd64 && y < 10'd424};
    end


    //----------------------------------------------------------------------
    // layer mixer
    // the ghost slot is taken out of the normal stack and drawn see-through on top
    //----------------------------------------------------------------------
    // slot idx, or 0 if this slot is the ghost
    function [3:0] ex;
        input [3:0] i;
        input [4:0] s;
        begin
            ex = (ghost_on && ghost_slot == s) ? 4'h0 : i;
        end
    endfunction
    wire [3:0] i_ghost = ghost_on ? s_idx[ghost_slot] : 4'h0;

    reg [3:0] top_idx;
    reg bad_px;                         // pixel of a bad object (edit mode), tinted red
    integer k;

    always @ (*) begin
        bad_px = 1'b0;
        for (k = 0; k < NSLOT; k = k + 1) begin
            if (obj_bad[k] && (ex(s_idx[k], k) != 4'h0 || (bx[k] && !(ghost_on && ghost_slot == k)))) begin
                bad_px = mode_edit;
            end
        end

        // lowest layer first, later ones win
        top_idx = 4'h0;
        if (i_terrain) begin
            top_idx = i_terrain;
        end
        for (k = SLOT_TREE0 + N_TREE - 1; k >= SLOT_TREE0; k = k - 1) begin
            if (ex(s_idx[k], k)) top_idx = s_idx[k];
        end
        if (i_wire) begin
            top_idx = i_wire;
        end
        for (k = SLOT_MIR0 + N_MIR - 1; k >= SLOT_MIR0; k = k - 1) begin
            if (ex(s_idx[k], k)) top_idx = s_idx[k];
        end
        for (k = SLOT_SPRING0 + N_SPRING - 1; k >= SLOT_SPRING0; k = k - 1) begin
            if (ex(s_idx[k], k)) top_idx = s_idx[k];
        end
        for (k = SLOT_DOOR0 + N_DOOR - 1; k >= SLOT_DOOR0; k = k - 1) begin
            if (ex(s_idx[k], k)) top_idx = s_idx[k];
        end
        if (ex(s_idx[SLOT_SCALE], SLOT_SCALE)) begin
            top_idx = s_idx[SLOT_SCALE];
        end
        if (ex(s_idx[SLOT_FLAG], SLOT_FLAG)) begin
            top_idx = s_idx[SLOT_FLAG];
        end
        for (k = SLOT_BOX0 + N_BOX - 1; k >= SLOT_BOX0; k = k - 1) begin
            if (ex(s_idx[k], k)) top_idx = s_idx[k];
        end
        if (ex(s_idx[SLOT_PLAYER], SLOT_PLAYER)) begin
            top_idx = s_idx[SLOT_PLAYER];
        end
        // gun in front of the player (hidden while the player itself is the ghost)
        if (gun_idx && !(ghost_on && ghost_slot == SLOT_PLAYER)) begin
            top_idx = gun_idx;
        end
        if (path_idx) begin
            top_idx = path_idx;         // aim path
        end
        if (shot_idx) begin
            top_idx = shot_idx;         // bullet / spark
        end
        if (i_redraw) begin
            top_idx = i_redraw;         // redraw effect over everything in the level
        end
    end

    // turn the index into a colour, then water tint, then ghost mix
    reg [11:0] base;
    reg [11:0] wbase;
    reg [11:0] gcol;
    always @ (*) begin
        if (top_idx != 4'h0) begin
            base = palette(top_idx);
        end
        else if (sh_terrain) begin
            base = SHADOWC;
        end
        else if (show_boxes && (|bx)) begin
            base = BOXTINT;
        end
        else if (stripe_d[1] && !no_stripes) begin
            base = STRIPE;
        end
        else begin
            base = PAPER;
        end
        wbase = w_surf ? SURFACE : w_body ? blend(base, WATER) : base;
        gcol = blend(palette(i_ghost), wbase);
        if (!ghost_ok) begin
            gcol = blend(gcol, BAD);    // ghost can't go here: reddish
        end
    end

    // final pick, cursor and buttons on top, black outside the visible area
    always @ (posedge clk) begin
        if (!von_d[1]) begin
            rgb <= 12'h000;
        end
        else if (i_cursor != 4'h0) begin
            rgb <= palette(i_cursor);
        end
        else if (i_ui != 4'h0) begin
            rgb <= palette(i_ui);
        end
        else if (i_ghost != 4'h0) begin
            rgb <= gcol;
        end
        else if (bad_px) begin
            rgb <= blend(wbase, BAD);
        end
        else begin
            rgb <= wbase;
        end
    end

endmodule
