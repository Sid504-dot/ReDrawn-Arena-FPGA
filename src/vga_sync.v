`timescale 1ns / 1ps

module vga_sync (
    input clk,
    input reset,
    output hsync,
    output vsync,
    output video_on,
    output p_tick,
    output [9:0] x,
    output [9:0] y
    );

    // horizontal, in pixels
    localparam H_DISPLAY       = 640;
    localparam H_L_BORDER      = 48;
    localparam H_R_BORDER      = 16;
    localparam H_RETRACE       = 96;    // hsync pulse
    localparam H_MAX           = H_DISPLAY + H_L_BORDER + H_R_BORDER + H_RETRACE - 1;
    localparam START_H_RETRACE = H_DISPLAY + H_R_BORDER;
    localparam END_H_RETRACE   = H_DISPLAY + H_R_BORDER + H_RETRACE - 1;

    // vertical, in lines
    localparam V_DISPLAY       = 480;
    localparam V_T_BORDER      = 33;
    localparam V_B_BORDER      = 10;
    localparam V_RETRACE       = 2;     // vsync pulse
    localparam V_MAX           = V_DISPLAY + V_T_BORDER + V_B_BORDER + V_RETRACE - 1;
    localparam START_V_RETRACE = V_DISPLAY + V_B_BORDER;
    localparam END_V_RETRACE   = V_DISPLAY + V_B_BORDER + V_RETRACE - 1;

    // count 0 1 2 3, pixel_tick every 4th clk = 25MHz
    reg [1:0] pixel_reg;
    wire [1:0] pixel_next;
    wire pixel_tick;

    always @ (posedge clk, posedge reset) begin
        if (reset == 1) begin
            pixel_reg <= 0;
        end
        else begin
            pixel_reg <= pixel_next;
        end
    end

    assign pixel_next = pixel_reg + 1;
    assign pixel_tick = (pixel_reg == 0);

    reg [9:0] h_count_reg;
    reg [9:0] h_count_next;
    reg [9:0] v_count_reg;
    reg [9:0] v_count_next;
    reg vsync_reg;
    reg hsync_reg;
    wire vsync_next;
    wire hsync_next;

    // sync outputs registered so they dont glitch
    always @ (posedge clk, posedge reset) begin
        if (reset == 1) begin
            v_count_reg <= 0;
            h_count_reg <= 0;
            vsync_reg <= 1;
            hsync_reg <= 1;
        end
        else begin
            v_count_reg <= v_count_next;
            h_count_reg <= h_count_next;
            vsync_reg <= vsync_next;
            hsync_reg <= hsync_next;
        end
    end

    // x + 1 every pixel, at the end of the line x = 0 and y + 1
    always @ (*) begin
        h_count_next = h_count_reg;
        v_count_next = v_count_reg;
        if (pixel_tick == 1) begin
            if (h_count_reg == H_MAX) begin
                h_count_next = 0;
                if (v_count_reg == V_MAX) begin
                    v_count_next = 0;
                end
                else begin
                    v_count_next = v_count_reg + 1;
                end
            end
            else begin
                h_count_next = h_count_reg + 1;
            end
        end
    end

    // sync pulses are active low
    assign hsync_next = ~(h_count_reg >= START_H_RETRACE && h_count_reg <= END_H_RETRACE);
    assign vsync_next = ~(v_count_reg >= START_V_RETRACE && v_count_reg <= END_V_RETRACE);
    assign video_on = (h_count_reg < H_DISPLAY) && (v_count_reg < V_DISPLAY);

    assign hsync = hsync_reg;
    assign vsync = vsync_reg;
    assign x = h_count_reg;
    assign y = v_count_reg;
    assign p_tick = pixel_tick;

endmodule
