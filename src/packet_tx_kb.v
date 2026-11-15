`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/22/2026 07:51:32 PM
// Design Name: 
// Module Name: packet_tx
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


module packet_tx_kb(
    input clk,
    input rst,
    input [6:0] keys,
    input busy,
    output reg start,
    output reg [7:0] byte_out
    );
    
    //m = 999999 
    // we use 10ms the interval between each byte sent as it is long enough for players ot not 
    //notice the lag
    
    reg [20:0] counter_10ms = 0;
    reg [1:0] step = 0;
    reg [1:0] which_byte = 0; //0= header, 1= data, 2= for checksum
    reg [6:0] snap = 0; // snapshot of keys taken every 10ms
    
    
    
    always @ (posedge clk) begin
        start <= 0;
        if (rst == 1) begin 
            start <= 0;
            which_byte <= 0;
            counter_10ms <= 0;
            step <= 0;
        end
        
        else if (step == 0) begin
            
            if (counter_10ms == 999999) begin
                snap <= keys;
                which_byte <= 0;
                counter_10ms <= 0;
                step <= 1;
            end else begin
                counter_10ms <= counter_10ms + 1;
            end
        end
        // pick the byte and start uart_tx
        else if (step == 1) begin
            if (which_byte == 0 ) begin 
                byte_out <= 8'hA5;
            end else if (which_byte == 1) begin
                byte_out <= {1'b0, snap};
            end else if (which_byte == 2) begin
                byte_out <= {1'b0, ~snap};
            end
            start <= 1;
            step <= 2;
        end
        // wait for uart_tx to take it
        else if (step == 2) begin
            if (busy == 1) begin
                step <= 3;
            end
        end
        // wait for it to finish, then the next byte (after the check byte: back to waiting)
        else if (step == 3) begin
            if (busy == 0) begin
                if (which_byte == 2) begin
                    step <= 0;
                end else begin
                    which_byte <= which_byte + 1;
                    step <= 1;
                end
            end
        end
     
        
        
    end
    
    
endmodule
