`timescale 1ns / 1ps


module arena_render (
    input clk,
    input [9:0] x,
    input [9:0] y,
    input video_on,
    input [6:0] terrain_in,         // {idx, shadow, water top, water}

    // players
    input vis1,
    input vis2,
    input [9:0] p1x,                // sprite top left
    input [9:0] p1y,
    input [9:0] p2x,
    input [9:0] p2y,
    input face1,                    // 1 = facing left
    input face2,
    input frz1,
    input frz2,
    input [3:0] gun1_idx,           // from aim_gun2
    input [3:0] gun2_idx,
    input [9:0] m1x,                // crosshairs
    input [9:0] m1y,
    input [9:0] m2x,
    input [9:0] m2y,

    // shots, ammo boxes, crates
    input [3:0] b_on,
    input [3:0] b_frz,
    input [39:0] b_x,               // shot centres, 10 bits each
    input [39:0] b_y,
    input k0_on,
    input k1_on,
    input [9:0] k0_x,
    input [9:0] k0_y,
    input [9:0] k1_x,
    input [9:0] k1_y,
    input [1:0] map,
    input cr_on,
    input [9:0] ca_x,
    input [9:0] ca_y,
    input [9:0] cb_x,
    input [9:0] cb_y,
    input [1:0] sz_a,               // 0 normal, 1 small, 2 big
    input [1:0] sz_b,

    // hud
    input [6:0] hp1,
    input [6:0] hp2,
    input [3:0] af1,                // fire ammo
    input [3:0] az1,                // freeze ammo
    input [3:0] af2,
    input [3:0] az2,
    input [4:0] kills1,
    input [4:0] kills2,
    input [8:0] time_left,

    // from match_fsm
    input [2:0] ui_screen,
    input [1:0] ui_count,
    input ui_sel,
    input ui_map,                   // 0 bridges, 1 towers
    input [1:0] pause_owner,
    input [1:0] winner,
    input by_quit,
    // hit spark (from bullets.v) and the crate redraw effect (redrawn's redraw.v)
    input [1:0] psz1,               // player sizes, 0 normal 1 small 2 big
    input [1:0] psz2,
    input sk_on,
    input sk_frz,
    input [2:0] sk_t,
    input [9:0] sk_x,
    input [9:0] sk_y,
    input [3:0] rd_idx,             // same timing as terrain_in
    output reg [11:0] rgb
    );
    `include "sprite_data_a.vh"
    `include "arena_data.vh"

    // small crate (not in sprite_data_a.vh)
    localparam SPR_CRATE_SMALL_W = 8;
    localparam SPR_CRATE_SMALL_H = 8;
    localparam [255:0] SPR_CRATE_SMALL = 256'h1111111115555551156665511566565115656651155666511555555111111111;

    localparam [11:0] PAPER   = 12'hEDB;
    localparam [11:0] STRIPE  = 12'hDCA;
    localparam [11:0] SHADOWC = 12'hCB9;
    localparam [11:0] WATER   = 12'h4AE;
    localparam [11:0] SURFACE = 12'h9CE;

    // ui_screen
    localparam MENU   = 3'd0;
    localparam COUNT  = 3'd1;
    localparam PLAY   = 3'd2;
    localparam PAUSE  = 3'd3;
    localparam OVER   = 3'd4;
    localparam MAPSEL = 3'd5;

    localparam [9:0] HIDE = 10'd1023;      // off screen

    // palette index
    localparam [3:0] K     = 4'h1;         // black
    localparam [3:0] WH    = 4'h2;
    localparam [3:0] GRN   = 4'h3;
    localparam [3:0] LGRN  = 4'h4;
    localparam [3:0] ORA   = 4'h8;
    localparam [3:0] RED   = 4'h9;
    localparam [3:0] BLU   = 4'hA;
    localparam [3:0] LBLU  = 4'hB;
    localparam [3:0] PINK  = 4'hD;
    localparam [3:0] DPINK = 4'hE;
    localparam [3:0] YEL   = 4'hF;

    initial begin
        rgb = 0;
    end

    // half and half mix of 2 colours (water)
    // average of 2 colours per channel, used to see the paper through water
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

    // frame counter
    // frame counter (not used for drawing now, kept from before)
    reg [7:0] frame = 0;
    reg vb_q = 0;
    always @ (posedge clk) begin
        vb_q <= (y >= 10'd480);
        if ((y >= 10'd480) && !vb_q) begin
            frame <= frame + 1;
        end
    end

    // terrain from redrawn tilemap (arena = slot 8)
    wire [3:0] i_terrain;
    wire sh_terrain;
    wire w_surf;
    wire w_body;
    // i_terrain = palette index, sh = shadow under ledges,
    // w_surf = water top line, w_body = inside water
    assign {i_terrain, sh_terrain, w_surf, w_body} = terrain_in;

    // trees
    wire [3:0] i_tree0;
    wire [3:0] i_tree1;
    // sprite: gives the palette index of the sprite at (x, y), 0 if outside
    // x0 / y0 = top left, HIDE puts it off screen, SHIFT 1 = drawn 2x
    sprite #(.W(SPR_TREE_W), .H(SPR_TREE_H), .SHIFT(1), .DATA(SPR_TREE)) u_tree0
        (.clk(clk), .x(x), .y(y), .x0(tree_x({map, 1'b0})), .y0(tree_y({map, 1'b0})), .flip(1'b0), .idx(i_tree0), .box());
    sprite #(.W(SPR_TREE_W), .H(SPR_TREE_H), .SHIFT(1), .DATA(SPR_TREE)) u_tree1
        (.clk(clk), .x(x), .y(y), .x0(tree_x({map, 1'b1})), .y0(tree_y({map, 1'b1})), .flip(1'b1), .idx(i_tree1), .box());

    // crates, any of 3 sizes
    wire [3:0] i_ca;
    wire [3:0] i_cb;
    // sprite_sz draws the crate at size sz (8, 16 or 32 px)
    sprite_sz #(.W(SPR_CRATE_W), .H(SPR_CRATE_H), .DATA(SPR_CRATE),
        .AW(SPR_CRATE_SMALL_W), .AH(SPR_CRATE_SMALL_H), .ADATA(SPR_CRATE_SMALL), .HAS_ALT(1)) u_ca
        (.clk(clk), .x(x), .y(y), .x0(cr_on ? ca_x : HIDE), .y0(cr_on ? ca_y : HIDE), .sz(sz_a), .flip(1'b0), .idx(i_ca), .box());
    sprite_sz #(.W(SPR_CRATE_W), .H(SPR_CRATE_H), .DATA(SPR_CRATE),
        .AW(SPR_CRATE_SMALL_W), .AH(SPR_CRATE_SMALL_H), .ADATA(SPR_CRATE_SMALL), .HAS_ALT(1)) u_cb
        (.clk(clk), .x(x), .y(y), .x0(cr_on ? cb_x : HIDE), .y0(cr_on ? cb_y : HIDE), .sz(sz_b), .flip(1'b0), .idx(i_cb), .box());

    // ammo boxes
    wire [3:0] i_k0;
    wire [3:0] i_k1;
    sprite #(.W(SPR_AMMO_BOX_W), .H(SPR_AMMO_BOX_H), .SHIFT(0), .DATA(SPR_AMMO_BOX)) u_k0
        (.clk(clk), .x(x), .y(y), .x0(k0_on ? k0_x : HIDE), .y0(k0_on ? k0_y : HIDE), .flip(1'b0), .idx(i_k0), .box());
    sprite #(.W(SPR_AMMO_BOX_W), .H(SPR_AMMO_BOX_H), .SHIFT(0), .DATA(SPR_AMMO_BOX)) u_k1
        (.clk(clk), .x(x), .y(y), .x0(k1_on ? k1_x : HIDE), .y0(k1_on ? k1_y : HIDE), .flip(1'b0), .idx(i_k1), .box());

    // players
    wire [3:0] i_p1r;
    wire [3:0] i_p2r;
    // sprite_sz: normal art 1x, small art 1x, normal art 2x (big), like single player
    sprite_sz #(.W(SPR_PLAYER_W), .H(SPR_PLAYER_H), .DATA(SPR_PLAYER),
        .AW(SPR_PLAYER_SMALL_W), .AH(SPR_PLAYER_SMALL_H), .ADATA(SPR_PLAYER_SMALL), .HAS_ALT(1)) u_p1
        (.clk(clk), .x(x), .y(y), .x0(vis1 ? p1x : HIDE), .y0(vis1 ? p1y : HIDE), .sz(psz1), .flip(face1), .idx(i_p1r), .box());
    sprite_sz #(.W(SPR_PLAYER_W), .H(SPR_PLAYER_H), .DATA(SPR_PLAYER),
        .AW(SPR_PLAYER_SMALL_W), .AH(SPR_PLAYER_SMALL_H), .ADATA(SPR_PLAYER_SMALL), .HAS_ALT(1)) u_p2
        (.clk(clk), .x(x), .y(y), .x0(vis2 ? p2x : HIDE), .y0(vis2 ? p2y : HIDE), .sz(psz2), .flip(face2), .idx(i_p2r), .box());

    // frozen delayed 2 clk to line up with sprite
    // the sprite answer is 2 clk late so the frozen flag must be too
    reg [1:0] frz1_d = 0;
    reg [1:0] frz2_d = 0;
    always @ (posedge clk) begin
        frz1_d <= {frz1_d[0], frz1};
        frz2_d <= {frz2_d[0], frz2};
    end

    // frozen, all except black and white -> light blue
    function [3:0] ice;
        input [3:0] i;
        begin
            if (i == 4'h0 || i == K)
                ice = i;
            else if (i == WH)
                ice = WH;
            else
                ice = LBLU;
        end
    endfunction

    // p2 pink -> green
    function [3:0] to_green;
        input [3:0] i;
        begin
            if (i == PINK)
                to_green = LGRN;
            else if (i == DPINK)
                to_green = GRN;
            else
                to_green = i;
        end
    endfunction

    // one player sprite in memory, p2 just recoloured
    wire [3:0] i_p1 = (frz1_d[1] == 1) ? ice(i_p1r) : i_p1r;
    wire [3:0] i_p2 = (frz2_d[1] == 1) ? ice(i_p2r) : to_green(i_p2r);

    // shots, red = fire, blue = freeze
    // one sprite per shot slot, the red shot turns blue for freeze
    wire [3:0] i_shot [0:3];
    reg [3:0] frz_d1 = 0;
    reg [3:0] frz_d2 = 0;
    always @ (posedge clk) begin
        frz_d1 <= b_frz;
        frz_d2 <= frz_d1;
    end
    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_shot
            wire [3:0] raw;
            sprite #(.W(SPR_AMMO_SHRINK_W), .H(SPR_AMMO_SHRINK_H), .SHIFT(0), .DATA(SPR_AMMO_SHRINK)) u_shot
                (.clk(clk), .x(x), .y(y),
                .x0(b_on[gi] ? b_x[gi*10 +: 10] - 10'd3 : HIDE), .y0(b_on[gi] ? b_y[gi*10 +: 10] - 10'd3 : HIDE),
                .flip(1'b0), .idx(raw), .box());
            assign i_shot[gi] = (frz_d2[gi] && raw == RED) ? BLU : raw;
        end
    endgenerate

    // hit spark, same look as single player: a ring that grows 3 -> 10 px over
    // 8 frames, rim red for a fire shot / blue for freeze, flashing middle for
    // the first 4 frames (yellow-orange fire, white-light blue freeze)
    wire [9:0] sax = (x > sk_x) ? x - sk_x : sk_x - x;
    wire [9:0] say = (y > sk_y) ? y - sk_y : sk_y - y;
    wire [9:0] smx_ = (sax > say) ? sax : say;
    wire [9:0] smn = (sax > say) ? say : sax;
    wire [10:0] sd = smx_ + (smn >> 2) + (smn >> 3);   // about the distance (max + 3/8 min)
    wire [10:0] srad = 11'd3 + sk_t;
    wire [3:0] sk_pix = (!sk_on || sd >= srad) ? 4'h0 :
                        (sd + 11'd2 >= srad) ? (sk_frz ? BLU : RED) :
                        (sk_t < 3'd4) ? ((x[1] ^ y[1]) ? (sk_frz ? WH : YEL) : (sk_frz ? LBLU : ORA)) : 4'h0;
    // 2 clk delay to line up with the sprites
    reg [3:0] sk_q1 = 0;
    reg [3:0] i_spark = 0;
    always @ (posedge clk) begin
        sk_q1 <= sk_pix;
        i_spark <= sk_q1;
    end

    // crosshair, white middle, outline in player colour
    // adx, ady = distance from the mouse point, gives a + shape
    function [3:0] cross;
        input [9:0] xx;
        input [9:0] yy;
        input [9:0] cx;
        input [9:0] cy;
        input [3:0] col;
        reg [9:0] adx;
        reg [9:0] ady;
        begin
            adx = (xx > cx) ? xx - cx : cx - xx;
            ady = (yy > cy) ? yy - cy : cy - yy;
            if ((ady == 0 && adx >= 2 && adx <= 6) || (adx == 0 && ady >= 2 && ady <= 6))
                cross = WH;
            else if ((ady <= 1 && adx >= 1 && adx <= 7) || (adx <= 1 && ady >= 1 && ady <= 7))
                cross = col;
            else
                cross = 4'h0;
        end
    endfunction

    wire show_cross = (ui_screen == PLAY);
    // 2 clk delay to line up with the sprites
    reg [3:0] c1_q1 = 0;
    reg [3:0] c1_q2 = 0;
    reg [3:0] c2_q1 = 0;
    reg [3:0] c2_q2 = 0;
    always @ (posedge clk) begin
        if (show_cross == 1 && vis1 == 1) begin
            c1_q1 <= cross(x, y, m1x, m1y, DPINK);
        end
        else begin
            c1_q1 <= 4'h0;
        end
        if (show_cross == 1 && vis2 == 1) begin
            c2_q1 <= cross(x, y, m2x, m2y, GRN);
        end
        else begin
            c2_q1 <= 4'h0;
        end
        c1_q2 <= c1_q1;
        c2_q2 <= c2_q1;
    end

    // hud, health bars 100 px = 100 hp
    localparam [9:0] BAR1  = 10'd50;
    localparam [9:0] BAR2  = 10'd490;
    localparam [9:0] BAR_Y = 10'd10;

    // hp bar at bx: black outline, filled part = hp px wide
    function [3:0] bar;
        input [9:0] xx;
        input [9:0] yy;
        input [9:0] bx;
        input [6:0] hp;
        input [3:0] col;
        begin
            if (xx + 1 < bx || xx > bx + 100 || yy + 1 < BAR_Y || yy > BAR_Y + 10)
                bar = 4'h0;
            else if (xx + 1 == bx || xx == bx + 100 || yy + 1 == BAR_Y || yy == BAR_Y + 10)
                bar = K;                    // outline
            else if (xx - bx < hp)
                bar = (hp <= 25) ? RED : col;   // red when low
            else
                bar = WH;
        end
    endfunction

    reg [3:0] bar_q1 = 0;
    reg [3:0] bar_q2 = 0;
    always @ (posedge clk) begin
        bar_q1 <= bar(x, y, BAR1, hp1, DPINK) | bar(x, y, BAR2, hp2, GRN);   // never overlap
        bar_q2 <= bar_q1;
    end

    // hearts and ammo icons
    wire [3:0] i_h1;
    wire [3:0] i_h2;
    wire [3:0] i_f1;
    wire [3:0] i_z1r;
    wire [3:0] i_f2;
    wire [3:0] i_z2r;
    sprite #(.W(SPR_HEART_W), .H(SPR_HEART_H), .SHIFT(1), .DATA(SPR_HEART)) u_h1
        (.clk(clk), .x(x), .y(y), .x0(10'd32), .y0(10'd9), .flip(1'b0), .idx(i_h1), .box());
    sprite #(.W(SPR_HEART_W), .H(SPR_HEART_H), .SHIFT(1), .DATA(SPR_HEART)) u_h2
        (.clk(clk), .x(x), .y(y), .x0(10'd472), .y0(10'd9), .flip(1'b0), .idx(i_h2), .box());
    sprite #(.W(SPR_AMMO_SHRINK_W), .H(SPR_AMMO_SHRINK_H), .SHIFT(1), .DATA(SPR_AMMO_SHRINK)) u_f1
        (.clk(clk), .x(x), .y(y), .x0(10'd50), .y0(10'd30), .flip(1'b0), .idx(i_f1), .box());
    sprite #(.W(SPR_AMMO_SHRINK_W), .H(SPR_AMMO_SHRINK_H), .SHIFT(1), .DATA(SPR_AMMO_SHRINK)) u_z1
        (.clk(clk), .x(x), .y(y), .x0(10'd86), .y0(10'd30), .flip(1'b0), .idx(i_z1r), .box());
    sprite #(.W(SPR_AMMO_SHRINK_W), .H(SPR_AMMO_SHRINK_H), .SHIFT(1), .DATA(SPR_AMMO_SHRINK)) u_f2
        (.clk(clk), .x(x), .y(y), .x0(10'd490), .y0(10'd30), .flip(1'b0), .idx(i_f2), .box());
    sprite #(.W(SPR_AMMO_SHRINK_W), .H(SPR_AMMO_SHRINK_H), .SHIFT(1), .DATA(SPR_AMMO_SHRINK)) u_z2
        (.clk(clk), .x(x), .y(y), .x0(10'd526), .y0(10'd30), .flip(1'b0), .idx(i_z2r), .box());
    wire [3:0] i_z1 = (i_z1r == RED) ? BLU : i_z1r;     // freeze icon blue
    wire [3:0] i_z2 = (i_z2r == RED) ? BLU : i_z2r;

    // number -> ascii
    function [7:0] dig;
        input [3:0] n;
        begin
            dig = 8'h30 + n;
        end
    endfunction

    // 0-99 -> 2 chars
    // no divider: find the tens by comparing, units = n - tens * 10
    function [15:0] two;
        input [6:0] n;
        reg [3:0] t;
        begin
            if (n >= 90)
                t = 9;
            else if (n >= 80)
                t = 8;
            else if (n >= 70)
                t = 7;
            else if (n >= 60)
                t = 6;
            else if (n >= 50)
                t = 5;
            else if (n >= 40)
                t = 4;
            else if (n >= 30)
                t = 3;
            else if (n >= 20)
                t = 2;
            else if (n >= 10)
                t = 1;
            else
                t = 0;
            two = {dig(t), dig(n - t * 10)};
        end
    endfunction

    // time left -> m:ss
    // time_left in s -> minutes by comparing (max 5 min)
    wire [2:0] mins = (time_left >= 300) ? 3'd5 : (time_left >= 240) ? 3'd4 : (time_left >= 180) ? 3'd3 :
                      (time_left >= 120) ? 3'd2 : (time_left >= 60)  ? 3'd1 : 3'd0;
    wire [8:0] secs9 = time_left - mins * 9'd60;
    wire [6:0] secs = secs9[6:0];

    wire [13:0] c_time;
    text_cell #(.LEN(4), .SHIFT(2)) u_time (.clk(clk), .x(x), .y(y), .x0(10'd290), .y0(10'd8),
        .str({dig({1'b0, mins}), ":", two(secs)}), .en(1'b1), .cq(c_time));

    // ammo pips, 1 bar (3 x 10) per shot, max 5
    // dx[4:2] = which pip, dx[1:0] = 3 makes the gap between pips
    function pips;
        input [9:0] xx;
        input [9:0] yy;
        input [9:0] x0;
        input [3:0] n;
        reg [9:0] dx;
        reg [3:0] m;
        begin
            dx = xx - x0;
            m = (n > 4'd5) ? 4'd5 : n;
            pips = (yy >= 10'd32) && (yy < 10'd42) && (xx >= x0) && (dx < 10'd20) &&
                   (dx[1:0] != 2'b11) && ({6'd0, dx[4:2]} < {6'd0, m});
        end
    endfunction

    reg [1:0] pip_d = 0;
    always @ (posedge clk) begin
        pip_d <= {pip_d[0], pips(x, y, 10'd66, af1) | pips(x, y, 10'd102, az1) |
                            pips(x, y, 10'd506, af2) | pips(x, y, 10'd542, az2)};
    end

    // message panel (menu, map, pause, over)
    wire panel_on = (ui_screen == MENU) || (ui_screen == PAUSE) || (ui_screen == OVER) || (ui_screen == MAPSEL);
    localparam [9:0] PX0 = 10'd184;
    localparam [9:0] PX1 = 10'd455;
    localparam [9:0] PY0 = 10'd180;
    localparam [9:0] PY1 = 10'd299;

    // white box with black border in the middle of the screen
    reg [3:0] pan_q1 = 0;
    reg [3:0] pan_q2 = 0;
    always @ (posedge clk) begin
        if (!panel_on || x < PX0 || x > PX1 || y < PY0 || y > PY1) begin
            pan_q1 <= 4'h0;
        end
        else if (x < PX0 + 3 || x > PX1 - 3 || y < PY0 + 3 || y > PY1 - 3) begin
            pan_q1 <= K;                // border
        end
        else begin
            pan_q1 <= WH;
        end
        pan_q2 <= pan_q1;
    end

    // panel text, A = big title, B and C small
    // strings are 8 bits per char, first char in the top bits
    // x positions picked so each line is centred
    reg [8*13-1:0] strA;
    reg [8*14-1:0] strB;
    reg [8*15-1:0] strC;
    reg [9:0] xa;
    reg [9:0] xb;
    reg [9:0] xc;
    always @ (*) begin
        strA = {13{" "}};
        strB = {14{" "}};
        strC = {15{" "}};
        xa = 10'd216;
        xb = 10'd224;
        xc = 10'd224;
        case (ui_screen)
            MENU: begin
                strA = "REDRAWN ARENA";
                xa = 10'd216;
                strB = {"PRESS ENTER", {3{" "}}};
                xb = 10'd276;
                strC = "MOST KILLS WINS";
                xc = 10'd260;
            end
            MAPSEL: begin
                strA = {"CHOOSE ARENA", " "};
                xa = 10'd224;
                if (ui_map == 0) begin
                    strB = "< BRIDGES >   ";
                    xb = 10'd276;
                end
                else begin
                    strB = "< TOWERS >    ";
                    xb = 10'd280;
                end
                strC = "ENTER TO START ";
                xc = 10'd264;
            end
            PAUSE: begin
                strA = {"PAUSED BY P", (pause_owner == 2'd1) ? "1" : "2", " "};
                xa = 10'd224;
                // > on the chosen one
                if (ui_sel == 0) begin
                    strB = {"> ", "RESUME", {6{" "}}};
                    strC = {"  ", "QUIT", {9{" "}}};
                end
                else begin
                    strB = {"  ", "RESUME", {6{" "}}};
                    strC = {"> ", "QUIT", {9{" "}}};
                end
                xb = 10'd284;
                xc = 10'd284;
            end
            OVER: begin
                if (winner == 2'd1) begin
                    strA = {"P1 WINS!", {5{" "}}};
                    xa = 10'd256;
                end
                else if (winner == 2'd2) begin
                    strA = {"P2 WINS!", {5{" "}}};
                    xa = 10'd256;
                end
                else begin
                    strA = {"DRAW", {9{" "}}};
                    xa = 10'd288;
                end
                if (by_quit == 1) begin
                    strB = {"P", (winner == 2'd1) ? "2" : "1", " QUIT", {7{" "}}};
                    xb = 10'd292;
                end
                else begin
                    strB = {"TIME UP ", two({2'b0, kills1}), "-", two({2'b0, kills2}), " "};
                    xb = 10'd268;
                end
                strC = {"ESC MENU", {7{" "}}};      // enter = rematch
                xc = 10'd288;
            end
            default: begin
            end
        endcase
    end

    // all text shares 1 font lookup, lines never on screen at same place
    // same shared font trick as the menu (one text_glyph for all text)
    wire [13:0] c_a;
    wire [13:0] c_b;
    wire [13:0] c_c;
    wire [13:0] c_cnt;
    text_cell #(.LEN(13), .SHIFT(2)) u_la (.clk(clk), .x(x), .y(y), .x0(xa), .y0(10'd196), .str(strA), .en(panel_on), .cq(c_a));
    text_cell #(.LEN(14), .SHIFT(1)) u_lb (.clk(clk), .x(x), .y(y), .x0(xb), .y0(10'd240), .str(strB), .en(panel_on), .cq(c_b));
    text_cell #(.LEN(15), .SHIFT(1)) u_lc (.clk(clk), .x(x), .y(y), .x0(xc), .y0(10'd270), .str(strC), .en(panel_on), .cq(c_c));
    // countdown 3 2 1 GO
    text_cell #(.LEN(2), .SHIFT(3)) u_cnt (.clk(clk), .x(x), .y(y),
        .x0((ui_count == 0) ? 10'd292 : 10'd308), .y0(10'd200),
        .str((ui_count == 0) ? "GO" : {dig({2'b0, ui_count}), " "}), .en(ui_screen == COUNT), .cq(c_cnt));
    wire t_any;
    text_glyph u_font (.clk(clk), .cq(c_time | c_a | c_b | c_c | c_cnt), .on(t_any));

    // background stripes, delayed 2 clk
    wire [10:0] diag = x + y;
    reg [1:0] stripe_d = 0;
    reg [1:0] von_d = 0;
    always @ (posedge clk) begin
        stripe_d <= {stripe_d[0], (diag[3:2] == 2'b00)};
        von_d <= {von_d[0], video_on};
    end

    // mixer, lowest first, later one wins
    // go from back to front, every layer that is not 0 overwrites top
    // so the last one that has something wins
    integer k;
    reg [3:0] top;
    always @ (*) begin
        top = 4'h0;
        if (i_terrain != 0) top = i_terrain;
        if (i_tree0 != 0)   top = i_tree0;
        if (i_tree1 != 0)   top = i_tree1;
        if (i_ca != 0)      top = i_ca;
        if (i_cb != 0)      top = i_cb;
        if (i_k0 != 0)      top = i_k0;
        if (i_k1 != 0)      top = i_k1;
        if (i_p1 != 0)      top = i_p1;
        if (i_p2 != 0)      top = i_p2;
        if (gun1_idx != 0)  top = gun1_idx;
        if (gun2_idx != 0)  top = gun2_idx;
        for (k = 0; k < 4; k = k + 1) begin
            if (i_shot[k] != 0) top = i_shot[k];
        end
        if (i_spark != 0)   top = i_spark;
        if (rd_idx != 0)    top = rd_idx;     // crate redraw effect over everything in the level
        // hud
        if (bar_q2 != 0)    top = bar_q2;
        if (i_h1 != 0)      top = i_h1;
        if (i_h2 != 0)      top = i_h2;
        if (i_f1 != 0)      top = i_f1;
        if (i_z1 != 0)      top = i_z1;
        if (i_f2 != 0)      top = i_f2;
        if (i_z2 != 0)      top = i_z2;
        if (pip_d[1] == 1)  top = K;
        // crosshairs, panel, text
        if (c1_q2 != 0)     top = c1_q2;
        if (c2_q2 != 0)     top = c2_q2;
        if (pan_q2 != 0)    top = pan_q2;
        if (t_any == 1)     top = K;
    end
    wire hud = (bar_q2 != 0) | (i_h1 != 0) | (i_h2 != 0) | (i_f1 != 0) | (i_z1 != 0) | (i_f2 != 0) | (i_z2 != 0) |
               pip_d[1] | (c1_q2 != 0) | (c2_q2 != 0) | (pan_q2 != 0) | t_any;

    // register the layer, colour next clk (timing)
    // palette lookup done 1 clk later so the path is not too long (timing)
    reg [3:0] top_q = 0;
    reg sh_q = 0;
    reg st_q = 0;
    reg ws_q = 0;
    reg wb_q = 0;
    reg von_q = 0;
    reg hud_q = 0;
    always @ (posedge clk) begin
        top_q <= top;
        hud_q <= hud;
        sh_q <= sh_terrain;
        st_q <= stripe_d[1];
        ws_q <= w_surf;
        wb_q <= w_body;
        von_q <= von_d[1];
    end

    // nothing in front -> shadow, stripe or paper, then water on top of that
    reg [11:0] base;
    always @ (*) begin
        if (top_q != 4'h0)
            base = palette(top_q);
        else if (sh_q == 1)
            base = SHADOWC;
        else if (st_q == 1)
            base = STRIPE;
        else
            base = PAPER;
        // water on top of background only
        if (!hud_q && ws_q == 1)
            base = SURFACE;
        else if (!hud_q && wb_q == 1)
            base = blend(base, WATER);
    end

    // must be black outside the visible area or the monitor goes dark
    always @ (posedge clk) begin
        if (von_q == 1) begin
            rgb <= base;
        end
        else begin
            rgb <= 12'h000;
        end
    end

endmodule
