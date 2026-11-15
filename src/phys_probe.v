`timescale 1ns / 1ps

module phys_probe (
    input clk,
    input rst,
    input start,                        // pulse: start a test
    input signed [11:0] x,              // hitbox top left, keep it until done
    input signed [11:0] y,
    input [5:0] w,                      // hitbox size 1-63 px
    input [5:0] h,
    output reg signed [11:0] q_x,       // point sent to the map lookup
    output reg signed [11:0] q_y,
    input q_solid,                      // answer, 2 clk later
    output reg busy,
    output reg done,                    // 1 clk when blocked is ready
    output reg blocked                  // 1 = box hits solid ground
    );

    reg [5:0] xo;                       // offset of the point being asked
    reg [5:0] yo;
    reg iss;                            // still asking
    reg hit;                            // seen a solid point
    reg [1:0] vq;                       // questions in flight (answers 1 and 2 clk later)

    wire [5:0] wl = w - 6'd1;           // last x offset
    wire [5:0] hl = h - 6'd1;
    wire [6:0] xn = {1'b0, xo} + 7'd8;
    wire [6:0] yn = {1'b0, yo} + 7'd8;
    // next point +8 but never past the last pixel
    wire [5:0] x_next = (xn >= {1'b0, wl}) ? wl : xn[5:0];
    wire [5:0] y_next = (yn >= {1'b0, hl}) ? hl : yn[5:0];
    wire row_end = (xo == wl);
    wire col_end = (yo == hl);

    always @ (posedge clk) begin
        done <= 0;
        if (rst == 1) begin
            busy <= 0;
            iss <= 0;
            hit <= 0;
            blocked <= 0;
            vq <= 2'b00;
            xo <= 6'd0;
            yo <= 6'd0;
            q_x <= 12'sd0;
            q_y <= 12'sd0;
        end
        else if (busy == 0) begin
            if (start == 1) begin
                busy <= 1;
                iss <= 1;
                hit <= 0;
                vq <= 2'b00;
                xo <= 6'd0;
                yo <= 6'd0;
            end
        end
        else begin
            vq <= {vq[0], iss};

            // ask 1 point per clk, row by row
            if (iss == 1) begin
                q_x <= x + $signed({6'd0, xo});
                q_y <= y + $signed({6'd0, yo});
                if (row_end == 1) begin
                    xo <= 6'd0;
                    if (col_end == 1) begin
                        iss <= 0;
                    end
                    else begin
                        yo <= y_next;
                    end
                end
                else begin
                    xo <= x_next;
                end
            end

            // answer to the question 2 clk ago
            if (vq[1] == 1) begin
                hit <= hit | q_solid;
            end

            // nothing left to ask or waiting -> report
            if (!iss && !vq[0] && !vq[1]) begin
                busy <= 0;
                done <= 1;
                blocked <= hit;
            end
        end
    end

endmodule
