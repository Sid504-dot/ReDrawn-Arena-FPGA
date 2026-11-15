`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/22/2026 01:50:24 PM
// Design Name: 
// Module Name: keyboard_ctrl
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////



module keyboard_ctrl (
    input        clk,
    input        rst,
    inout        ps2_clk,
    inout        ps2_data,
    output reg [6:0] keys
);


// ---- wires from Ps2Interface to the key tracker ----
    wire [7:0] rx_data;     // byte received from the keyboard
    wire read_data; 
    wire err;  // 1 for one clock when rx_data is new

    // ---- PS/2 receiver (receive only: never sends to the keyboard) ----
    Ps2Interface u_ps2 (
        .ps2_clk    (ps2_clk),
        .ps2_data   (ps2_data),
        .clk        (clk),
        .rst        (rst),
        .tx_data    (8'd0),     // nothing to send
        .write_data (1'b0),     // never send
        .rx_data    (rx_data),
        .read_data  (read_data),
        .busy       (),         // not needed
        .err        (err)          // not needed
    );
    
    reg got_F0 = 0;                 // last byte was F0: next code is a release
    reg got_E0 = 0;                 // last byte was E0: extended key, ignore its code
    
    always @ (posedge clk) begin
        if (rst == 1'b1 || err == 1'b1) begin 
            got_F0 <= 1'b0;
            got_E0 <= 1'b0;
            keys <= 7'b0;
        end else if (read_data == 1'b1) begin
            if (got_E0 == 1'b0) begin
            case (rx_data)
                8'hF0: got_F0 <= 1'b1;
                8'hE0: got_E0 <= 1'b1;
                // our keys: 1 if pressed, 0 if this was a release
                8'h1C: 
                    begin
                        keys[0] <= ~got_F0;
                        got_F0 <= 1'b0;
                        got_E0 <= 1'b0;
                    end
                8'h23: 
                    begin
                        keys[1] <= ~got_F0;
                        got_F0 <= 1'b0;
                        got_E0 <= 1'b0;
                    end
                8'h29: 
                    begin
                        keys[2] <= ~got_F0;
                        got_F0 <= 1'b0;
                        got_E0 <= 1'b0;
                    end    
                8'h12: 
                    begin
                        keys[3] <= ~got_F0;
                        got_F0 <= 1'b0;
                        got_E0 <= 1'b0;
                    end
                8'h2D: 
                    begin
                        keys[4] <= ~got_F0;
                        got_F0 <= 1'b0;
                        got_E0 <= 1'b0;
                    end
                8'h76: 
                    begin
                        keys[5] <= ~got_F0;
                        got_F0 <= 1'b0;
                        got_E0 <= 1'b0;
                    end
                8'h5A: 
                    begin
                        keys[6] <= ~got_F0;
                        got_F0 <= 1'b0;
                        got_E0 <= 1'b0;
                    end
                default:
                    begin
                        got_F0 <= 1'b0;
                        got_E0 <= 1'b0;
                    end
            endcase
            
            // after E0: wait for its code (or F0 + code) and throw it away
            end else begin
                if (rx_data == 8'hF0) begin 
                    got_F0 <= 1'b1;
                end else begin   
                    got_E0 <= 1'b0;
                    got_F0 <= 1'b0;
                end
            end
        end
        
    
    
    end


endmodule
