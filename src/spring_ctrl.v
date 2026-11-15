`timescale 1ns / 1ps

module spring_ctrl #(
    parameter STEP_FRAMES = 4,
    parameter LAUNCH_PX   = 64
    )(
    input clk,
    input [9:0] y,
    input mode_edit,
    input table_load,                   // new level loaded
    input [16*30-1:0] objs,             // object table (obj_slots.vh)
    output [5:0] frame,                 // {spring 1, spring 0} drawn frame = step
    output [19:0] spr_top,              // {spring 1, spring 0} top row on screen
    output [11:0] spr_dy,               // {spring 1, spring 0} signed, how far the top moved
    output [3:0] spr_state,             // {spring 1, spring 0} 0 EXT 1 COMPRESSING 2 COMPRESSED 3 RELEASING
    output reg launch,                  // 1 clk pulse
    output reg launch_hold,             // same, held for the frame
    output reg launch_id,               // which spring
    output [6:0] launch_px
    );
    `include "obj_slots.vh"

    localparam [1:0] EXTENDED    = 2'd0;
    localparam [1:0] COMPRESSING = 2'd1;
    localparam [1:0] COMPRESSED  = 2'd2;
    localparam [1:0] RELEASING   = 2'd3;

    assign launch_px = LAUNCH_PX;

    // 1 entry per spring
    reg [1:0] state [0:1];
    reg [2:0] step [0:1];
    reg [2:0] tmr [0:1];                // frames since last step
    reg [9:0] top_prev [0:1];           // top before the last step
    reg signed [5:0] dy [0:1];

    initial begin
        launch = 0;
        launch_hold = 0;
        launch_id = 0;
        state[0] = 0;
        state[1] = 0;
        step[0] = 0;
        step[1] = 0;
        tmr[0] = 0;
        tmr[1] = 0;
        top_prev[0] = 0;
        top_prev[1] = 0;
        dy[0] = 0;
        dy[1] = 0;
    end

    // top row of a spring at a step = sy + 16 * step
    function [9:0] topof;
        input [9:0] sy;
        input [2:0] s;
        begin
            topof = sy + {3'd0, s, 4'd0};
        end
    endfunction

    // pull each spring out of the object table (30 bits per slot:
    // bit 29 visible, 28:19 x, 18:9 y, 1:0 size)
    wire sv [0:1];
    wire [9:0] sx [0:1];
    wire [9:0] sy [0:1];
    wire [9:0] top_now [0:1];
    genvar g;
    generate
        for (g = 0; g < 2; g = g + 1) begin : g_s
            assign sv[g] = objs[(SLOT_SPRING0+g)*30 + 29];
            assign sx[g] = objs[(SLOT_SPRING0+g)*30 + 19 +: 10];
            assign sy[g] = objs[(SLOT_SPRING0+g)*30 + 9 +: 10];
            assign top_now[g] = topof(sy[g], step[g]);
            assign frame[g*3 +: 3] = step[g];
            assign spr_top[g*10 +: 10] = top_now[g];
            assign spr_dy[g*6 +: 6] = dy[g];
            assign spr_state[g*2 +: 2] = state[g];
        end
    endgenerate

    // check 10 (spring, body) pairs, 1 per clock, starting at row 480
    // pi[0] = spring, pi[3:1] = body (0 player, 1-4 crates)
    reg vb_q = 0;
    reg load_pend = 1;
    reg [3:0] pi = 0;
    reg scan = 0;
    reg upd = 0;
    reg [1:0] big = 0;                  // big body on spring k
    reg [1:0] chr = 0;                  // player on spring k
    reg [1:0] crt = 0;
    wire ks = pi[0];
    wire [2:0] oj = pi[3:1];
    // pick the body with a case, cheaper than objs[oj*30 +: 30]
    reg [29:0] oe;
    always @ (*) begin
        case (oj)
            3'd1: oe = objs[(SLOT_BOX0+0)*30 +: 30];
            3'd2: oe = objs[(SLOT_BOX0+1)*30 +: 30];
            3'd3: oe = objs[(SLOT_BOX0+2)*30 +: 30];
            3'd4: oe = objs[(SLOT_BOX0+3)*30 +: 30];
            default: oe = objs[SLOT_PLAYER*30 +: 30];
        endcase
    end
    wire [9:0] side = (oe[1:0] == 2'd1) ? 10'd8 : (oe[1:0] == 2'd2) ? 10'd32 : 10'd16;
    wire [9:0] ox = oe[28:19];
    wire [9:0] oy = oe[18:9];
    wire [9:0] bot = oy + side;         // bottom of the body
    wire [9:0] tn = ks ? top_now[1] : top_now[0];
    wire [9:0] tp = ks ? top_prev[1] : top_prev[0];
    wire [9:0] ssx = ks ? sx[1] : sx[0];
    wire ssv = ks ? sv[1] : sv[0];
    wire [9:0] t_lo = (tn < tp) ? tn : tp;
    wire [9:0] t_hi = (tn < tp) ? tp : tn;
    // middle of the body over the spring = at least half of it is over
    wire [10:0] omid = {1'b0, ox} + {2'b0, side[9:1]};
    wire contact = oe[29] && ssv && bot >= t_lo && bot <= t_hi && omid >= {1'b0, ssx} && omid <= {1'b0, ssx} + 11'd64;

    integer k;
    always @ (posedge clk) begin
        vb_q <= (y >= 10'd480);
        launch <= 0;
        if (table_load == 1) begin
            load_pend <= 1;
        end

        // start of vblank: start the scan
        if ((y >= 10'd480) && !vb_q) begin
            scan <= 1;
            pi <= 4'd0;
            big <= 2'b00;
            chr <= 2'b00;
            crt <= 2'b00;
        end
        else if (scan == 1) begin
            if (contact == 1) begin
                if (oe[1:0] == 2'd2) begin
                    big[ks] <= 1;
                end
                if (oj == 3'd0) begin
                    chr[ks] <= 1;
                end
                else begin
                    crt[ks] <= 1;
                end
            end
            if (pi == 4'd9) begin
                scan <= 0;
                upd <= 1;
            end
            pi <= pi + 4'd1;
        end

        // scan done, update both springs
        if (upd == 1) begin
            upd <= 0;
            load_pend <= 0;
            launch_hold <= 0;
            for (k = 0; k < 2; k = k + 1) begin
                dy[k] <= 6'sd0;
                if (mode_edit || load_pend || table_load || !sv[k]) begin
                    state[k] <= EXTENDED;
                    step[k] <= 3'd0;
                    tmr[k] <= 3'd0;
                    top_prev[k] <= topof(sy[k], 3'd0);
                end
                else begin
                    case (state[k])
                        EXTENDED: begin
                            if (big[k] == 1) begin
                                // first step straight away
                                state[k] <= COMPRESSING;
                                step[k] <= 3'd1;
                                tmr[k] <= 3'd0;
                                dy[k] <= 6'sd16;
                                top_prev[k] <= top_now[k];
                            end
                            else if (tmr[k] == STEP_FRAMES - 1) begin
                                top_prev[k] <= top_now[k];      // settled, close the contact window
                            end
                            else begin
                                tmr[k] <= tmr[k] + 3'd1;
                            end
                        end

                        COMPRESSED: begin
                            if (big[k] == 0) begin
                                state[k] <= RELEASING;
                                step[k] <= 3'd3;
                                tmr[k] <= 3'd0;
                                dy[k] <= -6'sd16;
                                top_prev[k] <= top_now[k];
                                if (chr[k] == 1 || crt[k] == 1) begin
                                    launch <= 1;
                                    launch_hold <= 1;
                                    launch_id <= k[0];
                                end
                            end
                            else if (tmr[k] == STEP_FRAMES - 1) begin
                                top_prev[k] <= top_now[k];
                            end
                            else begin
                                tmr[k] <= tmr[k] + 3'd1;
                            end
                        end

                        COMPRESSING: begin
                            if (big[k] == 0) begin
                                // big body left half way, go back up (no launch)
                                state[k] <= (step[k] == 3'd1) ? EXTENDED : RELEASING;
                                step[k] <= step[k] - 3'd1;
                                tmr[k] <= 3'd0;
                                dy[k] <= -6'sd16;
                                top_prev[k] <= top_now[k];
                            end
                            else if (tmr[k] == STEP_FRAMES - 1) begin
                                step[k] <= step[k] + 3'd1;
                                tmr[k] <= 3'd0;
                                dy[k] <= 6'sd16;
                                top_prev[k] <= top_now[k];
                                if (step[k] == 3'd3) begin
                                    state[k] <= COMPRESSED;
                                end
                            end
                            else begin
                                tmr[k] <= tmr[k] + 3'd1;
                            end
                        end

                        default: begin                          // RELEASING
                            if (big[k] == 1) begin
                                // big body back, squash again from here
                                state[k] <= (step[k] == 3'd3) ? COMPRESSED : COMPRESSING;
                                step[k] <= step[k] + 3'd1;
                                tmr[k] <= 3'd0;
                                dy[k] <= 6'sd16;
                                top_prev[k] <= top_now[k];
                            end
                            else if (tmr[k] == STEP_FRAMES - 1) begin
                                step[k] <= step[k] - 3'd1;
                                tmr[k] <= 3'd0;
                                dy[k] <= -6'sd16;
                                top_prev[k] <= top_now[k];
                                if (step[k] == 3'd1) begin
                                    state[k] <= EXTENDED;
                                end
                            end
                            else begin
                                tmr[k] <= tmr[k] + 3'd1;
                            end
                        end
                    endcase
                end
            end
        end
    end

endmodule
