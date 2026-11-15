`timescale 1ns / 1ps

module menu_screen (
    input  wire       clk,
    input  wire [9:0] x, y,
    input  wire       show,          // 1 = draw the menu
    input  wire       mode_sel,      // chosen option: 0 = 1 PLAYER, 1 = 2 PLAYERS
    input  wire       ok1, ok2,      // player 1 / player 2 boards connected
    input  wire [7:0] frame,         // frame counter, for blinking
    output reg        on = 0,
    output reg [11:0] rgb = 0
    );
    `include "sprite_data_a.vh"

    // ---------- colours ----------
    localparam [11:0] P1_BG = 12'hFBD, P1_DK = 12'hFAC,     // pink side (light / stripe)
                      P2_BG = 12'hBEB, P2_DK = 12'hADA,     // green side
                      WHITE = 12'hFFF, INK = 12'h223, SEL = 12'hFD4,
                      VS_C  = 12'hFC2, RED_C = 12'hC22, GRN_C = 12'h182,
                      PINK_T = 12'hC47, GRN_T = 12'h373;

    // ---------- helper: rectangle and its 3 px border ----------
    function in_rect; input [9:0] px, py, x0, y0, x1, y1;
        in_rect = (px >= x0) && (px <= x1) && (py >= y0) && (py <= y1);
    endfunction
    function on_edge; input [9:0] px, py, x0, y0, x1, y1;
        on_edge = in_rect(px, py, x0, y0, x1, y1) &&
                  (px < x0 + 3 || px > x1 - 3 || py < y0 + 3 || py > y1 - 3);
    endfunction

    // panels: title, name card 1, name card 2, bottom bar, and the chosen-mode box
    wire [9:0] sx0 = mode_sel ? 10'd314 : 10'd122;
    wire [9:0] sx1 = mode_sel ? 10'd480 : 10'd270;
    wire pan = in_rect(x, y, 10'd168, 10'd14, 10'd471, 10'd122) ||
               in_rect(x, y, 10'd80,  10'd318, 10'd223, 10'd395) ||
               in_rect(x, y, 10'd416, 10'd318, 10'd559, 10'd395) ||
               in_rect(x, y, 10'd104, 10'd402, 10'd535, 10'd473);
    wire edg = on_edge(x, y, 10'd168, 10'd14, 10'd471, 10'd122) ||
               on_edge(x, y, 10'd80,  10'd318, 10'd223, 10'd395) ||
               on_edge(x, y, 10'd416, 10'd318, 10'd559, 10'd395) ||
               on_edge(x, y, 10'd104, 10'd402, 10'd535, 10'd473);
    wire sbox = in_rect(x, y, sx0, 10'd406, sx1, 10'd437);
    wire vsbox = in_rect(x, y, 10'd246, 10'd182, 10'd389, 10'd293);   // dark box behind VS
    wire sedg = on_edge(x, y, sx0, 10'd406, sx1, 10'd437);

    // ---------- background: two halves, slanted band ----------
    // band centre goes from x = 352 at the top to x = 288 at the bottom
    wire [9:0]  bc  = 10'd352 - (y >> 3);
    wire [10:0] d   = {1'b0, x} - {1'b0, bc} + 11'd24;      // 0..47 inside the band
    wire in_band    = (d < 11'd48);
    wire band_edge  = in_band && (d < 11'd4 || d >= 11'd44);
    wire left       = (x < bc);
    wire [10:0] dg  = x + y;
    wire stripe     = (dg[4:3] == 2'b00);
    wire floor_ln   = (y >= 10'd304 && y < 10'd310) && !in_band;
    reg [11:0] bg1 = 0, bg2 = 0;
    always @(posedge clk) begin
        if (sedg)            bg1 <= INK;
        else if (sbox)       bg1 <= SEL;
        else if (edg)        bg1 <= INK;
        else if (pan)        bg1 <= WHITE;
        else if (vsbox)      bg1 <= INK;
        else if (band_edge)  bg1 <= INK;
        else if (in_band)    bg1 <= WHITE;
        else if (floor_ln)   bg1 <= INK;
        else if (left)       bg1 <= stripe ? P1_DK : P1_BG;
        else                 bg1 <= stripe ? P2_DK : P2_BG;
        bg2 <= bg1;
    end

    // ---------- the two fighters, 8x size (128 x 128), facing each other ----------
    wire [3:0] i_p1, i_p2r;
    sprite #(.W(SPR_PLAYER_W), .H(SPR_PLAYER_H), .SHIFT(3), .DATA(SPR_PLAYER)) u_p1
        (.clk(clk), .x(x), .y(y), .x0(10'd88),  .y0(10'd176), .flip(1'b0), .idx(i_p1),  .box());
    sprite #(.W(SPR_PLAYER_W), .H(SPR_PLAYER_H), .SHIFT(3), .DATA(SPR_PLAYER)) u_p2
        (.clk(clk), .x(x), .y(y), .x0(10'd424), .y0(10'd176), .flip(1'b1), .idx(i_p2r), .box());
    wire [3:0] i_p2 = (i_p2r == 4'hD) ? 4'h4 : (i_p2r == 4'hE) ? 4'h3 : i_p2r;   // player 2 wears green

    // ---------- text (font pixel = 2^SHIFT screen px; a character is 4 x 6 font px) ----------
    wire [13:0] c_t_title, c_t_sub, c_t_vs, c_t_n1, c_t_n2, c_t_s1, c_t_s2, c_t_m1, c_t_hint;
    // all lines share one font lookup (they never overlap): text_cell says which
    // char + where, text_glyph gives the ink, the line flags are delayed 1 clk to match
    wire t_ink;
    reg [8:0] lq = 0;
    text_cell #(.LEN(7), .SHIFT(3)) u_title (.clk(clk), .x(x), .y(y), .x0(10'd208), .y0(10'd28),
        .str("REDRAWN"), .en(1'b1), .cq(c_t_title));
    text_cell #(.LEN(5), .SHIFT(2)) u_sub (.clk(clk), .x(x), .y(y), .x0(10'd282), .y0(10'd84),
        .str("ARENA"), .en(1'b1), .cq(c_t_sub));
    // VS in yellow on a dark box (the box is drawn with the panels: cheaper than an outline)
    text_cell #(.LEN(2), .SHIFT(4)) u_vs (.clk(clk), .x(x), .y(y), .x0(10'd262), .y0(10'd198), .str("VS"), .en(1'b1), .cq(c_t_vs));
    // name cards
    text_cell #(.LEN(2), .SHIFT(3)) u_n1 (.clk(clk), .x(x), .y(y), .x0(10'd124), .y0(10'd326), .str("P1"), .en(1'b1), .cq(c_t_n1));
    text_cell #(.LEN(2), .SHIFT(3)) u_n2 (.clk(clk), .x(x), .y(y), .x0(10'd460), .y0(10'd326), .str("P2"), .en(1'b1), .cq(c_t_n2));
    text_cell #(.LEN(7), .SHIFT(2)) u_s1 (.clk(clk), .x(x), .y(y), .x0(ok1 ? 10'd114 : 10'd98),  .y0(10'd370),
        .str(ok1 ? "READY  " : "NO LINK"), .en(1'b1), .cq(c_t_s1));
    text_cell #(.LEN(7), .SHIFT(2)) u_s2 (.clk(clk), .x(x), .y(y), .x0(ok2 ? 10'd450 : 10'd434), .y0(10'd370),
        .str(ok2 ? "READY  " : "NO LINK"), .en(1'b1), .cq(c_t_s2));
    // bottom bar: the two modes and the hint
    // both modes in one line (one text unit instead of two): "2 PLAYERS" starts 12 characters (192 px) later
    text_cell #(.LEN(21), .SHIFT(2)) u_m1 (.clk(clk), .x(x), .y(y), .x0(10'd134), .y0(10'd412), .str("1 PLAYER    2 PLAYERS"), .en(1'b1), .cq(c_t_m1));
    text_cell #(.LEN(11), .SHIFT(2)) u_hint (.clk(clk), .x(x), .y(y), .x0(10'd234), .y0(10'd446),
        .str("PRESS ENTER"), .en(1'b1), .cq(c_t_hint));

    // delay show and visible to line up with the sprites/text
    text_glyph u_font (.clk(clk), .cq(c_t_title | c_t_sub | c_t_vs | c_t_n1 | c_t_n2 | c_t_s1 | c_t_s2 | c_t_m1 | c_t_hint), .on(t_ink));
    always @(posedge clk) lq <= {c_t_title[13], c_t_sub[13], c_t_vs[13], c_t_n1[13], c_t_n2[13], c_t_s1[13], c_t_s2[13], c_t_m1[13], c_t_hint[13]};
    wire t_title = t_ink && lq[8];
    wire t_sub = t_ink && lq[7];
    wire t_vs = t_ink && lq[6];
    wire t_n1 = t_ink && lq[5];
    wire t_n2 = t_ink && lq[4];
    wire t_s1 = t_ink && lq[3];
    wire t_s2 = t_ink && lq[2];
    wire t_m1 = t_ink && lq[1];
    wire t_hint = t_ink && lq[0];

    reg [1:0] show_q = 0;
    reg [1:0] vis_q = 0;
    always @(posedge clk) begin
        show_q <= {show_q[0], show};
        vis_q <= {vis_q[0], (x < 10'd640) && (y < 10'd480)};
    end
    wire blink = frame[5];          // about 1 Hz

    // ---------- mixer (later wins) ----------
    reg [11:0] c;
    always @* begin
        c = bg2;
        if (i_p1)    c = palette(i_p1);
        if (i_p2)    c = palette(i_p2);
        if (t_title) c = INK;
        if (t_sub)   c = PINK_T;
        if (t_vs)    c = VS_C;
        if (t_n1)    c = PINK_T;
        if (t_n2)    c = GRN_T;
        if (t_s1)    c = ok1 ? GRN_C : RED_C;
        if (t_s2)    c = ok2 ? GRN_C : RED_C;
        if (t_m1) c = INK;
        if (t_hint && blink) c = INK;
    end
    always @(posedge clk) begin
        on  <= show_q[1];
        rgb <= vis_q[1] ? c : 12'h000;   // black when not visible, else the monitor goes dark
    end
endmodule
