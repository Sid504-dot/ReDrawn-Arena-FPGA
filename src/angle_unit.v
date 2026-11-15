`timescale 1ns / 1ps

module angle_unit (
    input clk,
    // port a (redrawn)
    input a_req,
    input signed [15:0] a_vx,
    input signed [15:0] a_vy,
    input a_zero,
    input a_ovr_en,
    input [7:0] a_ovr_ang,
    output reg a_ack,
    // port b (arena)
    input b_req,
    input signed [15:0] b_vx,
    input signed [15:0] b_vy,
    output reg b_ack,
    // answer, for whichever port got the ack
    output reg [15:0] cz,
    output reg signed [15:0] s,
    output reg signed [15:0] c
    );
    `include "aim_tables.vh"            // atan_bam and sin_q14 tables

    initial begin
        a_ack = 0;
        b_ack = 0;
        cz = 0;
        s = 16'sd0;
        c = 16'sd16384;                 // cos 0 = 1
    end

    localparam U_IDLE   = 0;
    localparam U_CORDIC = 1;
    localparam U_SIN    = 2;
    localparam U_COS    = 3;
    localparam U_GAP    = 4;

    reg [2:0] st = U_IDLE;
    reg who = 0;                        // 0 port a, 1 port b
    reg signed [15:0] cx = 0;           // vector being rotated
    reg signed [15:0] cy = 0;
    reg [15:0] az = 0;                  // angle so far
    reg [3:0] ci = 0;                   // cordic step
    reg zero = 0;
    reg ovr = 0;
    reg [7:0] oang = 0;
    // 16 bit angle -> 8 bit (rounded) for the sine table
    wire [7:0] ang = ovr ? oang : az[15:8] + {7'd0, az[7]};

    always @ (posedge clk) begin
        a_ack <= 0;
        b_ack <= 0;
        case (st)
            // take a request, latch its values
            U_IDLE: begin
                if (a_req == 1 || b_req == 1) begin
                    who <= !a_req;
                    cx <= a_req ? a_vx : b_vx;
                    cy <= a_req ? a_vy : b_vy;
                    zero <= a_req && a_zero;
                    ovr <= a_req && a_ovr_en;
                    oang <= a_ovr_ang;
                    ci <= 4'd0;
                    st <= U_CORDIC;
                end
            end

            // cordic: keep rotating the vector towards the x axis by
            // smaller and smaller angles (atan(1/2^i)), add up the angles
            // only shifts and adds, no multiply
            U_CORDIC: begin
                if (ci == 0) begin
                    if (zero == 1 || (cx == 0 && cy == 0)) begin
                        az <= 16'd0;    // point right
                        st <= U_SIN;
                    end
                    else if (cx < 0) begin
                        // pointing left: flip 180 deg first, cordic only works for x > 0
                        cx <= -cx;
                        cy <= -cy;
                        az <= 16'd32768;
                        ci <= 1;
                    end
                    else begin
                        az <= 16'd0;
                        ci <= 1;
                    end
                end
                else begin
                    if (cy > 0) begin
                        cx <= cx + (cy >>> (ci - 1));
                        cy <= cy - (cx >>> (ci - 1));
                        az <= az + atan_bam(ci - 1);
                    end
                    else begin
                        cx <= cx - (cy >>> (ci - 1));
                        cy <= cy + (cx >>> (ci - 1));
                        az <= az - atan_bam(ci - 1);
                    end
                    if (ci == 4'd15) begin
                        st <= U_SIN;
                    end
                    ci <= ci + 1;
                end
            end

            // 1 sine table read twice, cos(a) = sin(a + 90 deg), 64 = 90 deg
            U_SIN: begin
                s <= sin_q14(ang);
                st <= U_COS;
            end

            U_COS: begin
                c <= sin_q14(ang + 8'd64);
                cz <= az;
                if (who == 1) begin
                    b_ack <= 1;
                end
                else begin
                    a_ack <= 1;
                end
                st <= U_GAP;
            end

            // the client drops req after ack, wait 1 clk so it isnt taken twice
            U_GAP: begin
                st <= U_IDLE;
            end

            default: begin
                st <= U_IDLE;
            end
        endcase
    end

endmodule
