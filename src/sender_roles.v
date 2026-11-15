`timescale 1ns / 1ps

module sender_roles (
    input  clk,
    input  rst,
    input  [1:0] role,                  // sw15-14
    input  [15:0] sw,
    inout  kb_ps2_clk, kb_ps2_data,     // usb keyboard
    input  [11:0] xpos, ypos,           // from MouseCtl in game_top
    input  m_left, m_right,
    output tx,                          // to JA1
    output reg [31:0] seg_text,
    output reg [3:0]  seg_dots,
    output reg [15:0] led
    );
    localparam R_KB = 2'b01, R_MS = 2'b10;
    wire is_kb = (role == R_KB);
    wire is_ms = (role == R_MS);

    // keyboard sender, held in reset if not this role
    // the modules for the other roles are held in reset so they
    // do nothing and dont send anything
    wire [6:0] keys;
    keyboard_ctrl u_keyboard (.clk(clk), .rst(rst || !is_kb), .ps2_clk(kb_ps2_clk), .ps2_data(kb_ps2_data), .keys(keys));
    wire tx_kb;
    link_tx_kb u_link_kb (.clk(clk), .rst(rst || !is_kb), .keys(keys), .tx(tx_kb));

    // mouse sender
    wire fire   = sw[2] ? m_right : m_left;        // sw2 left handed
    wire freeze = sw[2] ? m_left  : m_right;
    wire tx_ms;
    link_tx_ms u_link_ms (.clk(clk), .rst(rst || !is_ms), .mouse({xpos[9:0], ypos[8:0], fire, freeze}), .tx(tx_ms));

    // idle line is 1
    // uart line sits at 1 when nothing is sent
    assign tx = is_kb ? tx_kb : is_ms ? tx_ms : 1'b1;

    // number to hex char
    function [7:0] hexch;
        input [3:0] n;
        begin
            if (n < 10) begin
                hexch = 8'h30 + n;
            end else begin
                hexch = 8'h41 + n - 10;
            end
        end
    endfunction

    // binary to decimal digits (double dabble)
    // double dabble: shift bits in one at a time, any digit >= 5 gets +3
    // first so it carries into the next digit properly after the shift
    function [11:0] to_bcd;
        input [9:0] v;
        integer i;
        reg [21:0] w;
        begin
            w = {12'd0, v};
            for (i = 0; i < 10; i = i + 1) begin
                if (w[13:10] >= 5) w[13:10] = w[13:10] + 3;
                if (w[17:14] >= 5) w[17:14] = w[17:14] + 3;
                if (w[21:18] >= 5) w[21:18] = w[21:18] + 3;
                w = w << 1;
            end
            to_bcd = w[21:10];
        end
    endfunction
    wire [11:0] bcd = to_bcd(sw[0] ? {1'b0, ypos[8:0]} : xpos[9:0]);

    // 7 seg and leds
    // 7seg letters: L/r move, J jump, r restart, P pause (esc), E enter
    always @ (*) begin
        seg_dots = 4'b0000;
        seg_text = "    ";
        led      = 16'd0;
        if (is_kb == 1) begin
            if (sw[0] == 1) begin
                seg_text = {"P", sw[13] ? "2" : "1", hexch({1'b0, keys[6:4]}), hexch(keys[3:0])};
                seg_dots = 4'b0100;
            end else begin
                seg_text[31:24] = keys[0] ? "L" : keys[1] ? "r" : "-";
                seg_text[23:16] = keys[2] ? "J" : "-";
                seg_text[15:8]  = keys[4] ? "r" : "-";
                seg_text[7:0]   = keys[5] ? "P" : keys[6] ? "E" : "-";
            end
            led = {9'd0, keys};
        end else if (is_ms == 1) begin
            if (fire == 1) begin
                seg_text = "FIrE";
            end else if (freeze == 1) begin
                seg_text = "ICE ";
            end else begin
                seg_text = {sw[0] ? "y" : " ", {4'h3, bcd[11:8]}, {4'h3, bcd[7:4]}, {4'h3, bcd[3:0]}};
            end
            led = {fire, 1'b0, freeze, 3'b0, xpos[9:0]};
        end
    end

endmodule
