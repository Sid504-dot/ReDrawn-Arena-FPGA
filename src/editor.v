`timescale 1ns / 1ps

module editor #(
    parameter TEST_MOVE = 1             // old test hook: btn_l / btn_r walk the character (no physics). 0 in the game
    )(
    input clk,
    input rst,
    input [9:0] mx,
    input [9:0] my,
    input mleft,
    input mright,
    input [9:0] y,                      // vga row
    input level_cleared,                // from the game: flag reached
    input go_next,                      // 1 clk: clear panel -> next built-in level (user level: replay)
    input go_first,                     // 1 clk: YOU WON panel -> new run at level 1
    input go_restart,                   // 1 clk: restart the level in play
    input grow_sw,                      // test: flip = grow what is under the crosshair (play mode)
    input shrink_sw,                    // test: flip = shrink it
    input btn_l,                        // test: walk left / right, tmove_step px per frame (TEST_MOVE)
    input btn_r,
    input [4:0] tmove_step,
    input rd_busy,                      // redraw effect running (pixel_gen / redraw.v)
    input rd_swap,                      // redraw effect midpoint: swap the object size now
    output reg rd_start,
    output reg [9:0] rd_cx,
    output reg [9:0] rd_cy,
    output reg [6:0] rd_rad,
    output reg mode_edit,
    output reg [3:0] level,             // 0-6 built-in levels, 7 = user level U1
    output [2:0] copy_from,             // (copy level removed, always 0)
    output [16*30-1:0] objs,            // active object table (ghost merged in)
    output reg table_load,              // 1 clk: table (re)loaded
    output reg [3:0] tool,
    output reg [1:0] crate_sz,          // crate tool: size of the next crate (0 normal, 1 small, 2 big)
    output reg brush2,
    output reg rect_mode,
    output reg [2:0] verified,          // user level was cleared once in play test
    output reg sel_on,
    output reg [4:0] sel_slot,
    output reg ghost_on,
    output reg ghost_ok,
    output reg [4:0] ghost_slot,
    output reg hov_on,
    output reg [9:0] hov_x0,
    output reg [9:0] hov_y0,
    output reg [9:0] hov_x1,
    output reg [9:0] hov_y1,
    output reg hov_bad,                 // hover box red (boundary can't go there)
    output reg sel_bnd,                 // a boundary is selected (Delete removes it)
    output reg [15:0] obj_bad,          // per slot: object is in a bad spot (drawn red)
    output reg [1:0] lvl_bad,           // per user slot: level has bad objects / boundaries
    output reg val_busy,                // level check running

    // tile ram (tilemap.v port b, only while y >= 480)
    output [15:0] t_addr,
    output reg t_we,
    output reg [15:0] t_wdata,
    input [15:0] t_rdata,

    // collision copies (level_collision*.v), same address as the tile ram
    output [15:0] c_addr,
    output reg c_we,
    output reg [3:0] c_type,

    // physics write requests (see "physics requests" below), tie phys_req to 0 if unused
    input phys_req,                     // hold with slot / entry steady until phys_ack
    input [4:0] phys_slot,              // 0 character, 3-4 crates
    input [29:0] phys_entry,            // new {vis, x, y, p}, vis and p must match the current entry
    output reg phys_ack,                // 1 clk: request answered (exactly once)
    output reg phys_ok,                 // with phys_ack: 1 applied, 0 rejected (held till the next ack)
    output resize_busy,                 // a resize is being checked / waiting for the redraw midpoint
    output [4:0] resize_slot,           // ...of this slot, physics writes to it get rejected meanwhile

    // spring platform tops (spring_ctrl.v), growing never pushes into a spring
    input [19:0] spr_top,               // {spring 1, spring 0}

    // a grow / shrink bullet hit the character or a crate (aim.v): resize that slot
    input shot_hit,                     // 1 clk
    input [4:0] shot_slot,
    input shot_grow                     // 1 grow bullet, 0 shrink bullet
    );

    `include "obj_slots.vh"
    `include "ui_layout.vh"
    `include "level_data.vh"

    // start values of the output regs
    initial begin
        rd_start = 0;
        rd_cx = 0;
        rd_cy = 0;
        rd_rad = 0;
        mode_edit = 0;
        level = 0;
        table_load = 0;
        tool = 0;
        crate_sz = 2'd0;
        brush2 = 0;
        rect_mode = 0;
        verified = 0;
        sel_on = 0;
        sel_slot = 0;
        ghost_on = 0;
        ghost_ok = 0;
        ghost_slot = 0;
        hov_on = 0;
        hov_x0 = 0;
        hov_y0 = 0;
        hov_x1 = 0;
        hov_y1 = 0;
        hov_bad = 0;
        sel_bnd = 0;
        obj_bad = 0;
        lvl_bad = 0;
        val_busy = 0;
        t_we = 0;
        t_wdata = 0;
        c_we = 0;
        c_type = 0;
        phys_ack = 0;
        phys_ok = 0;
    end

    //----------------------------------------------------------------------
    // helpers
    //----------------------------------------------------------------------
    // tile types (3 bits); op types used when painting: 0 air, 1 solid, 2 water, 3 boundary,
    // 4 blank (Clear), 7 reflective. (crates are objects, no crate tiles any more.)
    localparam [2:0] T_AIR = 0, T_SOLID = 1, T_WATER = 2, T_BND = 3, T_MIR = 5;
    localparam [2:0] T_TPL = 3'd4, OP_MIR = 3'd7;

    function [15:0] lbase;                              // first tile of a level slot (slot x 3600)
        input [3:0] lv;
        case (lv[2:0])
            3'd0: lbase = 16'd0;     3'd1: lbase = 16'd3600;  3'd2: lbase = 16'd7200;  3'd3: lbase = 16'd10800;
            3'd4: lbase = 16'd14400; 3'd5: lbase = 16'd18000; 3'd6: lbase = 16'd21600; default: lbase = 16'd25200;
        endcase
    endfunction
    function [2:0] wtype;
        input [15:0] w;
        wtype = w[15] ? T_MIR : w[0] ? T_SOLID : w[10] ? T_WATER : w[12] ? T_BND : T_AIR;
    endfunction
    function [3:0] cnib;                                // collision copy {mirror, boundary, vert/water, solid}
        input [15:0] w;
        cnib = {w[15] & w[14], !w[15] & w[12], w[15] ? (w[14] & w[13]) : w[10], w[0] | w[15]};
    endfunction
    function is_ground;                                 // things objects can stand on
        input [2:0] ty;
        is_ground = (ty == T_SOLID) || (ty == T_MIR);
    endfunction
    // full tile word from the 3x3 neighbourhood (same rules as gen_levels.py)
    function [15:0] calc_word;
        input [26:0] nb;                                 // 9 x 3-bit types, index (dr+1)*3+(dc+1)
        input [6:0]  c; input [5:0] r;
        reg [2:0] t [0:8];
        integer k;
        reg [15:0] w;
        reg [8:0] g;
        reg vt;
        reg fc;
        begin
            for (k = 0; k < 9; k = k + 1) t[k] = nb[3*k +: 3];
            w = 16'h0000;
            if (t[4] == T_SOLID) begin
                w[0] = 1'b1;
                w[1] = (t[1] != T_SOLID); w[2] = (t[7] != T_SOLID);
                w[3] = (t[3] != T_SOLID); w[4] = (t[5] != T_SOLID);
                w[5] = (t[1] == T_SOLID) && (t[3] == T_SOLID) && (t[0] != T_SOLID);
                w[6] = (t[1] == T_SOLID) && (t[5] == T_SOLID) && (t[2] != T_SOLID);
                w[7] = (t[7] == T_SOLID) && (t[3] == T_SOLID) && (t[6] != T_SOLID);
                w[8] = (t[7] == T_SOLID) && (t[5] == T_SOLID) && (t[8] != T_SOLID);
            end else if (t[4] == T_MIR) begin              // reflective: mount on a neighbouring wall
                if (t[3] == T_SOLID)      begin vt = 1; fc = 1; end
                else if (t[5] == T_SOLID) begin vt = 1; fc = 0; end
                else if (t[7] == T_SOLID) begin vt = 0; fc = 0; end
                else if (t[1] == T_SOLID) begin vt = 0; fc = 1; end
                else                      begin vt = 1; fc = 1; end
                w = {2'b11, vt, fc, vt ? (t[1] != T_MIR) : (t[3] != T_MIR), vt ? (t[7] != T_MIR) : (t[5] != T_MIR), 10'd0};
            end else if (t[4] == T_WATER) begin
                w[10] = 1'b1; w[11] = (t[1] != T_WATER);
            end else if (t[4] == T_BND) begin
                w[12] = 1'b1; w[13] = (t[1] == T_BND) || (t[7] == T_BND);
            end else begin
                g = {3'b0, c[6:1]} * 9'd5 + {3'b0, r};
                w[9] = (t[7] == T_SOLID) && (g[2:0] < 3'd5);
            end
            calc_word = w;
        end
    endfunction
    // object size (screen px) from slot + parameter bits
    function [17:0] obj_wh;                              // {w[8:0], h[8:0]}
        input [4:0] s; input [8:0] p;
        begin
            if (s == SLOT_PLAYER)                         obj_wh = (p[1:0] == 2'd1) ? {9'd8, 9'd8} : (p[1:0] == 2'd2) ? {9'd32, 9'd32} : {9'd16, 9'd16};
            else if (s == SLOT_FLAG)                      obj_wh = {9'd16, 9'd24};
            else if (s == SLOT_GUN)                       obj_wh = {9'd16, 9'd8};
            else if (s >= SLOT_BOX0 && s < SLOT_SCALE)    obj_wh = (p[1:0] == 2'd1) ? {9'd8, 9'd8} : (p[1:0] == 2'd2) ? {9'd32, 9'd32} : {9'd16, 9'd16};
            else if (s == SLOT_SCALE)                     obj_wh = {9'd40, 9'd28};
            // (v7 bug fixed: the 8-bit {p[8:2], 1'b0} shifted the packed word, so doors were 12 px wide)
            else if (s >= SLOT_DOOR0 && s < SLOT_MIR0)    obj_wh = {9'd24, 1'b0, p[8:2], 1'b0};
            else if (s >= SLOT_MIR0 && s < SLOT_SPRING0)  obj_wh = p[1] ? {9'd8, 1'b0, p[8:2], 1'b0} : {1'b0, p[8:2], 1'b0, 9'd8};
            else if (s >= SLOT_SPRING0 && s < SLOT_TREE0) obj_wh = {9'd64, 9'd96};   // extended spring
            else if (s == SLOT_TREE0)                     obj_wh = {9'd32, 9'd42};
            else                                          obj_wh = {9'd48, 9'd16};
        end
    endfunction
    // object kind for a tool index / a slot
    localparam K_GROUND = 0, K_SCALE = 1, K_DOOR = 2, K_MIRROR = 3, K_FREE = 4;
    function [4:0] tool_slot0;  input [3:0] t;
        case (t) 4'd4: tool_slot0 = SLOT_PLAYER; 4'd5: tool_slot0 = SLOT_FLAG; 4'd6: tool_slot0 = SLOT_GUN;
                 4'd7: tool_slot0 = SLOT_BOX0;   4'd8: tool_slot0 = SLOT_SCALE; 4'd9: tool_slot0 = SLOT_DOOR0;
                 4'd10: tool_slot0 = SLOT_MIR0;  4'd11: tool_slot0 = SLOT_SPRING0; 4'd12: tool_slot0 = SLOT_TREE0;
                 default: tool_slot0 = SLOT_XGHOST; endcase
    endfunction
    function [2:0] tool_count;  input [3:0] t;
        case (t) 4'd7: tool_count = N_BOX; 4'd9, 4'd10, 4'd11: tool_count = 2; default: tool_count = 1; endcase
    endfunction
    function [3:0] slot_tool;   input [4:0] s;
        if (s == SLOT_PLAYER) slot_tool = 4; else if (s == SLOT_FLAG) slot_tool = 5; else if (s == SLOT_GUN) slot_tool = 6;
        else if (s < SLOT_SCALE) slot_tool = 7; else if (s == SLOT_SCALE) slot_tool = 8; else if (s < SLOT_MIR0) slot_tool = 9;
        else if (s < SLOT_SPRING0) slot_tool = 10; else if (s < SLOT_TREE0) slot_tool = 11; else if (s == SLOT_TREE0) slot_tool = 12;
        else slot_tool = 14;
    endfunction
    function [2:0] tool_kind;   input [3:0] t;
        case (t) 4'd8: tool_kind = K_SCALE; 4'd9: tool_kind = K_DOOR; 4'd10: tool_kind = K_MIRROR;
                 4'd14: tool_kind = K_FREE; default: tool_kind = K_GROUND; endcase
    endfunction

    //----------------------------------------------------------------------
    // shared tile-address unit
    //----------------------------------------------------------------------
    // every state sets (ta_c, ta_r) or a linear word index ta_w; one adder makes the address
    reg [6:0] ta_c = 0;
    reg [5:0] ta_r = 0;
    reg [11:0] ta_w = 0;
    // linear index / use the copy-source level
    reg ta_lin = 0;
    reg ta_cp = 0;
    wire [2:0] copy_sel = 3'd0;        // copy level removed (combined game)
    assign copy_from = copy_sel;
    wire [15:0] t_base = ta_cp ? lbase({1'b0, copy_from}) : lbase(level);
    wire [11:0] t_off  = ta_lin ? ta_w : {ta_r, 6'b0} + {ta_r, 4'b0} + ta_c;
    assign t_addr = t_base + {4'd0, t_off};
    assign c_addr = t_addr;                            // the collision copy is written at the same tile

    //----------------------------------------------------------------------
    // object tables
    //----------------------------------------------------------------------
    reg [29:0] act [0:NSLOT-1];        // what the renderer / game uses
    reg [29:0] bank [0:NSLOT-1];        // saved objects of the user slot U1 (combined game: one slot)
    reg [29:0] gent = 0;        // ghost entry
    genvar gi;
    generate for (gi = 0; gi < NSLOT; gi = gi + 1) begin : g_out
        assign objs[gi*30 +: 30] = (ghost_on && ghost_slot == gi) ? gent : act[gi];
    end endgenerate

    // write port + bulk loader of the active table
    reg ow_en = 0;
    reg [4:0] ow_slot = 0;
    reg [29:0] ow_data = 0;
    reg ld_busy = 0;
    reg [4:0] ld_i = 0;
    reg [1:0] ld_src = 0;
    reg [3:0] ld_lv = 0;
    wire [29:0] ld_val = (ld_src == 2'd0) ? lv_obj(ld_lv, ld_i) :
                         (ld_src == 2'd1) ? bank[ld_i] : tpl_obj(ld_i);
    wire       p_apply;                   // physics request applied this clock (see "physics requests")
    always @ (posedge clk) begin
        if (ow_en) act[ow_slot] <= ow_data;
        else if (ld_busy) act[ld_i] <= ld_val;
        else if (p_apply) act[phys_slot] <= phys_entry;
    end

    // 2-level undo: two banks of 4096 words, each = 3600 tile words + 36 object words
    // (object slot k = words 3600+2k (bits 15:0) and 3601+2k (bits 29:16)). Block RAM, one write port.
    reg [15:0] undo_ram [0:8191];
    reg [15:0] undo_q;
    reg [12:0] undo_raddr = 0;
    reg uw_en = 0;
    reg [12:0] uw_addr = 0;
    reg [15:0] uw_data = 0;
    always @ (posedge clk) begin
        undo_q <= undo_ram[undo_raddr];
        if (uw_en) undo_ram[uw_addr] <= uw_data;
    end

    integer i;
    initial begin
        for (i = 0; i < NSLOT; i = i + 1) act[i] = lv_obj(4'd0, i);
        for (i = 0; i < NSLOT; i = i + 1) bank[i] = tpl_obj(i);
    end

    //----------------------------------------------------------------------
    // frame sampling
    //----------------------------------------------------------------------
    reg y480_q = 0;
    wire fs = (y >= 10'd480) && !y480_q;        // start of vertical blank
    wire win = (y >= 10'd481) && (y <= 10'd519);        // safe to start an atomic memory step
    always @ (posedge clk) begin
        y480_q <= (y >= 10'd480);
    end

    reg [9:0] smx = 0;
    reg [9:0] smy = 0;
    reg sl = 0;
    reg sr = 0;
    reg pl = 0;
    reg pr = 0;
    wire [6:0] mc = smx[9:3];
    wire [9:0] my_rel = smy - 10'd64;
    wire [5:0] mr = (my_rel[8:3] > 6'd44) ? 6'd44 : my_rel[8:3];
    wire in_level = (smy >= 10'd64) && (smy < 10'd424);
    // button under the cursor: count how many 40-px button edges lie to its left (no divider)
    wire [3:0] bidx_f = btn_index(smx);
    wire [9:0] bofs = smx - ({bidx_f, 5'b0} + {bidx_f, 3'b0});        // x - 40*i, as shifts
    wire on_top = mode_edit && (smy >= 10'd16) && (smy < 10'd48) && (bofs >= 4) && (bofs < 36);
    wire on_bot = (smy >= 10'd432) && (smy < 10'd464) && (bofs >= 4) && (bofs < 36);

    //----------------------------------------------------------------------
    // job engine
    //----------------------------------------------------------------------
    localparam S_IDLE = 0, S_OPS = 1, S_SET = 2, S_RC_RD = 3, S_RC_WR = 4, S_SNAP = 5, S_UNDO = 6,
               S_COPY = 7, S_GHOST = 8, S_G_DOWN = 9, S_G_FOOT = 10, S_G_UP = 11, S_G_DN2 = 12,
               S_G_OVL = 14, S_G_DONE = 15, S_FIND = 16, S_STROKE = 17, S_RD_WAIT = 18,
               S_PICKBOX = 19, S_ESCAN = 20, S_RSZ = 22, S_RCHK = 23,
               // painting, eraser, boundaries, level check
               S_CMASK = 24, S_CRD = 25, S_COBJ = 26, S_CWR = 27,      // clipped painting
               S_ESTEP = 28, S_EADV = 29, S_EAFTER = 30, S_EBND = 31,  // freehand eraser, whole-boundary removal
               S_BSCAN = 32, S_BEXT = 33,                               // boundary ghost, selected boundary extent
               S_VAL = 34, S_VFIX = 35, S_VOBJ = 36, S_VTILE = 37, S_VPAIR = 38,  // validation
               S_UOBJ = 39, S_VSCAN = 40, S_SIDE = 41,
               // crates as objects
               S_ROVL = 42, S_ECRATE = 43, S_G_LAND = 44,               // resize vs objects, eraser crates, crate ghost landing tiles
               // springs / off-centre growth
               S_RTRY = 45, S_RNEXT = 46,                               // asymmetric growth: next horizontal shift
               S_GEN = 47;                                              // random level generator (4 Nov)
    reg [5:0] st = S_IDLE;
    // snapshot follow-up jobs (snap_then)
    localparam [3:0] SN_CLEAR = 1, SN_COPY = 2, SN_FILL = 3, SN_ERECT = 4, SN_PLACE = 5, SN_DELCARRY = 6,
                     SN_ERASE = 8, SN_BND = 9, SN_DELOBJ = 10, SN_DELBND = 11, SN_DOOR = 12, SN_GEN = 13;

    // ---- random level generator (sp's cave generator idea; 5 Nov: one generator, many shapes) ----
    // Each click first picks random settings: the screen is split into a grid of 1, 2 or 3 rows
    // and 3 or 4 columns of cells; how often the path changes row; for a 1-row grid, whether
    // the floors stay almost flat. A path starts in a cell (a 1-row grid: at one end; else the
    // top row going down or the bottom row climbing up) and walks sideways in one direction,
    // sometimes (never on its last row, always at the screen edge) moving one row on, then a
    // new random sideways direction. It ends at the screen edge of its last row.
    // Each cell on the path gets a room of random size and floor height. Sideways neighbours
    // are joined by a 4-tall hall at the lower floor; if the floors differ by more than 3, the
    // higher room also gets a shaft on the side facing the other room. Rows are joined by a
    // shaft in the middle of the cell. Each shaft is either straight (random width 3..6) or a
    // zig-zag staircase (width 4..5, 3-row pieces shifted 2 columns left / right in turn, so
    // every shift leaves a 2-wide step 3 rows above the last one). More ways up are designed
    // in the editor afterwards (crates, springs...). The character starts in the first room, the flag stands in the last
    // one on the far side. Every room / hall / ledge is one rectangle through the editor's op
    // queue; outlines and the level check run at the end. 1-row grids give the "rooms side by
    // side" kind of level, 2 and 3 rows the winding / climbing kind.
    reg [15:0] rg_lfsr = 16'hACE1;        // runs every clock: the click time is the seed
    always @ (posedge clk) begin
        rg_lfsr <= {rg_lfsr[14:0], rg_lfsr[15] ^ rg_lfsr[13] ^ rg_lfsr[12] ^ rg_lfsr[10]};
    end
    reg [3:0] rg_ph = 0;
    // grid rows (1..3); cell; how this cell joins the last (0 -, 1 hall, 2 row change)
    reg [1:0] rg_rows = 1;
    reg [1:0] rg_gc = 0;
    reg [1:0] rg_gr = 0;
    reg [1:0] rg_link = 0;
    // rg_c4 4 columns (else 3), rg_often path changes row often, rg_flat 1-row grid with flat floors,
    // rg_up path climbs (starts on the bottom row), rg_hd walking right, rg_first first cell,
    // rg_stair this shaft is a zig-zag staircase, rg_odd which way the next stair piece shifts
    reg rg_c4 = 0;
    reg rg_often = 0;
    reg rg_flat = 0;
    reg rg_up = 0;
    reg rg_hd = 0;
    reg rg_first = 0;
    reg rg_lad = 0;
    reg rg_stair = 0;
    reg rg_odd = 0;
    reg [3:0] rg_sw = 0;        // shaft width - 1
    reg [5:0] rg_sb = 0;        // bottom row of the shaft piece still to carve
    // columns
    reg [6:0] rg_cx = 0;
    reg [6:0] rg_pcx = 0;
    reg [6:0] rg_x0 = 0;
    reg [6:0] rg_x1 = 0;
    reg [6:0] rg_sx = 0;
    reg [6:0] rg_lx = 0;
    reg [6:0] rg_lc = 0;
    // rows
    reg [5:0] rg_cf = 0;
    reg [5:0] rg_ct = 0;
    reg [5:0] rg_pf = 0;
    reg [5:0] rg_sf = 0;
    reg [5:0] rg_lf = 0;
    reg [5:0] rg_lt = 0;
    function [2:0] rg_m5; input [2:0] v; rg_m5 = (v >= 3'd5) ? v - 3'd3 : v; endfunction   // 0..4
    wire [6:0] rg_w   = rg_c4 ? 7'd20 : 7'd26;        // cell size
    wire [5:0] rg_h   = (rg_rows == 2'd1) ? 6'd45 : (rg_rows == 2'd2) ? 6'd22 : 6'd15;
    wire [6:0] rg_mid = rg_c4 ? 7'd8 : 7'd11;        // row-change shaft starts at column mid-2
    wire [1:0] rg_cmax = rg_c4 ? 2'd3 : 2'd2;
    wire [6:0]  rg_cxn = rg_c4 ? {1'b0, rg_gc, 4'b0} + {3'b0, rg_gc, 2'b0}                         // 20 * column
                               : {1'b0, rg_gc, 4'b0} + {2'b0, rg_gc, 3'b0} + {4'b0, rg_gc, 1'b0};   // 26 * column
    wire [5:0] rg_cyn = (rg_rows == 2'd3) ? {rg_gr, 4'b0} - {4'b0, rg_gr} : (rg_gr != 2'd0) ? 6'd22 : 6'd0;
    wire [3:0] rg_fr  = (rg_rows == 2'd1) ? (rg_flat ? 4'd3 : 4'd15) : (rg_rows == 2'd2) ? 4'd7 : 4'd3;
    wire [3:0] rg_hr  = (rg_rows == 2'd1) ? 4'd15 : (rg_rows == 2'd2) ? 4'd7 : 4'd3;
    wire [5:0] rg_fn  = rg_cyn + rg_h - 6'd1 - {2'd0, rg_lfsr[9:6] & rg_fr};
    wire [5:0] rg_hn  = 6'd6 + {2'd0, rg_lfsr[13:10] & rg_hr};
    wire [5:0] rg_tn  = (rg_fn > rg_cyn + rg_hn) ? rg_fn - rg_hn : rg_cyn + 6'd1;        // top, at least 1 row below the cell top
    wire [5:0] rg_lo  = (rg_pf < rg_cf) ? rg_pf : rg_cf;
    wire [5:0] rg_hi  = (rg_pf < rg_cf) ? rg_cf : rg_pf;
    wire [6:0] rg_ha  = ((rg_pcx < rg_cx) ? rg_pcx : rg_cx) + rg_mid + 7'd2;        // hall ends (middle of each cell)
    wire [6:0] rg_hb  = ((rg_pcx < rg_cx) ? rg_cx : rg_pcx) + rg_mid + 7'd2;
    wire [6:0] rg_hcx = (rg_pf < rg_cf) ? rg_pcx : rg_cx;        // the higher room's cell
    wire [6:0] rg_ocx = (rg_pf < rg_cf) ? rg_cx : rg_pcx;
    wire rg_lrow = rg_up ? (rg_gr == 2'd0) : (rg_gr == rg_rows - 2'd1);
    wire rg_edge = rg_hd ? (rg_gc == rg_cmax) : (rg_gc == 2'd0);
    wire rg_vert = ((rg_lfsr[2:0] < (rg_often ? 3'd4 : 3'd2)) && !rg_lrow) || rg_edge;
    function [7:0] c8; input [6:0] v; c8 = {1'b0, v}; endfunction
    function [6:0] r7; input [5:0] v; r7 = {1'b0, v}; endfunction

    // rectangle-op queue: up to 4 ops {kind(1=set, 2=recalc, 3=clipped set), type[2:0], c0, r0, c1, r1}
    reg [1:0] op_kind [0:3];
    reg [2:0] op_type [0:3];
    reg [7:0]  op_c0 [0:3], op_c1 [0:3];  // raw values (>= 200 / >= 100 mean "negative"), clamped in S_OPS
    reg [6:0] op_r0 [0:3];
    reg [6:0] op_r1 [0:3];
    // current op, clamped
    reg [6:0] lc0 = 0;
    reg [6:0] lc1 = 0;
    reg [5:0] lr0 = 0;
    reg [5:0] lr1 = 0;
    function [6:0] clc; input [7:0] v; clc = (v >= 8'd200) ? 7'd0 : (v > 8'd79) ? 7'd79 : v[6:0]; endfunction
    function [5:0] clr; input [6:0] v; clr = (v >= 7'd100) ? 6'd0 : (v > 7'd44) ? 6'd44 : v[5:0]; endfunction
    reg [2:0] nops = 0;
    reg [2:0] opi = 0;
    // loop position
    reg [6:0] cc = 0;
    reg [5:0] rr = 0;
    reg [3:0] ki = 0;
    reg [26:0] nb = 0;
    reg [5:0] after_ops = S_IDLE;        // what to do when the op queue is empty

    // stroke state
    reg erasing = 0;        // freehand eraser held down
    reg [6:0] sc = 0;
    reg [6:0] tc = 0;
    reg [5:0] srow = 0;
    reg [5:0] trow = 0;
    reg [2:0] stroke_type = 0;
    reg [6:0] rc0 = 0;
    reg [5:0] rr0 = 0;
    // eraser: current stamp / target tile
    reg [6:0] ep_c = 0;
    reg [6:0] et_c = 0;
    reg [5:0] ep_r = 0;
    reg [5:0] et_r = 0;
    reg ebnd_ret = 0;        // whole-boundary removal returns to: 0 eraser scan, 1 validation
    reg [5:0] br = 0;        // boundary row scan
    reg bphase = 0;
    // clipped painting
    // objects touching the op / still to test for this tile
    reg [15:0] cm_mask = 0;
    reg [15:0] om = 0;
    reg [15:0] cw = 0;        // tile word being replaced
    reg cblk = 0;
    // boundary tool ghost
    reg [6:0] bs_c = 0;
    reg [5:0] bs_top = 0;
    reg [5:0] bs_bot = 0;
    reg bs_ok = 0;
    reg bs_commit = 0;
    // selected boundary
    reg [6:0] sb_c = 0;
    reg [5:0] sb_r = 0;
    reg [5:0] sb_top = 0;
    reg [5:0] sb_bot = 0;
    // validation
    reg [6:0] vc = 0;
    reg [5:0] vr = 0;
    reg in_run = 0;
    reg run_ceil = 0;
    reg prev_solid = 0;
    reg run_ok = 0;
    reg col_end = 0;
    reg [5:0] run_top = 0;
    reg [5:0] run_end = 0;
    // boundaries in the level (saturates at 7)
    reg [2:0] bcnt = 0;
    reg [2:0] bnd_cnt = 0;
    reg bbad = 0;
    reg [15:0] nbad = 0;
    reg [4:0] vo = 0;
    reg [9:0] vx = 0;
    reg [9:0] vy = 0;
    reg [8:0] vw = 0;
    reg [8:0] vh = 0;
    // tile-rect check
    reg [6:0] tc0 = 0;
    reg [6:0] tc1 = 0;
    reg [6:0] tcc = 0;
    reg [5:0] tr0 = 0;
    reg [5:0] tr1 = 0;
    reg [5:0] trr = 0;
    reg tmode = 0;        // 0: tiles must be air/water, 1: must be solid
    reg [2:0] vph = 0;        // which check of the object runs
    // undo ring
    reg u_top = 0;        // bank holding the newest snapshot
    reg [1:0] u_cnt = 0;        // snapshots available (0-2)
    reg no_snap = 0;        // run snap_then without taking a snapshot
    reg ret_undo = 0;        // S_RD_WAIT is restoring undo object words
    reg [15:0] lo_w = 0;
    reg [5:0] oi = 0;
    // area to tidy up after erasing
    reg [6:0] uc0 = 0;
    reg [6:0] uc1 = 0;
    reg [5:0] ur0 = 0;
    reg [5:0] ur1 = 0;
    task u_inc(input [6:0] c, input [5:0] r);                 // grow it to cover tile (c, r) and its neighbours
        begin
            if (((c == 0) ? 7'd0 : c - 1) < uc0) uc0 <= (c == 0) ? 7'd0 : c - 1;
            if (((c == 7'd79) ? 7'd79 : c + 1) > uc1) uc1 <= (c == 7'd79) ? 7'd79 : c + 1;
            if (((r == 0) ? 6'd0 : r - 1) < ur0) ur0 <= (r == 0) ? 6'd0 : r - 1;
            if (((r == 6'd44) ? 6'd44 : r + 1) > ur1) ur1 <= (r == 6'd44) ? 6'd44 : r + 1;
        end
    endtask

    // ghost computation
    reg [3:0] gtool = 0;
    reg [4:0] gslot = 0;
    // gfull: crate tool with all 4 crate slots taken
    reg gvalid = 0;
    reg gfree = 0;
    reg gfull = 0;
    reg [9:0] gx = 0;
    reg [9:0] gy = 0;
    reg [8:0] gp = 0;
    reg [8:0] gw = 0;
    reg [8:0] gh = 0;
    reg [6:0] gc = 0;
    reg [6:0] gc0 = 0;
    reg [6:0] gc1 = 0;
    reg [5:0] gr = 0;
    reg [5:0] gr0 = 0;
    reg [5:0] gr1 = 0;
    reg [5:0] gu = 0;
    reg [2:0] gstep = 0;
    reg commit = 0;        // place after computing
    reg [1:0] gside = 0;        // crate ghost: boundary landing-tile scan (left / right column)
    reg [4:0] si = 0;

    // moving / picking
    reg moving = 0;
    // resizing (play mode): pending change, applied at the redraw effect's midpoint
    reg g_q = 0;
    reg s_q = 0;
    reg grow_ev = 0;
    reg shrink_ev = 0;
    // pending bullet hit (slot shot_s)
    reg shot_ev = 0;
    reg shot_g = 0;
    reg rs_shot = 0;
    reg [4:0] shot_s = 0;
    reg gsup = 0;        // spring ghost - checking the support row
    // asymmetric growth: centred x (rs_nx0), then shifts +1, -1, +2, -2 ... up to rs_dmax
    reg [9:0] rs_nx0 = 0;
    reg [9:0] rs_nw = 0;
    reg [9:0] rs_ny = 0;
    reg [4:0] rs_d = 0;
    reg [4:0] rs_dmax = 0;
    reg rs_neg = 0;
    reg rs_pend = 0;
    reg rs_swap = 0;
    reg rs_grow = 0;
    reg [4:0] rs_slot = 0;        // object being resized (character or crate)
    reg [29:0] rs_entry = 0;        // its new entry
    // free-space check
    reg [6:0] ck_c0 = 0;
    reg [6:0] ck_c1 = 0;
    reg [6:0] ck_c = 0;
    reg [5:0] ck_r0 = 0;
    reg [5:0] ck_r1 = 0;
    reg [5:0] ck_r = 0;
    // straight-line drawing, carrying boxes lifted off the canvas
    reg line_on = 0;        // a line / rectangle is being dragged
    // its anchor tile
    reg [6:0] la_c = 0;
    reg [5:0] la_r = 0;
    // end of the previous line (start snaps to it)
    reg [6:0] le_c = 0;
    reg [5:0] le_r = 0;
    reg le_valid = 0;
    // eraser scan position
    reg [6:0] ecc = 0;
    reg [5:0] err = 0;
    // eraser rectangle
    reg [6:0] ec0 = 0;
    reg [6:0] ec1 = 0;
    reg [5:0] er0 = 0;
    reg [5:0] er1 = 0;
    reg [4:0] mv_slot = 0;
    reg [1:0] find_for = 0;        // 1 = delete, 2 = pick, 3 = select only

    // undo / copy loops
    reg [11:0] wi = 0;
    reg [3:0] snap_then = 0;        // job to run after the snapshot

    // queue helpers -------------------------------------------------
    task q_clear; begin nops = 0; end endtask
    task q_add(input [1:0] k, input [2:0] ty, input [7:0] c0, input [6:0] r0, input [7:0] c1, input [6:0] r1);
        begin
            op_kind[nops] = k; op_type[nops] = ty;
            op_c0[nops] = c0; op_c1[nops] = c1; op_r0[nops] = r0; op_r1[nops] = r1;
            nops = nops + 1;
        end
    endtask
    // scale notch: set (fill=1 solid / 0 air) a 5x4 tile block + recalc around it
    task q_notch(input [29:0] e, input fill);
        reg [6:0] c0;
        reg [5:0] r0;
        reg [9:0] yr;
        begin
            c0 = e[28:22]; yr = e[18:9] - 10'd64; r0 = yr[8:3];
            q_add(2'd1, fill ? 3'd1 : 3'd0, {1'b0, c0}, {1'b0, r0}, {1'b0, c0} + 8'd4, {1'b0, r0} + 7'd3);
            q_add(2'd2, 3'd0, {1'b0, c0} - 8'd1, {1'b0, r0} - 7'd1, {1'b0, c0} + 8'd5, {1'b0, r0} + 7'd4);
        end
    endtask
    // bulk table loads run one slot per clock (ld_src: 0 built-in level, 1 user bank, 2 blank, 3 undo)
    task load_from(input [1:0] src, input [3:0] lv);
        begin ld_busy <= 1'b1; ld_i <= 5'd0; ld_src <= src; ld_lv <= lv; end
    endtask
    task load_table(input [3:0] lv);
        load_from((lv < N_BUILT) ? 2'd0 : 2'd1, lv);
    endtask
    task set_obj(input [4:0] s, input [29:0] e);   // single write port into the active table
        begin
            ow_en <= 1'b1; ow_slot <= s; ow_data <= e;
            verified[level - N_BUILT] <= 1'b0;
        end
    endtask

    // ---- tool helpers ----
    function obj_tool;                       // tools that carry an object on the cursor
        input [3:0] tl;
        obj_tool = (tl == 4'd4) || (tl == 4'd5) || (tl >= 4'd7 && tl <= 4'd9) || (tl >= 4'd11 && tl <= 4'd14);
    endfunction
    function line_tool;                      // tools that drag a straight line (rectangle mode: a box)
        input [3:0] tl; input rm;              // the eraser drags only in rectangle mode (otherwise freehand)
        line_tool = (tl <= 4'd1) || (tl == 4'd10) || (tl == 4'd3 && rm);
    endfunction
    function avail_t;                        // can one more object of this tool be placed?
        input [3:0] tl;
        case (tl)
        4'd4:  avail_t = !act[SLOT_PLAYER][29];
        4'd5:  avail_t = !act[SLOT_FLAG][29];
        4'd8:  avail_t = !act[SLOT_SCALE][29];
        4'd9:  avail_t = !act[SLOT_DOOR0][29]   || !act[SLOT_DOOR0+1][29];
        4'd12: avail_t = !act[SLOT_TREE0][29];
        4'd11: avail_t = !act[SLOT_SPRING0][29] || !act[SLOT_SPRING0+1][29];
        4'd13, 4'd14: avail_t = 1'b0;         // unused tool buttons (sun / cloud deleted)
        4'd6:  avail_t = 1'b0;                // old big-box tool: removed (one crate tool + size button)
        default: avail_t = 1'b1;              // crate tool: stays selectable when full (red ghost)
        endcase
    endfunction
    // line being dragged: locked to the axis the mouse moved along most (rectangle mode: free box)
    wire [6:0] ldc = (mc > la_c) ? mc - la_c : la_c - mc;
    wire [5:0] ldr = (mr > la_r) ? mr - la_r : la_r - mr;
    wire lhor = ({1'b0, ldc} >= {2'b0, ldr});
    wire [6:0] le_x = rect_mode ? mc : (lhor ? mc : la_c);
    wire [5:0] le_y = rect_mode ? mr : (lhor ? la_r : mr);
    wire [6:0] lb   = (brush2 && !rect_mode) ? 7'd1 : 7'd0;
    wire [6:0] lc0w = (la_c < le_x) ? la_c : le_x;
    wire [6:0] lc1t = ((la_c < le_x) ? le_x : la_c) + lb;
    wire [6:0] lc1w = (lc1t > 7'd79) ? 7'd79 : lc1t;
    wire [5:0] lr0w = (la_r < le_y) ? la_r : le_y;
    wire [5:0] lr1t = ((la_r < le_y) ? le_y : la_r) + lb[5:0];
    wire [5:0] lr1w = (lr1t > 6'd44) ? 6'd44 : lr1t;
    // start snaps to the previous line's end when within 2 tiles
    wire snap_ok = le_valid && (((mc > le_c) ? mc - le_c : le_c - mc) <= 7'd2) && (((mr > le_r) ? mr - le_r : le_r - mr) <= 6'd2);

    // rect-op loop position helpers
    wire [6:0] nc = (cc == lc1) ? lc0 : cc + 1;
    wire row_end = (cc == lc1);
    wire op_end  = row_end && (rr == lr1);
    // neighbour k of (cc, rr), clamped
    wire [1:0] kdr = (ki < 3) ? 2'd0 : (ki < 6) ? 2'd1 : 2'd2;
    wire [1:0] kdc = ki - kdr * 3;
    wire [6:0] ncol = (kdc == 0) ? ((cc == 0) ? 7'd0 : cc - 1) : (kdc == 2) ? ((cc == 79) ? 7'd79 : cc + 1) : cc;
    wire [5:0] nrow = (kdr == 0) ? ((rr == 0) ? 6'd0 : rr - 1) : (kdr == 2) ? ((rr == 44) ? 6'd44 : rr + 1) : rr;
    // read issued 1 / 2 clocks ago
    reg rd_pend = 0;
    reg p1 = 0;
    reg p2 = 0;
    // word index of those reads
    reg [11:0] a1 = 0;
    reg [11:0] a2 = 0;
    reg [3:0] kc = 0;

    // ghost helpers
    wire [8:0] hw = gw >> 1;
    wire [10:0] gx_raw = {1'b0, smx} - {2'b0, hw};
    wire [9:0] gx_snap = gx_raw[10] ? 10'd0 : ((gx_raw[9:0] + {1'b0, gw} > 10'd640) ? 10'd640 - gw : {gx_raw[9:3], 3'b0});
    wire [29:0] cand = {1'b1, gx, gy, gp};
    wire [17:0] owh = obj_wh(si, act[si][8:0]);
    wire [9:0] ox = act[si][28:19];
    wire [9:0] oy = act[si][18:9];
    wire overlap = act[si][29] && (si != gslot) && !(si >= SLOT_TREE0) &&
                   (gx < ox + owh[17:9]) && (ox < gx + gw) && (gy < oy + owh[8:0]) && (oy < gy + gh);
    wire under   = act[si][29] && (smx >= ox) && (smx < ox + owh[17:9]) && (smy >= oy) && (smy < oy + owh[8:0]);

    // ---- release 1 helpers ----
    function gameplay;                       // objects that block painting and are validated
        input [4:0] k;                       // (not the gun, the unused mirror slots or decorations)
        gameplay = (k != SLOT_GUN) && !(k >= SLOT_MIR0 && k < SLOT_SPRING0) && (k < SLOT_TREE0);
    endfunction
    wire is_door_si = (si >= SLOT_DOOR0) && (si < SLOT_MIR0);
    wire is_spr_si  = (si >= SLOT_SPRING0) && (si < SLOT_TREE0);
    wire is_box_si  = (si >= SLOT_BOX0) && (si < SLOT_SCALE);
    wire water_op   = (op_type[opi] == 3'd2);
    // object si as seen by clipping: water may cover objects but keeps off crates, doors / springs and their support rows
    wire [9:0] cy0  = (water_op && is_door_si) ? oy - 10'd8 : oy;
    wire [9:0] chh  = {1'b0, owh[8:0]} + ((water_op && is_door_si) ? 10'd16 : (water_op && is_spr_si) ? 10'd8 : 10'd0);
    wire clip_obj   = act[si][29] && gameplay(si) && (!water_op || is_door_si || is_spr_si || is_box_si);
    // op rectangle (px)
    wire [9:0] opx0 = {lc0, 3'b0};
    wire [9:0] opx1 = {lc1, 3'b0} + 10'd8;
    wire [9:0] opy0 = 10'd64 + {lr0, 3'b0};
    wire [9:0] opy1 = 10'd64 + {lr1, 3'b0} + 10'd8;
    wire op_hit     = clip_obj && (opx0 < ox + owh[17:9]) && (ox < opx1) && (opy0 < cy0 + chh) && (cy0 < opy1);
    // tile being painted (px)
    wire [9:0] tpx  = {cc, 3'b0};
    wire [9:0] tpy = 10'd64 + {rr, 3'b0};
    wire tile_hit   = (tpx < ox + owh[17:9]) && (ox < tpx + 10'd8) && (tpy < cy0 + chh) && (cy0 < tpy + 10'd8);
    function [4:0] low1;                     // lowest set bit
        input [15:0] m; integer q;
        begin low1 = 5'd0; for (q = 15; q >= 0; q = q - 1) if (m[q]) low1 = q; end
    endfunction
    // validation: object si against the latched rectangle of object vo
    wire pair_hit = act[si][29] && gameplay(si) && (vx < ox + owh[17:9]) && (ox < vx + vw) && (vy < oy + owh[8:0]) && (oy < vy + vh);
    wire cur_bad  = (level == N_BUILT + 4'd1) ? lvl_bad[1] : lvl_bad[0];
    // boundary floor rule: beside the boundary's lowest tile (column sdc, row sdb), on both sides,
    // solid / reflective ground one row lower and a free tile (air / water, no door / spring / scale)
    // where a dropped 8x8 gun lands (no crate there either - crates are objects now)
    reg [6:0] sdc = 0;
    reg [5:0] sdb = 0;
    reg [5:0] sd_ret = 0;
    reg [1:0] sidx = 0;
    wire [9:0] sdx0 = {sdc, 3'b0} - 10'd8;
    wire [9:0] sdx1 = {sdc, 3'b0} + 10'd16;
    wire [9:0] sdy0 = 10'd64 + {sdb, 3'b0};
    wire side_hit = act[si][29] && (is_door_si || is_spr_si || is_box_si || si == SLOT_SCALE) &&
                    (sdx0 < ox + owh[17:9]) && (ox < sdx1) && (sdy0 < oy + owh[8:0]) && (oy < sdy0 + 10'd8);
    // eraser: next step toward the target (close to a straight line, never skips a tile)
    wire [6:0] edx = (et_c > ep_c) ? et_c - ep_c : ep_c - et_c;
    wire [5:0] edy = (et_r > ep_r) ? et_r - ep_r : ep_r - et_r;
    wire estx = (edx != 0) && ({edx, 1'b0} >= {1'b0, edy});
    wire esty = (edy != 0) && ({edy, 1'b0} >= {2'b0, edx});
    wire [6:0] eb = brush2 ? 7'd1 : 7'd0;
    wire is_bnd_w = !t_rdata[15] && t_rdata[12];        // tile word read back is a boundary tile
    // eraser stamp (px) against crate si: the eraser removes every crate it touches, whole
    wire [9:0] esx0 = {ec0, 3'b0};
    wire [9:0] esx1 = {ec1, 3'b0} + 10'd8;
    wire [9:0] esy0 = 10'd64 + {er0, 3'b0};
    wire [9:0] esy1 = 10'd64 + {er1, 3'b0} + 10'd8;
    wire erase_hit  = act[si][29] && is_box_si && (esx0 < ox + owh[17:9]) && (ox < esx1) && (esy0 < oy + owh[8:0]) && (oy < esy1);
    // resize: grown rectangle (vx, vy, vw, vh) against the character and the other crates
    // also the scale, closed doors and springs (spring: its current platform top to its base)
    wire [9:0] r_oy = is_spr_si ? ((si == SLOT_SPRING0) ? spr_top[9:0] : spr_top[19:10]) : oy;
    wire [9:0] r_oh = is_spr_si ? oy + 10'd96 - r_oy : {1'b0, owh[8:0]};
    wire rsz_hit    = act[si][29] && (si == SLOT_PLAYER || is_box_si || si == SLOT_SCALE || is_spr_si || (is_door_si && !act[si][0])) &&
                      (si != rs_slot) &&
                      (vx < ox + owh[17:9]) && (ox < vx + vw) && (vy < r_oy + r_oh) && (r_oy < vy + vh);
    function [9:0] side_px;                           // character / crate side from its size code
        input [1:0] code;
        side_px = (code == 2'd1) ? 10'd8 : (code == 2'd2) ? 10'd32 : 10'd16;
    endfunction
    function in_obj;                                  // cursor inside a character / crate entry
        input [29:0] e; input [9:0] px, py;
        in_obj = e[29] && px >= e[28:19] && px < e[28:19] + side_px(e[1:0]) && py >= e[18:9] && py < e[18:9] + side_px(e[1:0]);
    endfunction

    // ---- small read ports (size cut, 4 Nov): the character / a crate (slots 0, 3-6) or a door (8-9),
    // a 5-way or 2-way choice instead of a 16-way multiplexer over the whole table ----
    function [29:0] pc_ent;                  // slot k = character or crate; anything else reads 0
        input [4:0] k;
        case (k)
            SLOT_PLAYER:  pc_ent = act[SLOT_PLAYER];
            SLOT_BOX0:    pc_ent = act[SLOT_BOX0];
            SLOT_BOX0+1:  pc_ent = act[SLOT_BOX0+1];
            SLOT_BOX0+2:  pc_ent = act[SLOT_BOX0+2];
            SLOT_BOX0+3:  pc_ent = act[SLOT_BOX0+3];
            default:      pc_ent = 30'd0;
        endcase
    endfunction
    function [29:0] door_ent;                // slot k = one of the two doors
        input [4:0] k;
        door_ent = k[0] ? act[SLOT_DOOR0+1] : act[SLOT_DOOR0];
    endfunction
    wire [29:0] sel_door = door_ent(sel_slot);        // the selected door (door option button)

    //----------------------------------------------------------------------
    // physics requests
    //----------------------------------------------------------------------
    // Handshake (return-to-zero): physics raises phys_req with phys_slot / phys_entry and holds
    // them until phys_ack. The editor answers each request exactly once: one-clock phys_ack with
    // phys_ok (1 applied, 0 rejected; phys_ok stays valid until the next ack). After an ack the
    // editor takes no new request until it has seen phys_req low for at least one clock, so a
    // request left high is never processed twice. Back-to-back requests: drop phys_req for one
    // clock after each ack (about 3 clocks per request; character + 4 crates easily fit one blank).
    // Rejected at once: edit mode, a slot other than 0 / 3-6.
    // Otherwise the request waits (it is never dropped) until play mode, rows 480-499 of the
    // vertical blank, the editor's own job engine idle and no table write / load this clock;
    // then it is rejected if the slot is being resized (resize_busy), the request went stale
    // (a restart / level load happened while it was waiting), the target is empty, or vis / p
    // differ from the current entry (physics moves objects, it cannot add, delete or resize them);
    // else it is applied: act[] (and so `objs`) holds the new entry from the clock after phys_ack.
    // Visible to gun.v in the same blank (it starts at row 500) and on screen from the next frame;
    // aim.v traces from row 480, so its path may use the old position for one frame.
    // Collision against terrain / other objects is the physics engine's job (not repeated here).
    reg p_done = 0;
    reg p_stale = 0;
    wire p_slot_ok = (phys_slot == SLOT_PLAYER) || (phys_slot >= SLOT_BOX0 && phys_slot < SLOT_BOX0 + N_BOX);
    wire [29:0] p_cur    = pc_ent(phys_slot);        // 0 for any other slot (p_slot_ok)
    wire p_pend    = phys_req && !p_done;
    wire p_rej_now = p_pend && (mode_edit || !p_slot_ok);
    wire p_win     = (y >= 10'd480) && (y <= 10'd499);
    wire p_serve   = p_pend && !p_rej_now && p_win && (st == S_IDLE) && !fs && !ow_en && !ld_busy && !table_load && !rst;
    wire rsz_st    = (st == S_RSZ || st == S_RCHK || st == S_ROVL || st == S_RTRY || st == S_RNEXT);
    wire p_rsz     = (rs_pend || rsz_st) && (rs_slot == phys_slot);
    wire p_good    = !p_rsz && !p_stale && p_cur[29] && phys_entry[29] && (phys_entry[8:0] == p_cur[8:0]);
    assign     p_apply   = p_serve && p_good;
    assign     resize_busy = rs_pend || rsz_st;
    assign     resize_slot = rs_slot;
    always @ (posedge clk) begin
        phys_ack <= 1'b0;
        if (!phys_req) p_done <= 1'b0;
        if (table_load && p_pend) p_stale <= 1'b1;
        if (p_rej_now || p_serve) begin
            phys_ack <= 1'b1; phys_ok <= p_apply; p_done <= 1'b1; p_stale <= 1'b0;
        end
    end

    // ---- keep the bank of the user slot being edited equal to the active table ----
    // (one slot per clock, a single write port: far smaller than writing banks directly)
    reg [4:0] sync_i = 0;
    always @ (posedge clk) begin
        sync_i <= (sync_i == NSLOT - 1) ? 5'd0 : sync_i + 1;
        if (mode_edit && level >= N_BUILT && !ld_busy && !table_load)
            bank[sync_i] <= act[sync_i];
    end

    always @ (posedge clk) begin
        t_we <= 1'b0;
        c_we <= 1'b0;
        table_load <= 1'b0;
        ow_en <= 1'b0;
        rd_start <= 1'b0;
        uw_en <= 1'b0;
        if (rd_swap) rs_swap <= 1'b1;
        if (ld_busy) begin
            if (ld_i == NSLOT - 1) begin ld_busy <= 1'b0; table_load <= 1'b1; end
            ld_i <= ld_i + 1;
        end
        if (rst) begin
            st <= S_IDLE; mode_edit <= 1'b0; level <= 4'd0; load_table(4'd0);
            moving <= 0; ghost_on <= 0; sel_on <= 0; sel_bnd <= 0; erasing <= 0; line_on <= 0; u_cnt <= 0; val_busy <= 0;
        end else begin
            if (!mode_edit && level >= N_BUILT && level_cleared && verified != 3'b111)
                verified[level - N_BUILT] <= 1'b1;              // clear check passed
            if (shot_hit && !mode_edit) begin shot_ev <= 1'b1; shot_s <= shot_slot; shot_g <= shot_grow; end   // bullet hit, handled next free frame
            if (mode_edit || table_load) shot_ev <= 1'b0;
            case (st)
            // ---------------------------------------------------------- dispatcher
            S_IDLE: if (fs) begin
                smx <= mx; smy <= my; sl <= mleft; sr <= mright; pl <= sl; pr <= sr;
                grow_ev <= (grow_sw != g_q); shrink_ev <= (shrink_sw != s_q); g_q <= grow_sw; s_q <= shrink_sw;
                st  <= S_STROKE;                              // decide next clock (uses the sampled values)
            end
            S_STROKE: begin
                st <= S_IDLE;
                // a selected boundary keeps a dashed box around it (other hovers draw over it)
                hov_on <= sel_bnd && mode_edit; hov_bad <= 1'b0;
                hov_x0 <= {sb_c, 3'b0}; hov_x1 <= {sb_c, 3'b0} + 10'd8;
                hov_y0 <= 10'd64 + {sb_top, 3'b0}; hov_y1 <= 10'd64 + {sb_bot, 3'b0} + 10'd8;
                // ---------------- buttons ----------------
                if (sl && !pl && (on_top || on_bot)) begin
                    ghost_on <= 1'b0; moving <= 1'b0; erasing <= 1'b0;
                    if (on_top) begin
                        if (avail_t(bidx_f)) tool <= bidx_f;     // greyed tools can't be picked
                        sel_on <= 1'b0; sel_bnd <= 1'b0; line_on <= 1'b0;
                    end
                    else if (!mode_edit) begin                    // play-mode bar
                        if (bidx_f < N_PLAY || (EDITOR_ON && bidx_f >= N_BUILT && bidx_f < N_BUILT + N_USER)) begin
                            level <= bidx_f; load_table(bidx_f);
                            if (bidx_f != level) u_cnt <= 2'd0;    // undo history belongs to one level
                            // an invalid user level can't be played: open it in the editor to repair it
`ifdef REDRAWN_EDITOR
                            if (bidx_f >= N_BUILT && lvl_bad[bidx_f - N_BUILT]) begin   // U1 = level 7 -> lvl_bad[0]
                                mode_edit <= 1'b1; sel_on <= 1'b0; sel_bnd <= 1'b0; st <= S_VAL;
                            end
`endif
                        end else if (bidx_f == 4'd14) load_table(level);
`ifdef REDRAWN_EDITOR
                        else if (bidx_f == 4'd15 && level >= N_BUILT) begin
                            mode_edit <= 1'b1; load_table(level); sel_on <= 1'b0; sel_bnd <= 1'b0; st <= S_VAL;
                        end
`endif
                    end else case (bidx_f)                        // edit-mode bar
                        4'd0: begin                                   // U1 (the one save slot)
                            level <= N_BUILT + bidx_f; load_table(N_BUILT + bidx_f); sel_on <= 0; sel_bnd <= 0;
                            if (N_BUILT + bidx_f != level) u_cnt <= 2'd0;
                            st <= S_VAL;
                        end
                        4'd3: brush2 <= ~brush2;
                        4'd4: rect_mode <= ~rect_mode;
                        4'd5: if (tool == 4'd7)                                                  // crate size: Small -> Normal -> Big -> Small
                                  crate_sz <= (crate_sz == 2'd1) ? 2'd0 : (crate_sz == 2'd0) ? 2'd2 : 2'd1;
4'd6: if (u_cnt != 2'd0) begin wi <= 0; p1 <= 0; p2 <= 0; st <= S_UNDO; end
                        4'd7: begin snap_then <= SN_CLEAR; no_snap <= 1'b0; wi <= 0; p1 <= 0; p2 <= 0; st <= S_SNAP; end
                        4'd8: begin snap_then <= SN_GEN;   no_snap <= 1'b0; wi <= 0; p1 <= 0; p2 <= 0; st <= S_SNAP; end   // random level
                        // 4'd8 / 4'd9 (copy a built-in level) removed in the combined game (4 Nov, LUTs)
                        4'd10: begin                                                            // back to levels
                            mode_edit <= 1'b0; ghost_on <= 1'b0; sel_on <= 1'b0; sel_bnd <= 1'b0;
                            if (cur_bad || val_busy) begin level <= 4'd0; load_table(4'd0); u_cnt <= 2'd0; end   // invalid: not playable
                            else load_table(level);
                        end
                        4'd12: if (sel_on) begin                                                // option A (doors; the crate resize option was removed)
                            if (sel_slot >= SLOT_DOOR0 && sel_slot < SLOT_MIR0) begin
                                snap_then <= SN_DOOR; no_snap <= 1'b0; wi <= 0; p1 <= 0; p2 <= 0; st <= S_SNAP;
                            end
                        end
                        4'd14: if (sel_on) begin snap_then <= SN_DELOBJ; no_snap <= 1'b0; wi <= 0; p1 <= 0; p2 <= 0; st <= S_SNAP; end   // delete selected
                               else if (sel_bnd) begin snap_then <= SN_DELBND; no_snap <= 1'b0; wi <= 0; p1 <= 0; p2 <= 0; st <= S_SNAP; end
                        4'd15: if (act[SLOT_PLAYER][29] && act[SLOT_FLAG][29] && !cur_bad && !val_busy) begin   // play-test
                            mode_edit <= 1'b0; load_table(level); sel_on <= 1'b0; sel_bnd <= 1'b0;
                        end
                        default: ;
                    endcase
                end
                // ---------------- editing in the level area ----------------
                else if (mode_edit && in_level) begin
                    if (moving) begin                                   // carrying something lifted off the canvas
                        gtool <= slot_tool(mv_slot);
                        if (sr && !pr) begin                            // right click: delete it (crates too: they are objects)
                            moving <= 1'b0; ghost_on <= 1'b0;
                            snap_then <= SN_DELCARRY; no_snap <= 1'b0; wi <= 0; p1 <= 0; p2 <= 0; st <= S_SNAP;
                        end else begin                                  // follow the cursor; left click puts it down
                            commit <= sl && !pl; st <= S_GHOST;
                        end
                    end else if (line_on) begin                         // dragging a straight line / rectangle
                        hov_on <= 1'b1; hov_bad <= 1'b0;
                        hov_x0 <= {lc0w, 3'b0}; hov_x1 <= {lc1w, 3'b0} + 10'd8;
                        hov_y0 <= 10'd64 + {lr0w, 3'b0}; hov_y1 <= 10'd64 + {lr1w, 3'b0} + 10'd8;
                        if (sr && !pr) line_on <= 1'b0;                 // right click: cancel the line
                        else if (!sl && !pl) begin                      // released for 2 frames: commit it (1 frame could be a mouse glitch)
                            line_on <= 1'b0;
                            rc0 <= lc0w; sc <= lc1w; rr0 <= lr0w; srow <= lr1w;
                            if (stroke_type != 3'd0) begin le_c <= le_x; le_r <= le_y; le_valid <= 1'b1; end   // the eraser never sets a snap point
                            snap_then <= (stroke_type == 3'd0) ? SN_ERECT : SN_FILL; no_snap <= 1'b0; wi <= 0; p1 <= 0; p2 <= 0; st <= S_SNAP;
                        end
                    end else if (erasing) begin                         // freehand eraser held down
                        hov_on <= 1'b1; hov_bad <= 1'b0;
                        hov_x0 <= {mc, 3'b0}; hov_x1 <= {mc, 3'b0} + (brush2 ? 10'd16 : 10'd8);
                        hov_y0 <= 10'd64 + {mr, 3'b0}; hov_y1 <= 10'd64 + {mr, 3'b0} + (brush2 ? 10'd16 : 10'd8);
                        if (!sl) begin erasing <= 1'b0; st <= S_VAL; end          // released: re-check the level
                        else if (mc != ep_c || mr != ep_r) begin et_c <= mc; et_r <= mr; st <= S_EADV; end
                    end else if (obj_tool(tool)) begin                  // carrying a new object from the toolbar
                        if (!avail_t(tool)) begin tool <= 4'd15; ghost_on <= 1'b0; end   // limit reached: empty hand
                        else if (sr && !pr) ghost_on <= 1'b0;           // right click: cancel (it comes straight back)
                        else begin gtool <= tool; commit <= sl && !pl; st <= S_GHOST; end
                    end else if (tool == 4'd3 && !rect_mode) begin      // freehand eraser: press starts erasing (one undo step)
                        ghost_on <= 1'b0;
                        hov_on <= 1'b1; hov_bad <= 1'b0;
                        hov_x0 <= {mc, 3'b0}; hov_x1 <= {mc, 3'b0} + (brush2 ? 10'd16 : 10'd8);
                        hov_y0 <= 10'd64 + {mr, 3'b0}; hov_y1 <= 10'd64 + {mr, 3'b0} + (brush2 ? 10'd16 : 10'd8);
                        if (sl && !pl) begin
                            sel_on <= 1'b0; sel_bnd <= 1'b0;
                            snap_then <= SN_ERASE; no_snap <= 1'b0; wi <= 0; p1 <= 0; p2 <= 0; st <= S_SNAP;
                        end
                    end else if (tool == 4'd2) begin                    // boundary: auto span, placed with one click
                        ghost_on <= 1'b0;
                        bs_commit <= sl && !pl; br <= mr; vph <= 3'd0; gstep <= 0; st <= S_BSCAN;
                    end else if (sl && !pl) begin                       // press: pick up an object / box, else start a line
                        ghost_on <= 1'b0; find_for <= 2'd2; si <= 0; st <= S_FIND;
                    end else begin
                        ghost_on <= 1'b0;
                        if (line_tool(tool, rect_mode)) begin           // hover box: the brush (rectangle mode: one tile)
                            hov_on <= 1'b1; hov_bad <= 1'b0;
                            hov_x0 <= {(snap_ok && tool != 4'd3) ? le_c : mc, 3'b0}; hov_y0 <= 10'd64 + {(snap_ok && tool != 4'd3) ? le_r : mr, 3'b0};
                            hov_x1 <= {(snap_ok && tool != 4'd3) ? le_c : mc, 3'b0} + ((brush2 && !rect_mode) ? 10'd16 : 10'd8);
                            hov_y1 <= 10'd64 + {(snap_ok && tool != 4'd3) ? le_r : mr, 3'b0} + ((brush2 && !rect_mode) ? 10'd16 : 10'd8);
                        end
                    end
                end else if (mode_edit) begin
                    ghost_on <= moving ? ghost_on : 1'b0;
                    if (line_on && !sl && !pl) line_on <= 1'b0;
                    if (erasing && !sl) begin erasing <= 1'b0; st <= S_VAL; end
                end
                // ---------------- play mode: resize what is under the crosshair ----------------
                if (!mode_edit) begin
                    // test hook (no gravity, no collision): move the character sideways inside the screen
                    if (TEST_MOVE && act[SLOT_PLAYER][29] && (btn_l ^ btn_r) && !rs_pend) begin : tmove
                        reg [9:0] px;
                        reg [9:0] pw;
                        px = act[SLOT_PLAYER][28:19];
                        pw = (act[SLOT_PLAYER][1:0] == 2'd1) ? 10'd8 : (act[SLOT_PLAYER][1:0] == 2'd2) ? 10'd32 : 10'd16;
                        if (btn_r) px = (px + tmove_step + pw > 10'd640) ? 10'd640 - pw : px + tmove_step;
                        else       px = (px < tmove_step) ? 10'd0 : px - tmove_step;
                        ow_en <= 1'b1; ow_slot <= SLOT_PLAYER; ow_data <= {act[SLOT_PLAYER][29], px, act[SLOT_PLAYER][18:0]};   // (keeps 'verified')
                    end
                    if (rs_pend && rs_swap) begin                   // effect midpoint: apply the change
                        rs_pend <= 1'b0; rs_swap <= 1'b0;
                        set_obj(rs_slot, rs_entry);                  // character or crate: one object write
                    end else if (!rs_pend && !rd_busy && shot_ev && !shot_hit) begin   // bullet hit first
                        shot_ev <= 1'b0; rs_shot <= 1'b1; rs_grow <= shot_g; st <= S_RSZ; gstep <= 0;
                    end else if (!rs_pend && !rd_busy && (grow_ev || shrink_ev)) begin
                        rs_shot <= 1'b0; rs_grow <= grow_ev; st <= S_RSZ; gstep <= 0;
                    end
                end
            end

`ifdef REDRAWN_EDITOR
            // ---------------------------------------------------------- op queue
            S_OPS: begin
                if (opi == nops) st <= after_ops;
                else begin cc <= clc(op_c0[opi]); rr <= clr(op_r0[opi]); ki <= 0; kc <= 0; p1 <= 0; p2 <= 0;
                           lc0 <= clc(op_c0[opi]); lc1 <= clc(op_c1[opi]); lr0 <= clr(op_r0[opi]); lr1 <= clr(op_r1[opi]);
                           si <= 0; cm_mask <= 16'd0; gstep <= 0;
                           st <= (op_kind[opi] == 2'd1) ? S_SET : (op_kind[opi] == 2'd3) ? S_CMASK : S_RC_RD; end
            end
            S_SET: if (win) begin                               // one write per clock
                begin : set_blk
                    reg [15:0] w;
                    reg [6:0] dc;
                    reg [5:0] dr;
                    dc = cc - lc0; dr = rr - lr0;
                    case (op_type[opi])
                        3'd1: w = 16'h0001;                     // wall
                        3'd2: w = 16'h0400;                     // water
                        3'd3: w = 16'h1000;                     // boundary
OP_MIR: w = 16'hC000;                   // orientation + caps filled in by the recalculation
                        default: w = 16'h0000;                  // air / Clear
                    endcase
                    ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= cc; ta_r <= rr; t_wdata <= w; t_we <= 1'b1; c_type <= cnib(w); c_we <= 1'b1;
                end
                cc <= nc; if (row_end) rr <= rr + 1;
                if (op_end) begin opi <= opi + 1; st <= S_OPS; end
            end
            // ---- clipped set (terrain strokes): never paint over objects, crates or boundaries ----
            S_CMASK: begin                                      // which objects touch this op at all (one per clock)
                if (op_hit) cm_mask[si] <= 1'b1;
                if (si == NSLOT - 1) begin gstep <= 0; st <= S_CRD; end
                else si <= si + 1;
            end
            S_CRD: begin                                        // read the tile (and for water over ground: the tiles above / below)
                if (gstep == 3'd0) begin if (win) begin ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= cc; ta_r <= rr; gstep <= 3'd1; end end
                else if (gstep == 3'd1) gstep <= 3'd2;
                else if (gstep == 3'd2) begin
                    cw <= t_rdata;
                    // boundaries are whole objects: strokes go around them (crates: object clipping, S_COBJ)
                    cblk <= is_bnd_w;
                    if (water_op && wtype(t_rdata) == T_SOLID) gstep <= 3'd3;   // ground under / over a boundary stays
                    else begin om <= cm_mask; gstep <= 3'd0; st <= S_COBJ; end
                end
                else if (gstep == 3'd3) begin if (win) begin ta_c <= cc; ta_r <= (rr == 0) ? 6'd0 : rr - 1; gstep <= 3'd4; end end
                else if (gstep == 3'd4) begin ta_r <= (rr == 6'd44) ? 6'd44 : rr + 1; gstep <= 3'd5; end
                else if (gstep == 3'd5) begin if (is_bnd_w && rr != 0) cblk <= 1'b1; gstep <= 3'd6; end
                else begin if (is_bnd_w && rr != 6'd44) cblk <= 1'b1; om <= cm_mask; gstep <= 3'd0; st <= S_COBJ; end
            end
            S_COBJ: begin                                       // test the tile against each touching object (2 clocks each)
                if (cblk || om == 16'd0) st <= S_CWR;
                else if (gstep == 3'd0) begin si <= low1(om); gstep <= 3'd1; end
                else begin
                    if (tile_hit) cblk <= 1'b1;
                    om[si] <= 1'b0; gstep <= 3'd0;
                end
            end
            S_CWR: if (win) begin                               // write it unless it was blocked
                if (!cblk) begin : cwr_blk
                    reg [15:0] w;
                    case (op_type[opi])
                        3'd1: w = 16'h0001; 3'd2: w = 16'h0400; 3'd3: w = 16'h1000; OP_MIR: w = 16'hC000;
                        default: w = 16'h0000;
                    endcase
                    ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= cc; ta_r <= rr; t_wdata <= w; t_we <= 1'b1; c_type <= cnib(w); c_we <= 1'b1;
                end
                cblk <= 1'b0; gstep <= 3'd0;
                cc <= nc; if (row_end) rr <= rr + 1;
                if (op_end) begin opi <= opi + 1; st <= S_OPS; end else st <= S_CRD;
            end
            S_RC_RD: begin                                      // read the 9 neighbours (data arrives 2 clocks later)
                if (p2) begin nb[3*kc +: 3] <= wtype(t_rdata); kc <= kc + 1; end
                p2 <= p1;
                if (ki < 9 && (win || ki != 0)) begin
                    ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= ncol; ta_r <= nrow; ki <= ki + 1; p1 <= 1'b1;
                end else p1 <= 1'b0;
                if (kc == 4'd8 && p2) st <= S_RC_WR;
            end
            S_RC_WR: begin
                ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= cc; ta_r <= rr; t_wdata <= calc_word(nb, cc, rr);
                t_we <= 1'b1; c_type <= cnib(calc_word(nb, cc, rr)); c_we <= 1'b1;
                ki <= 0; kc <= 0; p1 <= 0; p2 <= 0;
                cc <= nc; if (row_end) rr <= rr + 1;
                if (op_end) begin opi <= opi + 1; st <= S_OPS; end else st <= S_RC_RD;
            end

            // ---------------------------------------------------------- undo snapshot / restore
            // A snapshot copies the level's 3600 tile words and the 16 object entries into the
            // older of the two undo banks; then the job in snap_then runs.
            S_SNAP: begin
                if (no_snap) wi <= 12'd3600;                    // job without an undo step
                // tiles: read word wi of this level, store it 2 clocks later
                if (p2) begin uw_en <= 1'b1; uw_addr <= {~u_top, a2}; uw_data <= t_rdata; end
                p2 <= p1; a2 <= a1;
                if (wi < 12'd3600 && win && !no_snap) begin
                    ta_lin <= 1'b1; ta_cp <= 1'b0; ta_w <= wi; a1 <= wi; wi <= wi + 1; p1 <= 1'b1;
                end else p1 <= 1'b0;
                if (wi == 12'd3600 && !p1 && !p2) begin
                    if (no_snap) begin oi <= 6'd36; st <= S_UOBJ; end
                    else begin oi <= 6'd0; si <= 5'd0; st <= S_UOBJ; end
                end
            end
            S_UOBJ: begin                                       // snapshot: object words, then the follow-up job
                if (oi < 6'd36) begin
                    uw_en <= 1'b1; uw_addr <= {~u_top, 12'd3600 + {6'd0, oi}};
                    uw_data <= oi[0] ? {2'b00, act[si][29:16]} : act[si][15:0];
                    if (oi[0]) si <= si + 1;
                    oi <= oi + 1;
                end else begin
                    if (!no_snap) begin
                        u_top <= ~u_top; u_cnt <= (u_cnt == 2'd2) ? 2'd2 : u_cnt + 1;
                        verified[level - N_BUILT] <= 1'b0;
                    end
                    no_snap <= 1'b0;
                    opi <= 0; q_clear;
                    case (snap_then)
                        SN_GEN: begin                                  // random level: empty object table, then plan rooms
                                    load_from(2'd2, level); sel_on <= 1'b0; sel_bnd <= 1'b0;
                                    rg_ph <= 4'd0; st <= S_GEN; end
                        SN_CLEAR: begin q_add(2'd1, T_TPL, 8'd0, 7'd0, 8'd79, 7'd44); q_add(2'd2, 3'd0, 8'd0, 7'd0, 8'd79, 7'd44);
                                    after_ops <= S_VAL; st <= S_OPS; sel_on <= 1'b0; sel_bnd <= 1'b0;
                                    load_from(2'd2, level); end
                        SN_FILL: begin                                 // straight line / rectangle, clipped around objects
                            q_add(2'd3, stroke_type, (rc0 < sc) ? rc0 : sc, (rr0 < srow) ? rr0 : srow, (rc0 < sc) ? sc : rc0, (rr0 < srow) ? srow : rr0);
                            q_add(2'd2, 3'd0, ((rc0 < sc) ? rc0 : sc) - 8'd1, ((rr0 < srow) ? rr0 : srow) - 7'd1,
                                              ((rc0 < sc) ? sc : rc0) + 8'd1, ((rr0 < srow) ? srow : rr0) + 7'd1);
                            after_ops <= S_VAL; st <= S_OPS;
                        end
                        SN_ERECT: begin                                // eraser rectangle: whole crates / boundaries first
                            ec0 <= rc0; ec1 <= sc; er0 <= rr0; er1 <= srow; ecc <= rc0; err <= rr0; gstep <= 0; st <= S_ESCAN;
                            uc0 <= (rc0 == 0) ? 7'd0 : rc0 - 1; uc1 <= (sc == 7'd79) ? 7'd79 : sc + 1;
                            ur0 <= (rr0 == 0) ? 6'd0 : rr0 - 1; ur1 <= (srow == 6'd44) ? 6'd44 : srow + 1;
                        end
                        SN_ERASE: begin                                // freehand eraser: first stamp under the cursor
                            erasing <= 1'b1; ep_c <= mc; ep_r <= mr; et_c <= mc; et_r <= mr; st <= S_ESTEP;
                        end
                        SN_PLACE: begin                               // place the ghost object (crates too: object slots 3-6)
                            set_obj(gslot, gent); sel_on <= 1'b1; sel_slot <= gslot; sel_bnd <= 1'b0;
                            if (gslot == SLOT_SCALE) begin
                                if (act[SLOT_SCALE][29]) q_notch(act[SLOT_SCALE], 1'b1);
                                q_notch(gent, 1'b0);
                            end
                            after_ops <= S_VAL; st <= S_OPS;
                        end
                        SN_DELCARRY: begin                             // delete the object being carried
                            set_obj(mv_slot, 30'd0); sel_on <= 1'b0;
                            if (mv_slot == SLOT_SCALE) q_notch(act[SLOT_SCALE], 1'b1);
                            after_ops <= S_VAL; st <= S_OPS;
                        end
                        SN_DELOBJ: begin                               // Delete button: the selected object
                            set_obj(sel_slot, 30'd0); sel_on <= 1'b0;
                            if (sel_slot == SLOT_SCALE) q_notch(act[SLOT_SCALE], 1'b1);
                            after_ops <= S_VAL; st <= S_OPS;
                        end
                        SN_DELBND: begin                               // Delete button: the selected boundary, whole
                            sel_bnd <= 1'b0; ecc <= sb_c; err <= sb_r; br <= sb_r; bphase <= 1'b0; gstep <= 0;
                            uc0 <= (sb_c == 0) ? 7'd0 : sb_c - 1; uc1 <= (sb_c == 7'd79) ? 7'd79 : sb_c + 1;
                            ur0 <= (sb_r == 0) ? 6'd0 : sb_r - 1; ur1 <= (sb_r == 6'd44) ? 6'd44 : sb_r + 1;
                            ebnd_ret <= 1'b1; st <= S_EBND;
                        end
                        SN_DOOR: begin                                 // door option: starts open / closed
                            set_obj(sel_slot, {sel_door[29:1], ~sel_door[0]}); st <= S_VAL;
                        end
                        SN_BND: begin                                  // boundary: one column, ceiling to floor
                            q_add(2'd1, 3'd3, {1'b0, bs_c}, {1'b0, bs_top}, {1'b0, bs_c}, {1'b0, bs_bot});
                            q_add(2'd2, 3'd0, {1'b0, bs_c} - 8'd1, {1'b0, bs_top} - 7'd1, {1'b0, bs_c} + 8'd1, {1'b0, bs_bot} + 7'd1);
                            after_ops <= S_VAL; st <= S_OPS;
                        end
default: st <= S_IDLE;
                    endcase
                end
            end
            S_UNDO: begin                                       // restore the newest bank: tiles (2-clock read pipeline), then objects
                if (p2) begin
                    ta_lin <= 1'b1; ta_cp <= 1'b0; ta_w <= a2; t_wdata <= undo_q; t_we <= 1'b1; c_type <= cnib(undo_q); c_we <= 1'b1;
                end
                p2 <= p1; a2 <= a1;
                if (wi < 12'd3600 && win) begin undo_raddr <= {u_top, wi}; a1 <= wi; wi <= wi + 1; p1 <= 1'b1; end
                else p1 <= 1'b0;
                if (wi == 12'd3600 && !p1 && !p2) begin oi <= 6'd0; gstep <= 3'd0; st <= S_RD_WAIT; ret_undo <= 1'b1; end
            end
            S_COPY: st <= S_VAL;                                // copy level removed (combined game)
            S_RD_WAIT: if (ret_undo) begin                      // undo: object words back into the table (word pairs)
                if (oi == 6'd36) begin
                    ret_undo <= 1'b0; u_top <= ~u_top; u_cnt <= u_cnt - 2'd1;
                    verified[level - N_BUILT] <= 1'b0; table_load <= 1'b1;
                    sel_on <= 1'b0; sel_bnd <= 1'b0; moving <= 1'b0; ghost_on <= 1'b0; st <= S_VAL;
                end else if (gstep == 3'd0) begin undo_raddr <= {u_top, 12'd3600 + {6'd0, oi}}; gstep <= 3'd1; end
                else if (gstep == 3'd1) gstep <= 3'd2;
                else begin
                    if (!oi[0]) lo_w <= undo_q;
                    else begin ow_en <= 1'b1; ow_slot <= oi[5:1]; ow_data <= {undo_q[13:0], lo_w}; end
                    oi <= oi + 1; gstep <= 3'd0;
                end
            end else st <= S_VAL;                               // (was the copy-level write)

            // ---------------------------------------------------------- find object under cursor
            S_FIND: begin                                       // objects beat painting: pick one up if clicked
                if (under) begin
                    moving <= 1'b1; mv_slot <= si; sel_on <= 1'b1; sel_slot <= si; sel_bnd <= 1'b0; st <= S_IDLE;
                end else if (si == NSLOT - 1) begin gstep <= 0; st <= S_PICKBOX; end
                else si <= si + 1;
            end
            S_PICKBOX: begin                                    // a boundary tile: select it (crates are picked as objects in S_FIND)
                if (gstep == 3'd0) begin if (win) begin ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= mc; ta_r <= mr; gstep <= 3'd1; end end
                else if (gstep == 3'd1) gstep <= 3'd2;
                else begin
                    gstep <= 3'd0;
                    if (is_bnd_w) begin                           // select the boundary (Delete removes it)
                        sel_bnd <= 1'b1; sel_on <= 1'b0; sb_c <= mc; sb_r <= mr;
                        br <= mr; bphase <= 1'b0; st <= S_BEXT;
                    end else if (line_tool(tool, rect_mode)) begin   // empty spot: start a straight line
                        line_on <= 1'b1; sel_bnd <= 1'b0;
                        // start snaps to the last line's end only for walls (water / mirror start right at the mouse)
                        la_c <= (snap_ok && tool == 4'd0) ? le_c : mc; la_r <= (snap_ok && tool == 4'd0) ? le_r : mr;
                        stroke_type <= (tool == 4'd0) ? 3'd1 : (tool == 4'd1) ? 3'd2 : (tool == 4'd10) ? OP_MIR : 3'd0;
                        st <= S_IDLE;
                    end else begin sel_bnd <= 1'b0; st <= S_IDLE; end
                end
            end
            S_BEXT: begin                                       // extent of the selected boundary (for its dashed box)
                if (gstep == 3'd0) begin
                    if (win) begin ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= sb_c; ta_r <= br; gstep <= 3'd1; end
                end else if (gstep == 3'd1) gstep <= 3'd2;
                else begin
                    gstep <= 3'd0;
                    if (!bphase) begin                          // upward
                        if (is_bnd_w && br != 0) br <= br - 1;
                        else begin sb_top <= is_bnd_w ? br : br + 1; bphase <= 1'b1; br <= sb_r; end
                    end else begin                              // downward
                        if (is_bnd_w && br != 6'd44) br <= br + 1;
                        else begin sb_bot <= is_bnd_w ? br : br - 1; st <= S_IDLE; end
                    end
                end
            end

            // ---------------------------------------------------------- eraser
            S_ESTEP: begin                                      // one brush stamp at (ep_c, ep_r)
                ec0 <= ep_c; ec1 <= (ep_c + eb > 7'd79) ? 7'd79 : ep_c + eb;
                er0 <= ep_r; er1 <= (ep_r + eb[5:0] > 6'd44) ? 6'd44 : ep_r + eb[5:0];
                ecc <= ep_c; err <= ep_r;
                uc0 <= (ep_c == 0) ? 7'd0 : ep_c - 1; uc1 <= (ep_c + eb + 7'd1 > 7'd79) ? 7'd79 : ep_c + eb + 7'd1;
                ur0 <= (ep_r == 0) ? 6'd0 : ep_r - 1; ur1 <= (ep_r + eb[5:0] + 6'd1 > 6'd44) ? 6'd44 : ep_r + eb[5:0] + 6'd1;
                gstep <= 0; st <= S_ESCAN;
            end
            S_EADV: begin                                       // move one tile toward the cursor
                if (estx) ep_c <= (et_c > ep_c) ? ep_c + 1 : ep_c - 1;
                if (esty) ep_r <= (et_r > ep_r) ? ep_r + 1 : ep_r - 1;
                st <= S_ESTEP;
            end
            S_EAFTER: st <= (ep_c == et_c && ep_r == et_r) ? S_IDLE : S_EADV;
            S_ESCAN: begin                                      // eraser: scan its rectangle for boundary tiles
                if (gstep == 3'd0) begin if (win) begin ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= ecc; ta_r <= err; gstep <= 3'd1; end end
                else if (gstep == 3'd1) gstep <= 3'd2;
                else begin
                    gstep <= 3'd0;
                    if (is_bnd_w) begin                           // part of a boundary: erase all of it
                        br <= err; bphase <= 1'b0; ebnd_ret <= 1'b0; st <= S_EBND;
                    end else if (ecc == ec1 && err == er1) begin    // scan done: whole crates it touches, then the stamp
                        si <= SLOT_BOX0; st <= S_ECRATE;
                    end else if (ecc == ec1) begin ecc <= ec0; err <= err + 1; end
                    else ecc <= ecc + 1;
                end
            end
            S_ECRATE: begin                                     // remove every crate the stamp touches (one slot per clock)
                if (erase_hit) begin
                    set_obj(si, 30'd0);
                    if (sel_on && sel_slot == si) sel_on <= 1'b0;
                end
                if (si == SLOT_BOX0 + N_BOX - 1) begin          // then erase the stamp, tidy up around it
                    q_clear;
                    q_add(2'd1, 3'd0, {1'b0, ec0}, {1'b0, er0}, {1'b0, ec1}, {1'b0, er1});
                    q_add(2'd2, 3'd0, {1'b0, uc0}, {1'b0, ur0}, {1'b0, uc1}, {1'b0, ur1});
                    opi <= 0; after_ops <= erasing ? S_EAFTER : S_VAL; st <= S_OPS;
                end else si <= si + 1;
            end
            S_EBND: begin                                       // remove the boundary through (ecc, err): up, then down
                if (gstep == 3'd0) begin
                    if (win) begin ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= ecc; ta_r <= br; gstep <= 3'd1; end
                end else if (gstep == 3'd1) gstep <= 3'd2;
                else if (gstep == 3'd2) begin
                    if (is_bnd_w) gstep <= 3'd3;
                    else if (!bphase) begin bphase <= 1'b1; br <= err + 1; gstep <= (err == 6'd44) ? 3'd4 : 3'd0; end
                    else gstep <= 3'd4;
                end else if (gstep == 3'd3) begin
                    if (win) begin                              // air over this tile (address still set)
                        t_wdata <= 16'h0000; t_we <= 1'b1; c_type <= 4'd0; c_we <= 1'b1;
                        u_inc(ecc, br);
                        if (!bphase) begin
                            if (br == 0) begin bphase <= 1'b1; br <= err + 1; gstep <= (err == 6'd44) ? 3'd4 : 3'd0; end
                            else begin br <= br - 1; gstep <= 3'd0; end
                        end else begin
                            if (br == 6'd44) gstep <= 3'd4;
                            else begin br <= br + 1; gstep <= 3'd0; end
                        end
                    end
                end else begin                                  // done
                    gstep <= 3'd0;
                    if (!ebnd_ret) st <= S_ESCAN;               // eraser: carry on scanning the stamp
                    else begin                                  // Delete button: tidy up, then re-check
                        q_clear; q_add(2'd2, 3'd0, {1'b0, uc0}, {1'b0, ur0}, {1'b0, uc1}, {1'b0, ur1});
                        opi <= 0; after_ops <= S_VAL; st <= S_OPS;
                    end
                end
            end

            // ---------------------------------------------------------- boundary tool ghost
            // Column under the cursor: must be air; scan up to the ceiling and down to the floor,
            // both must be solid ground, no object in the way, at most 4 boundaries per level.
            S_BSCAN: begin
                if (gstep == 3'd0) begin
                    if (win) begin ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= mc; ta_r <= br; gstep <= 3'd1; end
                end else if (gstep == 3'd1) gstep <= 3'd2;
                else if (gstep == 3'd2) begin
                    gstep <= 3'd0;
                    case (vph)
                    3'd0: begin                                 // the cursor tile
                        bs_c <= mc;
                        if (wtype(t_rdata) != T_AIR) begin bs_ok <= 1'b0; bs_top <= mr; bs_bot <= mr; gstep <= 3'd4; end
                        else begin bs_ok <= 1'b1; vph <= 3'd1; if (mr == 0) begin bs_ok <= 1'b0; bs_top <= 0; vph <= 3'd2; br <= mr; gstep <= 3'd3; end else br <= mr - 1; end
                    end
                    3'd1: begin                                 // upward to the ceiling
                        if (wtype(t_rdata) == T_AIR) begin
                            if (br == 0) begin bs_ok <= 1'b0; bs_top <= 0; vph <= 3'd2; br <= mr; gstep <= 3'd3; end
                            else br <= br - 1;
                        end else begin
                            bs_top <= br + 1; if (wtype(t_rdata) != T_SOLID) bs_ok <= 1'b0;
                            vph <= 3'd2; br <= mr; gstep <= 3'd3;
                        end
                    end
                    default: begin                              // downward to the floor
                        if (wtype(t_rdata) == T_AIR) begin
                            if (br == 6'd44) begin bs_ok <= 1'b0; bs_bot <= 6'd44; gstep <= 3'd5; end
                            else br <= br + 1;
                        end else begin
                            bs_bot <= br - 1; if (wtype(t_rdata) != T_SOLID) bs_ok <= 1'b0;
                            sdc <= mc; sdb <= br - 1; sd_ret <= S_BSCAN; sidx <= 0; gstep <= 3'd0; st <= S_SIDE;   // floor on both sides
                        end
                    end
                    endcase
                end else if (gstep == 3'd3) begin              // start the downward scan below the cursor
                    if (mr == 6'd44) begin bs_ok <= 1'b0; bs_bot <= 6'd44; gstep <= 3'd5; end
                    else begin br <= mr + 1; gstep <= 3'd0; end
                end else if (gstep == 3'd5) begin              // latch the column, test the objects
                    vx <= {bs_c, 3'b0}; vy <= 10'd64 + {bs_top, 3'b0}; vw <= 9'd8; vh <= {bs_bot - bs_top + 6'd1, 3'b0};
                    si <= 0; gstep <= 3'd6;
                end else if (gstep == 3'd6) begin
                    if (pair_hit) bs_ok <= 1'b0;
                    if (si == NSLOT - 1) gstep <= 3'd4; else si <= si + 1;
                end else begin                                  // show it; a click places it (valid) or selects (invalid)
                    hov_on <= 1'b1; hov_bad <= !(bs_ok && bnd_cnt < 3'd4);
                    hov_x0 <= {bs_c, 3'b0}; hov_x1 <= {bs_c, 3'b0} + 10'd8;
                    hov_y0 <= 10'd64 + {bs_top, 3'b0}; hov_y1 <= 10'd64 + {bs_bot, 3'b0} + 10'd8;
                    vph <= 3'd0; gstep <= 3'd0;
                    if (bs_commit && bs_ok && bnd_cnt < 3'd4) begin
                        sel_on <= 1'b0; sel_bnd <= 1'b0; snap_then <= SN_BND; no_snap <= 1'b0; wi <= 0; p1 <= 0; p2 <= 0; st <= S_SNAP;
                    end else if (bs_commit) begin find_for <= 2'd2; si <= 0; st <= S_FIND; end
                    else st <= S_IDLE;
                end
            end

            // ---------------------------------------------------------- validation
            // Runs after every edit (and on loading / copying / undo). About 15,000 clocks:
            //  1. every column top to bottom: each run of boundary tiles needs solid ground right
            //     above and right below; tile bit 14 marks an invalid boundary (drawn red)
            //  2. every gameplay object: inside the level, footprint free of ground / crates /
            //     boundaries, support where needed (spring: full width; door: above and below),
            //     no overlap with another gameplay object
            S_VAL: if (!ld_busy && !table_load) begin
                val_busy <= 1'b1; vc <= 0; vr <= 0; in_run <= 0; prev_solid <= 0; bcnt <= 0; bbad <= 0; nbad <= 0;
                gstep <= 0; st <= S_VSCAN;
            end
            S_VSCAN: begin
                if (gstep == 3'd0) begin if (win) begin ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= vc; ta_r <= vr; gstep <= 3'd1; end end
                else if (gstep == 3'd1) gstep <= 3'd2;
                else if (gstep == 3'd2) begin
                    prev_solid <= (wtype(t_rdata) == T_SOLID);
                    if (is_bnd_w && !in_run) begin in_run <= 1'b1; run_top <= vr; run_ceil <= prev_solid; end
                    if (in_run && !is_bnd_w) begin               // run ended above this tile: this is its floor
                        run_ok <= run_ceil && (wtype(t_rdata) == T_SOLID); run_end <= vr - 1; in_run <= 1'b0;
                        trr <= run_top; gstep <= 3'd0;
                        sdc <= vc; sdb <= vr - 1; sd_ret <= S_VFIX; sidx <= 0; st <= S_SIDE;   // + floor on both sides
                    end else if (is_bnd_w && vr == 6'd44) begin    // reaches the bottom row: no floor
                        run_ok <= 1'b0; run_end <= vr; in_run <= 1'b0;
                        trr <= in_run ? run_top : vr; gstep <= 3'd0; st <= S_VFIX;
                    end else gstep <= 3'd3;
                end else begin                                  // next tile
                    gstep <= 3'd0;
                    if (vr == 6'd44) begin
                        vr <= 0; prev_solid <= 1'b0;
                        if (vc == 7'd79) begin vo <= 0; vph <= 0; st <= S_VOBJ; end
                        else vc <= vc + 1;
                    end else vr <= vr + 1;
                end
            end
            S_SIDE: begin                                       // boundary floor rule; failing clears bs_ok and run_ok
                if (sdc == 0 || sdc == 7'd79 || sdb >= 6'd44) begin bs_ok <= 1'b0; run_ok <= 1'b0; gstep <= (sd_ret == S_BSCAN) ? 3'd5 : 3'd0; st <= sd_ret; end
                else if (gstep == 3'd0) begin
                    if (win) begin ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= sidx[0] ? sdc + 1 : sdc - 1; ta_r <= sidx[1] ? sdb : sdb + 1; gstep <= 3'd1; end
                end else if (gstep == 3'd1) gstep <= 3'd2;
                else if (gstep == 3'd2) begin
                    if (sidx[1] ? (wtype(t_rdata) != T_AIR && wtype(t_rdata) != T_WATER)            // landing tile free
                                : (wtype(t_rdata) != T_SOLID && wtype(t_rdata) != T_MIR)) begin   // ground under it
                        bs_ok <= 1'b0; run_ok <= 1'b0;
                    end
                    sidx <= sidx + 1; si <= 0;
                    gstep <= (sidx == 2'd3) ? 3'd3 : 3'd0;
                end else begin                                  // no door / spring / scale on the landing tiles
                    if (side_hit) begin bs_ok <= 1'b0; run_ok <= 1'b0; end
                    if (si == NSLOT - 1) begin gstep <= (sd_ret == S_BSCAN) ? 3'd5 : 3'd0; st <= sd_ret; end
                    else si <= si + 1;
                end
            end
            S_VFIX: begin                                       // mark the boundary run valid / invalid (tile bit 14)
                if (gstep == 3'd0) begin if (win) begin ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= vc; ta_r <= trr; gstep <= 3'd1; end end
                else if (gstep == 3'd1) gstep <= 3'd2;
                else if (gstep == 3'd2) begin cw <= t_rdata; gstep <= 3'd3; end
                else if (win) begin
                    t_wdata <= {cw[15], !run_ok, cw[13:0]}; t_we <= 1'b1;
                    if (trr >= run_end) begin
                        bcnt <= (bcnt == 3'd7) ? 3'd7 : bcnt + 1; if (!run_ok) bbad <= 1'b1;
                        gstep <= 3'd3; st <= S_VSCAN;
                    end else begin trr <= trr + 1; gstep <= 3'd0; end
                end
            end
            S_VOBJ: begin
                if (gstep == 3'd0) begin
                    if (vo == NSLOT) begin                      // all done
                        obj_bad <= nbad; bnd_cnt <= bcnt;
                        if (level >= N_BUILT) lvl_bad[(level == N_BUILT) ? 1'b0 : 1'b1] <= (|nbad) || bbad;
                        val_busy <= 1'b0; st <= S_IDLE;
                    end else begin si <= vo; vph <= 3'd0; gstep <= 3'd1; end
                end else if (gstep == 3'd1) begin               // latch the object; inside the level?
                    vx <= ox; vy <= oy; vw <= owh[17:9]; vh <= owh[8:0];
                    if (!(act[si][29] && gameplay(si))) begin vo <= vo + 1; gstep <= 3'd0; end
                    else if (oy < 10'd64 || oy + owh[8:0] > 10'd424 || ox + owh[17:9] > 10'd640) begin
                        nbad[vo] <= 1'b1; si <= vo + 1; gstep <= 3'd0; st <= S_VPAIR;
                    end else begin                              // body: must be free of ground
                        tc0 <= is_door_si ? (ox + 10'd12) >> 3 : ox[9:3];
                        tc1 <= is_door_si ? (ox + 10'd12) >> 3 : (ox + owh[17:9] - 10'd1) >> 3;
                        tr0 <= (oy - 10'd64) >> 3; tr1 <= (oy + owh[8:0] - 10'd65) >> 3;
                        tmode <= 1'b0; vph <= 3'd1; gstep <= 3'd2;
                    end
                end else if (gstep == 3'd2) begin               // start a tile-rectangle check
                    tcc <= tc0; trr <= tr0; gstep <= 3'd0; st <= S_VTILE;
                end else begin                                  // gstep 3: after a check, the next one
                    gstep <= 3'd2;
                    if (vph == 3'd1 && is_spr_si) begin         // spring: solid ground under its full width
                        if (tr1 == 6'd44) begin nbad[vo] <= 1'b1; si <= vo + 1; gstep <= 3'd0; st <= S_VPAIR; end
                        else begin tr0 <= tr1 + 1; tr1 <= tr1 + 1; tmode <= 1'b1; vph <= 3'd3; end
                    end else if (vph == 3'd1 && is_door_si) begin   // door: solid ground above
                        if (tr0 == 0) begin nbad[vo] <= 1'b1; si <= vo + 1; gstep <= 3'd0; st <= S_VPAIR; end
                        else begin tr1 <= tr0 - 1; tr0 <= tr0 - 1; vr <= tr1; tmode <= 1'b1; vph <= 3'd2; end
                    end else if (vph == 3'd2) begin             // door: ... and below
                        if (vr == 6'd44) begin nbad[vo] <= 1'b1; si <= vo + 1; gstep <= 3'd0; st <= S_VPAIR; end
                        else begin tr0 <= vr + 1; tr1 <= vr + 1; vph <= 3'd3; end
                    end else begin si <= vo + 1; gstep <= 3'd0; st <= S_VPAIR; end
                end
            end
            S_VTILE: begin                                      // every tile of (tc0..tc1, tr0..tr1): air/water (tmode 0) or ground (1)
                if (gstep == 3'd0) begin if (win) begin ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= tcc; ta_r <= trr; gstep <= 3'd1; end end
                else if (gstep == 3'd1) gstep <= 3'd2;
                else begin
                    gstep <= 3'd0;
                    if (tmode ? (wtype(t_rdata) != T_SOLID) : (wtype(t_rdata) != T_AIR && wtype(t_rdata) != T_WATER)) begin
                        nbad[vo] <= 1'b1; si <= vo + 1; st <= S_VPAIR;   // fails: skip its other checks
                    end else if (tcc == tc1 && trr == tr1) begin gstep <= 3'd3; st <= S_VOBJ; end
                    else if (tcc == tc1) begin tcc <= tc0; trr <= trr + 1; end
                    else tcc <= tcc + 1;
                end
            end
            S_VPAIR: begin                                      // overlaps with the later gameplay objects
                if (si >= NSLOT) begin vo <= vo + 1; gstep <= 3'd0; st <= S_VOBJ; end
                else begin
                    if (pair_hit) begin nbad[vo] <= 1'b1; nbad[si] <= 1'b1; end
                    si <= si + 1;
                end
            end
`endif

            // ---------------------------------------------------------- random level
            S_GEN: begin
                opi <= 0;
                case (rg_ph)
                    4'd0: begin                                     // all ground; random settings
                        rg_rows  <= (rg_lfsr[1:0] == 2'd0) ? 2'd1 : (rg_lfsr[1:0] == 2'd1) ? 2'd2 : 2'd3;
                        rg_c4 <= rg_lfsr[2]; rg_often <= rg_lfsr[3]; rg_flat <= rg_lfsr[4];
                        rg_up <= rg_lfsr[5] && (rg_lfsr[1:0] != 2'd0); rg_hd <= rg_lfsr[6];
                        rg_link <= 2'd0; rg_first <= 1'b1;
                        q_clear; q_add(2'd1, T_SOLID, 8'd0, 7'd0, 8'd79, 7'd44);
                        after_ops <= S_GEN; rg_ph <= 4'd10; st <= S_OPS;
                    end
                    4'd10: begin                                    // start cell
                        rg_gr <= rg_up ? rg_rows - 2'd1 : 2'd0;
                        if (rg_rows == 2'd1) rg_gc <= rg_hd ? 2'd0 : rg_cmax;
                        else rg_gc <= (!rg_c4 && rg_lfsr[1:0] == 2'd3) ? 2'd1 : rg_lfsr[1:0];
                        rg_ph <= 4'd1;
                    end
                    4'd1: begin                                     // plan the room in this cell
                        rg_cx <= rg_cxn;
                        rg_x0 <= rg_cxn + 7'd1 + {4'd0, rg_m5(rg_lfsr[2:0])};
                        rg_x1 <= rg_cxn + rg_w - 7'd6 + {4'd0, rg_m5(rg_lfsr[5:3])};
                        rg_cf <= rg_fn; rg_ct <= rg_tn;
                        rg_ph <= 4'd2;
                    end
                    4'd2: begin                                     // carve the room and the way in
                        q_clear;
                        q_add(2'd1, T_AIR, c8(rg_x0), r7(rg_ct), c8(rg_x1), r7(rg_cf) - 7'd1);
                        rg_lad <= 1'b0;
                        if (rg_link == 2'd1) begin
                            q_add(2'd1, T_AIR, c8(rg_ha), r7(rg_hi) - 7'd4, c8(rg_hb), r7(rg_hi) - 7'd1);      // hall
                            if (rg_hi > rg_lo + 6'd3) begin                                              // opening in the higher room
                                rg_lad <= 1'b1;
                                rg_lc <= (rg_hcx < rg_ocx) ? rg_hcx + rg_w - 7'd6 : rg_hcx + 7'd2;   // 5 wide
                                rg_lt <= rg_lo - 6'd3;
                            end
                        end else if (rg_link == 2'd2) begin                                             // shaft between rows
                            rg_lad <= 1'b1; rg_lc <= rg_cx + rg_mid - 7'd2; rg_lt <= rg_lo - 6'd1;
                        end
                        rg_sb <= rg_hi - 6'd1; rg_odd <= 1'b0; rg_stair <= rg_lfsr[11];
                        rg_sw <= (rg_link == 2'd2 && rg_lfsr[14] && rg_lfsr[10])                     // 1 in 4 row-change shafts: very wide (8-12)
                                 ? (rg_c4 ? 4'd7 + {3'b0, rg_lfsr[12]} : 4'd8 + {2'b0, rg_lfsr[13:12]})
                                 : rg_lfsr[11] ? 4'd3 + {3'b0, rg_lfsr[12]} : 4'd2 + {2'b0, rg_lfsr[13:12]};
                        if (rg_first) begin rg_sx <= rg_x0 + 7'd1; rg_sf <= rg_cf; end
                        rg_first <= 1'b0;
                        rg_lx <= (rg_hd || rg_link == 2'd2) ? rg_x1 - 7'd1 : rg_x0 + 7'd1; rg_lf <= rg_cf;
                        rg_pcx <= rg_cx; rg_pf <= rg_cf;
                        after_ops <= S_GEN; rg_ph <= 4'd11; st <= S_OPS;
                    end
                    4'd11: begin                                    // shaft: straight, or a staircase carved bottom up (rg_sb = next piece bottom)
                        if (!rg_lad) rg_ph <= 4'd4;
                        else if (!rg_stair) begin                    // straight shaft
                            q_clear; q_add(2'd1, T_AIR, c8(rg_lc), r7(rg_lt), c8(rg_lc) + {4'd0, rg_sw}, r7(rg_sb));
                            after_ops <= S_GEN; rg_ph <= 4'd4; st <= S_OPS;
                        end else begin                               // staircase: one 3-row piece per round, bottom up
                            q_clear;
                            q_add(2'd1, T_AIR, c8(rg_lc) + (rg_odd ? 8'd2 : 8'd0), (rg_sb < rg_lt + 6'd2) ? r7(rg_lt) : r7(rg_sb) - 7'd2,
                                               c8(rg_lc) + (rg_odd ? 8'd2 : 8'd0) + {4'd0, rg_sw}, r7(rg_sb));
                            if (rg_sb < rg_lt + 6'd3) rg_ph <= 4'd4;
                            else begin rg_sb <= rg_sb - 6'd3; rg_odd <= ~rg_odd; end
                            after_ops <= S_GEN; st <= S_OPS;
                        end
                    end
                    4'd4: begin                                     // next cell
                        if (!rg_vert) begin
                            rg_gc <= rg_hd ? rg_gc + 2'd1 : rg_gc - 2'd1; rg_link <= 2'd1; rg_ph <= 4'd1;
                        end else if (rg_lrow) rg_ph <= 4'd5;
                        else begin
                            rg_gr <= rg_up ? rg_gr - 2'd1 : rg_gr + 2'd1; rg_link <= 2'd2; rg_hd <= rg_lfsr[3]; rg_ph <= 4'd1;
                        end
                    end
                    4'd5: begin                                     // outlines / grass
                        q_clear; q_add(2'd2, 3'd0, 8'd0, 7'd0, 8'd79, 7'd44);
                        after_ops <= S_GEN; rg_ph <= 4'd6; st <= S_OPS;
                    end
                    4'd6: begin                                     // the character in the first room
                        set_obj(SLOT_PLAYER, {1'b1, rg_sx, 3'b000, 10'd48 + {1'b0, rg_sf, 3'b000}, 9'd0});   // 64 + 8f - 16
                        rg_ph <= 4'd7;
                    end
                    default: begin                                  // the flag in the last room
                        set_obj(SLOT_FLAG, {1'b1, rg_lx, 3'b000, 10'd40 + {1'b0, rg_lf, 3'b000}, 9'd0});   // 64 + 8f - 24
                        st <= S_VAL;
                    end
                endcase
            end

            // ---------------------------------------------------------- resizing (play mode)
            S_RSZ: begin : rsz                                  // character first, else a crate under the crosshair
                reg [4:0] ts;
                reg hitf;
                reg [1:0] osz;
                reg [1:0] nsz;
                reg [9:0] ow;
                reg [9:0] nw;
                reg [9:0] px;
                reg [9:0] py;
                reg [9:0] nx;
                reg [9:0] ny;
                reg [10:0] feet;
                reg [29:0] te;
                hitf = 1'b0; ts = SLOT_PLAYER;
                for (i = SLOT_BOX0 + N_BOX - 1; i >= SLOT_BOX0; i = i - 1)
                    if (in_obj(act[i], smx, smy)) begin hitf = 1'b1; ts = i; end
                if (in_obj(act[SLOT_PLAYER], smx, smy)) begin hitf = 1'b1; ts = SLOT_PLAYER; end
                if (rs_shot) begin                               // the slot the bullet hit
                    ts = shot_s; hitf = pc_ent(shot_s) >> 29;   // vis bit; 0 unless the character / a crate
                end
                te  = pc_ent(ts);                                // ts is always the character or a crate here
                osz = te[1:0];
                ow  = side_px(osz);
                px  = te[28:19]; py = te[18:9];
                // Small <-> Normal <-> Big (8 / 16 / 32 px), feet planted, stays centred (exact pixels)
                nsz = rs_grow ? ((osz == 2'd1) ? 2'd0 : 2'd2) : ((osz == 2'd2) ? 2'd0 : 2'd1);
                nw  = side_px(nsz);
                nx  = px + (ow >> 1) - (nw >> 1); ny = py + ow - nw;
                if (!hitf || (rs_grow && osz == 2'd2) || (!rs_grow && osz == 2'd1)) st <= S_IDLE;   // nothing there / at the limit
                else begin
                    rs_slot  <= ts;
                    rs_entry <= {1'b1, nx, ny, te[8:2], nsz};
                    feet = py + ow;
                    rd_cx <= px + (ow >> 1);
                    rd_cy <= feet - (((ow > nw) ? ow : nw) >> 1);
                    rd_rad <= (((ow > nw) ? ow : nw) >> 1) + (((ow > nw) ? ow : nw) >> 2) + 10'd4;
                    if (rs_grow) begin                       // growing needs free space: terrain, then the other objects
                        // (F): centred first, then the nearest horizontal shift (+1, -1, +2, -2 ...),
                        // never more than half the growth, so the old body stays inside the new one; feet stay
                        rs_nx0 <= nx; rs_nw <= nw; rs_ny <= ny; rs_d <= 5'd0; rs_neg <= 1'b0;
                        rs_dmax <= (nw - ow) >> 1;
                        st <= S_RTRY;
                    end else begin rd_start <= 1'b1; rs_pend <= 1'b1; st <= S_IDLE; end
                end
            end
            S_RCHK: begin                                       // is the grown footprint free of terrain? (air / water only)
                if (gstep == 3'd0) begin if (win) begin ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= ck_c; ta_r <= ck_r; gstep <= 3'd1; end end
                else if (gstep == 3'd1) gstep <= 3'd2;
                else begin
                    gstep <= 3'd0;
                    if (!(wtype(t_rdata) == T_AIR || wtype(t_rdata) == T_WATER) ||
                        ck_c0 > 7'd79 || ck_r0 > 6'd44 || ck_r1 > 6'd44 || ck_c1 > 7'd79)
                        st <= S_RNEXT;                               // blocked here: try the next shift
                    else if (ck_c == ck_c1 && ck_r == ck_r1) begin si <= 5'd0; st <= S_ROVL; end
                    else if (ck_c == ck_c1) begin ck_c <= ck_c0; ck_r <= ck_r + 1; end
                    else ck_c <= ck_c + 1;
                end
            end
            S_ROVL: begin                                       // ... and of the character / the other crates
                if (rsz_hit) st <= S_RNEXT;                      // blocked here: try the next shift
                else if (si == SLOT_SPRING0 + N_SPRING - 1) begin rd_start <= 1'b1; rs_pend <= 1'b1; st <= S_IDLE; end
                else si <= si + 1;
            end
            S_RTRY: begin : rtry                                // grown box at shift (rs_neg ? -rs_d : +rs_d)
                reg [9:0] cx;
                cx = rs_neg ? rs_nx0 - {5'd0, rs_d} : rs_nx0 + {5'd0, rs_d};
                rs_entry[28:19] <= cx;
                vx <= cx; vy <= rs_ny; vw <= rs_nw[8:0]; vh <= rs_nw[8:0];
                ck_c0 <= cx[9:3]; ck_c1 <= (cx + rs_nw - 10'd1) >> 3;
                ck_r0 <= (rs_ny - 10'd64) >> 3; ck_r1 <= (rs_ny + rs_nw - 10'd65) >> 3;
                ck_c <= cx[9:3]; ck_r <= (rs_ny - 10'd64) >> 3; gstep <= 0; st <= S_RCHK;
            end
            S_RNEXT: begin                                      // next candidate, nearest first; none left: unchanged
                if (rs_d == rs_dmax && (rs_neg || rs_d == 5'd0)) st <= S_IDLE;
                else if (rs_d == 5'd0 || rs_neg) begin rs_d <= rs_d + 5'd1; rs_neg <= 1'b0; st <= S_RTRY; end
                else begin rs_neg <= 1'b1; st <= S_RTRY; end
            end

`ifdef REDRAWN_EDITOR
            // ---------------------------------------------------------- ghost / placement
            S_GHOST: begin
                // pick the slot
                gfree = 1'b0; gfull <= 1'b0;
                if (moving) begin gslot <= mv_slot; gfree = 1'b1; end
                else if (tool_count(gtool) == 3'd1) begin gslot <= tool_slot0(gtool); gfree = 1'b1; end
                else begin
                    for (i = 3; i >= 0; i = i - 1)
                        if (i < tool_count(gtool) && !act[tool_slot0(gtool) + i][29]) begin gslot <= tool_slot0(gtool) + i; gfree = 1'b1; end
                    if (!gfree && gtool == 4'd7) begin gslot <= SLOT_XGHOST; gfree = 1'b1; gfull <= 1'b1; end   // 4 crates: red ghost
                end
                if (!gfree) begin ghost_on <= 1'b0; st <= S_IDLE; end
                else begin
                    // size and initial parameter
                    gp <= 9'd0;
                    case (gtool)
                        4'd4: begin gw <= 16; gh <= 16; end
                        4'd5: begin gw <= 16; gh <= 24; end
                        4'd7: begin                                 // crate: carried one keeps its size, a new one uses crate_sz
                            gw <= side_px(moving ? act[mv_slot][1:0] : crate_sz); gh <= side_px(moving ? act[mv_slot][1:0] : crate_sz);
                            gp <= {7'd0, moving ? act[mv_slot][1:0] : crate_sz};
                        end
                        4'd8: begin gw <= 40; gh <= 28; end
                        4'd11: begin gw <= 64; gh <= 96; end
                        4'd12: begin gw <= 32; gh <= 42; end
                        4'd13: begin gw <= 48; gh <= 48; end
                        4'd14: begin gw <= 48; gh <= 16; end
                        default: begin gw <= 24; gh <= 32; gp <= moving ? {7'd0, 1'b0, act[mv_slot][0]} : 9'd0; end
                    endcase
                    gc <= mc; gr <= mr; gvalid <= 1'b1; gstep <= 0; ki <= 0; gsup <= 1'b0;
                    st <= S_G_DOWN;
                end
            end
            S_G_DOWN: begin                                     // per kind: ground scan, door scans, mirror checks
                case (tool_kind(gtool))
                K_FREE: begin
                    gx <= (smx < {1'b0, gw[8:1]}) ? 10'd0 : (smx - gw[8:1] + gw > 10'd640) ? 10'd640 - gw : smx - gw[8:1];
                    gy <= (smy < 10'd64 + gh[8:1]) ? 10'd64 : (smy - gh[8:1] + gh > 10'd424) ? 10'd424 - gh : smy - gh[8:1];
                    st <= S_G_DONE;
                end
                K_DOOR: begin gx <= ({mc, 3'b0} < 10'd8) ? 10'd0 : {mc, 3'b0} - 10'd8; gu <= mr; st <= S_G_UP; end
                default: begin                                      // ground / scale: scan down from the cursor
                    if (gstep == 0) begin gx <= gx_snap; gstep <= 1; end
                    else if (gstep == 1) begin gc <= (gx + gw[8:1]) >> 3; gr <= mr; gstep <= 2; end
                    else if (gstep == 2 && win) begin ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= gc; ta_r <= gr; gstep <= 3; end
                    else if (gstep == 3) gstep <= 4;
                    else if (gstep == 4) begin
                        if (is_ground(wtype(t_rdata))) begin
                            if (gr == mr) begin gvalid <= 1'b0; st <= S_G_DONE; end     // cursor inside a wall / box
                            else begin
                                gy <= (tool_kind(gtool) == K_SCALE) ? 10'd64 + {gr, 3'b0} : 10'd64 + {gr, 3'b0} - gh;
                                gr0 <= gr; gstep <= 0; ki <= 0;
                                st <= S_G_FOOT;
                            end
                        end else if (gr == 6'd44) begin gvalid <= 1'b0; st <= S_G_DONE; end
                        else begin gr <= gr + 1; gstep <= 2; end
                    end
                end
                endcase
            end
            S_G_FOOT: begin                                     // footprint must be clear (scale: notch must be solid)
                if (gstep == 0) begin
                    if (gy < 10'd64) begin gvalid <= 1'b0; st <= S_G_DONE; end
                    else begin
                        gc0 <= gx[9:3]; gc1 <= (gx + gw - 1) >> 3;
                        gr0 <= (tool_kind(gtool) == K_SCALE) ? gr0 : (gy - 10'd64) >> 3;
                        gr1 <= (tool_kind(gtool) == K_SCALE) ? gr0 + 6'd3 : (gy + gh - 10'd65) >> 3;
                        gc <= gx[9:3]; gr <= (tool_kind(gtool) == K_SCALE) ? gr0 : (gy - 10'd64) >> 3;
                        gstep <= (gtool == 4'd12) ? 3'd5 : 3'd1;        // trees skip the check
                    end
                end else if (gstep == 1 && win) begin ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= gc; ta_r <= gr > 6'd44 ? 6'd44 : gr; gstep <= 2; end
                else if (gstep == 2) gstep <= 3;
                else if (gstep == 3) begin
                    if ((tool_kind(gtool) == K_SCALE || gsup) ? (wtype(t_rdata) != T_SOLID)
                                                      : (wtype(t_rdata) != T_AIR && wtype(t_rdata) != T_WATER)) begin
                        gvalid <= 1'b0; st <= S_G_DONE;
                    end else if (gc == gc1 && gr == gr1) gstep <= (gtool == 4'd11 && !gsup) ? 3'd6 : 3'd5;
                    else begin
                        if (gc == gc1) begin gc <= gc0; gr <= gr + 1; end else gc <= gc + 1;
                        gstep <= 1;
                    end
                end else if (gstep == 6) begin                   // solid ground under its full width (E6)
                    if (gr1 == 6'd44) begin gvalid <= 1'b0; st <= S_G_DONE; end
                    else begin gsup <= 1'b1; gr <= gr1 + 6'd1; gr1 <= gr1 + 6'd1; gc <= gc0; gstep <= 1; end
                end else if (gstep == 5) begin                   // crates: keep off the boundary gun-landing tiles first
                    si <= 0; gside <= 2'd0; gstep <= 0; gr <= gr0; gsup <= 1'b0;
                    st <= (gtool == 4'd7) ? S_G_LAND : S_G_OVL;
                end
            end
            S_G_UP: begin                                       // door: find ceiling above, floor below
                if (gstep == 0 && win) begin ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= mc; ta_r <= gu; gstep <= 1; end
                else if (gstep == 1) gstep <= 2;
                else if (gstep == 2) begin
                    if (wtype(t_rdata) == T_SOLID) begin
                        if (gu == mr) begin gvalid <= 1'b0; st <= S_G_DONE; end
                        else begin gy <= 10'd64 + {gu + 6'd1, 3'b0}; gr0 <= gu; gu <= mr; gstep <= 0; st <= S_G_DN2; end
                    end else if (gu == 0) begin gvalid <= 1'b0; st <= S_G_DONE; end
                    else begin gu <= gu - 1; gstep <= 0; end
                end
            end
            S_G_DN2: begin
                if (gstep == 0 && win) begin ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= mc; ta_r <= gu; gstep <= 1; end
                else if (gstep == 1) gstep <= 2;
                else if (gstep == 2) begin
                    if (wtype(t_rdata) == T_SOLID) begin
                        gh <= {gu - gr0 - 6'd1, 3'b0};
                        begin : dp reg [5:0] dr; dr = gu - gr0 - 6'd1; gp <= {dr[4:0], 2'b00, 1'b0, gp[0]}; end
                        if ((gu - gr0 - 6'd1) < 6'd4 || (gu - gr0 - 6'd1) > 6'd31) gvalid <= 1'b0;
                        si <= 0; st <= (gu - gr0 - 6'd1 < 6'd4 || gu - gr0 - 6'd1 > 6'd31) ? S_G_DONE : S_G_OVL;
                    end else if (gu == 6'd44) begin gvalid <= 1'b0; st <= S_G_DONE; end
                    else begin gu <= gu + 1; gstep <= 0; end
                end
            end
            S_G_OVL: begin                                      // no overlap with other gameplay objects
                if (gtool >= 4'd12) st <= S_G_DONE;              // decorations may overlap
                else if (overlap) begin gvalid <= 1'b0; st <= S_G_DONE; end
                else if (si == NSLOT - 1) st <= S_G_DONE;
                else si <= si + 1;
            end
            // Crate ghost: the tile beside the lowest tile of every boundary is where a
            // dropped gun lands; a crate may not cover it. The footprint is air / water already, so
            // only the columns just left (gside 0) and right (gside 1) of it can hold such a boundary:
            // for each footprint row, a boundary tile there whose tile below is not a boundary.
            S_G_LAND: begin
                if (gside == 2'd2) begin si <= 0; st <= S_G_OVL; end
                else if (gstep == 3'd0) begin
                    if ((gside == 2'd0) ? (gc0 == 7'd0) : (gc1 == 7'd79)) begin gside <= gside + 1; gr <= gr0; end   // level edge: nothing there
                    else if (win) begin ta_lin <= 1'b0; ta_cp <= 1'b0; ta_c <= (gside == 2'd0) ? gc0 - 1 : gc1 + 1; ta_r <= gr; gstep <= 3'd1; end
                end
                else if (gstep == 3'd1) gstep <= 3'd2;
                else if (gstep == 3'd2) begin
                    if (is_bnd_w && gr != 6'd44) begin ta_r <= gr + 1; gstep <= 3'd3; end   // boundary: is this its lowest tile?
                    else gstep <= 3'd5;
                end
                else if (gstep == 3'd3) gstep <= 3'd4;
                else if (gstep == 3'd4) begin
                    if (!is_bnd_w) begin gvalid <= 1'b0; st <= S_G_DONE; end
                    else gstep <= 3'd5;
                end
                else begin                                      // next row / column
                    gstep <= 3'd0;
                    if (gr == gr1) begin gside <= gside + 1; gr <= gr0; end else gr <= gr + 1;
                end
            end
            S_G_DONE: begin
                gent <= {1'b1, gx, gy, gp};
                ghost_on <= 1'b1; ghost_ok <= gvalid && !gfull; ghost_slot <= gslot;
                if (commit && gvalid && !gfull) begin commit <= 1'b0; moving <= 1'b0; snap_then <= SN_PLACE; no_snap <= 1'b0; wi <= 0; p1 <= 0; p2 <= 0; st <= S_SNAP; end
                else begin commit <= 1'b0; st <= S_IDLE; end
            end
`endif
            default: st <= S_IDLE;
            endcase
            // level-clear screen / R key (play mode only; wins over a button click in the same clock)
            if (!mode_edit && go_first) begin level <= 4'd0; load_table(4'd0); u_cnt <= 2'd0; end
            else if (!mode_edit && go_restart) load_table(level);
            else if (!mode_edit && go_next) begin
                if (level < N_PLAY - 1) begin level <= level + 4'd1; load_table(level + 4'd1); u_cnt <= 2'd0; end
                else if (level < N_PLAY) begin level <= 4'd0; load_table(4'd0); u_cnt <= 2'd0; end
                else load_table(level);                     // user level: play it again
            end
        end
    end
endmodule

