`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: editor_ui
// Description: draws the redrawn buttons: level select, editor tools,
//              counters ("how many left") and the paint hover box
//              buttons are 32x32 px on a 40 px grid (x = 40*i + 4)
//                top row    y 16-47   (edit mode only, the 16 tools)
//                bottom row y 432-463 (levels in play mode, actions in edit mode)
//              icons come from icons.mem (16x16 art drawn 2x, see sprites.txt icon_*)
//              idx 0 = nothing here, 3 clk delay
//////////////////////////////////////////////////////////////////////////////////


module editor_ui(
    input clk,
    input [9:0] x_i,
    input [9:0] y_i,
    input mode_edit,
    input [3:0] level,
    input [2:0] copy_from,
    input [3:0] tool,
    input [1:0] crate_sz,               // crate size for the next placement (0 normal, 1 small, 2 big)
    input brush2,
    input rect_mode,
    input [2:0] verified,
    input [1:0] lvl_bad,                // user level has bad placements (red dot, can't be played)
    input play_block,                   // play test not possible now (button greyed)
    input sel_on,
    input sel_bnd,
    input [4:0] sel_slot,
    input [16*30-1:0] objs,
    input ghost_on,
    input [4:0] ghost_slot,
    input hov_on,
    input [9:0] hov_x0,
    input [9:0] hov_y0,
    input [9:0] hov_x1,
    input [9:0] hov_y1,
    input hov_bad,                      // hover box red (boundary can't go there)
    output reg [3:0] idx
    );

    `include "sprite_data.vh"
    `include "obj_slots.vh"
    `include "ui_layout.vh"

    reg [3:0] icons [0:8191];
    initial begin
        $readmemh("icons.mem", icons);
    end

    // 3x5 digit font, gives row r of digit d (3 bits, left px = bit 2)
    function [2:0] digit_row;
        input [3:0] d;
        input [2:0] r;
        reg [14:0] f;
        begin
            case (d)
                4'd0: f = 15'b111_101_101_101_111;
                4'd1: f = 15'b010_110_010_010_111;
                4'd2: f = 15'b111_001_111_100_111;
                4'd3: f = 15'b111_001_111_001_111;
                4'd4: f = 15'b101_101_111_001_001;
                4'd5: f = 15'b111_100_111_001_111;
                4'd6: f = 15'b111_100_111_101_111;
                4'd7: f = 15'b111_001_001_001_001;
                4'd8: f = 15'b111_101_111_101_111;
                default: f = 15'b111_101_111_001_111;    // 9
            endcase
            digit_row = f[14 - 3*r -: 3];
        end
    endfunction

    // how many of an object type are still free (n slots starting at s0)
    // the ghost's own slot counts as free, it isn't placed yet
    function [2:0] free_count;
        input [16*30-1:0] o;
        input [4:0] s0;
        input [2:0] n;
        integer k;
        reg [2:0] c;
        begin
            c = 0;
            for (k = 0; k < 4; k = k + 1) begin
                if (k < n && (!o[(s0 + k) * 30 + 29] || (ghost_on && ghost_slot == s0 + k))) begin
                    c = c + 1;
                end
            end
            free_count = c;
        end
    endfunction


    //----------------------------------------------------------------------
    // stage 0: register x / y, which button, and the counters
    // (added for timing, x stays the same for 4 clk so 1 more clk is fine)
    //----------------------------------------------------------------------
    reg [9:0] x;
    reg [9:0] y;
    reg [3:0] bi;                       // button number 0-15
    reg top;
    reg bot;
    reg f_pl;                           // player / flag / scale / tree still free
    reg f_fl;
    reg f_sc;
    reg f_tr;
    reg [2:0] f_box;                    // how many crates / doors / springs free
    reg [2:0] f_door;
    reg [2:0] f_spr;

    always @ (posedge clk) begin
        x <= x_i;
        y <= y_i;
        bi <= btn_index(x_i);           // no divider, compares with the button edges
        top <= mode_edit && (y_i >= 10'd16) && (y_i < 10'd48);
        bot <= (y_i >= 10'd432) && (y_i < 10'd464);
        f_pl <= (free_count(objs, SLOT_PLAYER, 3'd1) != 0);
        f_fl <= (free_count(objs, SLOT_FLAG, 3'd1) != 0);
        f_sc <= (free_count(objs, SLOT_SCALE, 3'd1) != 0);
        f_tr <= (free_count(objs, SLOT_TREE0, 3'd1) != 0);
        f_box <= free_count(objs, SLOT_BOX0, N_BOX[2:0]);
        f_door <= free_count(objs, SLOT_DOOR0, 3'd2);
        f_spr <= free_count(objs, SLOT_SPRING0, 3'd2);
    end


    //----------------------------------------------------------------------
    // stage 1: which icon, and where inside the button
    //----------------------------------------------------------------------
    wire [9:0] bx = x - ({bi, 5'b0} + {bi, 3'b0});     // x - 40*i, done with shifts
    wire [9:0] lx = bx - 10'd4;
    wire inx = (bx >= 10'd4) && (bx < 10'd36);
    wire [3:0] ac = lx[4:1];                            // art column 0-15
    wire [9:0] ly = y - (top ? 10'd16 : 10'd432);
    wire [3:0] ar = ly[4:1];                            // art row 0-15

    reg show;
    reg active;                         // selected (red, thicker frame)
    reg user_fill;                      // user level button (light blue)
    reg dot;                            // status dot (verified / bad)
    reg dis;                            // greyed out
    reg bad;
    reg [4:0] icon;
    reg [3:0] digit;                    // 0 = no digit
    reg [3:0] count;                    // 15 = no counter

    always @ (*) begin
        show = 0;
        active = 0;
        user_fill = 0;
        dot = 0;
        dis = 0;
        bad = 0;
        icon = ICON_BLANK;
        digit = 0;
        count = 15;

        if (top) begin
            // tools: 0 wall 1 water 2 boundary 3 eraser 4 player 5 flag 6 (empty, old big box)
            //        7 crate 8 scale 9 door 10 mirror wall 11 spring 12 tree 15 select
            //        13 / 14 unused
            // note: active = (tool == bi) is switched off here, so the picked tool
            //       is not drawn red on the top row
            show = (bi != 4'd6) && (bi != 4'd13) && (bi != 4'd14);
            icon = bi;
            // counters, greyed out when nothing is left
            case (bi)
                4'd4: dis = !f_pl;
                4'd5: dis = !f_fl;
                4'd7: count = {1'b0, f_box};    // crates left (at 0 the ghost goes red, not greyed)
                4'd8: dis = !f_sc;
                4'd9: begin
                    count = {1'b0, f_door};
                    dis = (count == 0);
                end
                4'd11: begin
                    count = {1'b0, f_spr};
                    dis = (count == 0);
                end
                4'd12: dis = !f_tr;
                default: ;
            endcase
            if (dis) begin
                active = 1'b0;
            end
        end
        else if (bot && mode_edit) begin
            // bottom row in edit mode
            case (bi)
                4'd0: begin                     // U1 button
                    show = 1;
                    user_fill = 1;
                    digit = bi + 1;
                    active = (level == N_BUILT + bi);
                    bad = lvl_bad[bi[0]];
                    dot = verified[bi[1:0]] || bad;
                end
                4'd3: begin                     // brush size
                    show = 1;
                    icon = brush2 ? ICON_BRUSH2 : ICON_BRUSH1;
                end
                4'd4: begin                     // rectangle mode
                    show = 1;
                    icon = ICON_RECT;
                    active = rect_mode;
                end
                4'd5: begin                     // crate size, crate tool only
                    if (tool == 4'd7) begin
                        show = 1;
                        icon = (crate_sz == 2'd1) ? ICON_CSZ_SMALL : (crate_sz == 2'd2) ? ICON_CSZ_BIG : ICON_CSZ_NORMAL;
                    end
                end
                4'd6: begin
                    show = 1;
                    icon = ICON_UNDO;
                end
                4'd7: begin
                    show = 1;
                    icon = ICON_CLEAR;
                end
                4'd8: begin                     // random level (dice art sits in the old copy icon)
                    show = 1;
                    icon = ICON_COPY;
                end
                4'd10: begin                    // back to levels
                    show = 1;
                    icon = ICON_EXIT;
                end
                4'd12: begin                    // door open/closed option, only when a door is selected
                    if (sel_on && sel_slot >= SLOT_DOOR0 && sel_slot < SLOT_MIR0) begin
                        show = 1;
                        icon = ICON_OPEN;
                    end
                end
                4'd14: begin
                    if (sel_on || sel_bnd) begin
                        show = 1;
                        icon = ICON_DELETE;
                    end
                end
                4'd15: begin                    // play test
                    show = 1;
                    icon = ICON_PLAY;
                    dis = play_block;
                end
                default: ;
            endcase
        end
        else if (bot) begin
            // bottom row in play mode
            case (bi)
                4'd0, 4'd1, 4'd2, 4'd3, 4'd4, 4'd5, 4'd6: begin     // levels 1-7
                    if (bi < N_PLAY) begin
                        show = 1;
                        digit = bi + 1;
                        active = (level == bi);
                    end
                end
                4'd7: begin                     // U1 (the one save slot, level 7)
                    if (EDITOR_ON) begin
                        show = 1;
                        user_fill = 1;
                        digit = 4'd1;
                        active = (level == bi);
                        bad = lvl_bad[0];
                        dot = verified[0] || bad;
                    end
                end
                4'd14: begin
                    show = 1;
                    icon = ICON_RESTART;
                end
                4'd15: begin                    // edit, only on the user level
                    if (EDITOR_ON && level >= N_BUILT) begin
                        show = 1;
                        icon = ICON_EDIT;
                    end
                end
                default: ;
            endcase
        end
    end

    // register everything for stage 2, icon rom read here too
    reg s_show;
    reg s_active;
    reg s_user;
    reg s_dot;
    reg s_in;
    reg s_hov;
    reg s_dis;
    reg s_bad;
    reg s_hbad;
    reg [3:0] s_ac;
    reg [3:0] s_ar;
    reg [3:0] s_digit;
    reg [3:0] s_count;
    reg s_dash;
    wire [12:0] iaddr = {icon, ar, ac};
    reg [3:0] ipix;
    // hover box: only its 1 px outline
    wire hov_edge = hov_on && (x >= hov_x0) && (x < hov_x1) && (y >= hov_y0) && (y < hov_y1) &&
                    (x == hov_x0 || x == hov_x1 - 1 || y == hov_y0 || y == hov_y1 - 1);

    always @ (posedge clk) begin
        ipix <= icons[iaddr];
        s_show <= show && inx;
        s_active <= active;
        s_user <= user_fill;
        s_dot <= dot;
        s_dis <= dis;
        s_bad <= bad;
        s_hbad <= hov_bad;
        s_ac <= ac;
        s_ar <= ar;
        s_digit <= digit;
        s_count <= count;
        s_hov <= hov_edge;
        s_dash <= x[1] ^ y[1];
    end


    //----------------------------------------------------------------------
    // stage 2: put the button together
    //----------------------------------------------------------------------
    // frame, thicker when selected
    wire frame_px = (s_ac == 0) || (s_ac == 15) || (s_ar == 0) || (s_ar == 15) ||
                    (s_active && ((s_ac == 1) || (s_ac == 14) || (s_ar == 1) || (s_ar == 14)));
    // level digit in the middle
    wire [2:0] drow = digit_row(s_digit, s_ar - 4'd5);
    wire digit_px = (s_digit != 0) && (s_ar >= 5) && (s_ar <= 9) && (s_ac >= 6) && (s_ac <= 8) && drow[2 - (s_ac - 4'd6)];
    // "left" counter in the top right
    wire [2:0] crow = digit_row(s_count, s_ar - 4'd1);
    wire count_px = (s_count != 15) && (s_ar >= 1) && (s_ar <= 5) && (s_ac >= 12) && (s_ac <= 14) && crow[2 - (s_ac - 4'd12)];
    // status dot in the bottom right
    wire dot_px = s_dot && (s_ar >= 11) && (s_ar <= 13) && (s_ac >= 11) && (s_ac <= 13);

    always @ (posedge clk) begin
        if (s_show) begin
            if (frame_px) begin
                idx <= s_dis ? 4'hC : s_active ? 4'h9 : 4'h1;   // grey = used up, red = selected
            end
            else if (count_px) begin
                idx <= 4'h9;                                    // red counter
            end
            else if (digit_px) begin
                idx <= 4'h1;
            end
            else if (dot_px) begin
                idx <= s_bad ? 4'h9 : 4'h3;                     // green = verified, red = bad level
            end
            else if (ipix != 4'h0) begin
                idx <= s_dis ? 4'hC : ipix;                     // used up tools drawn grey
            end
            else begin
                idx <= s_active ? 4'hF : s_user ? 4'hB : 4'h2;  // yellow / light blue / white
            end
        end
        else if (s_hov) begin
            idx <= s_dash ? 4'h2 : (s_hbad ? 4'h9 : 4'h1);      // red dashes = can't go there
        end
        else begin
            idx <= 4'h0;
        end
    end

endmodule
