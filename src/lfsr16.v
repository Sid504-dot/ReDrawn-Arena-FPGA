`timescale 1ns / 1ps


module lfsr16 #(
    parameter [15:0] SEED = 16'hACE1     // not 0
    )(
    input clk,
    output reg [15:0] q = SEED
    );

    always @ (posedge clk) begin
        if (q[0] == 1) begin
            q <= {1'b0, q[15:1]} ^ 16'hB400;
        end else begin
            q <= {1'b0, q[15:1]};
        end
    end

endmodule
