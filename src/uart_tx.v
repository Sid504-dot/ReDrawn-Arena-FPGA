`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/22/2026 06:23:18 PM
// Design Name: 
// Module Name: uart_tx
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


module uart_tx(
    input clk,
    input rst,
    input start,
    input [7:0] byte_in,
    output reg tx = 1,
    output reg busy = 0
    );
    
    reg [9:0] counter_sampling = 0;   // 0 to 867
    reg [3:0] counter_data = 0;       // which data bit, 0 to 7
    reg [1:0] idle = 0;               // 0 wait, 1 start, 2 data, 3 stop
    reg [7:0] copy_data = 0;              // copy of byte_in, sent bit by bit
    // tx idles at 1 (line high = nothing being sent)

    always @ (posedge clk) begin

        if (rst == 1) begin
            idle <= 0;
            tx <= 1;
            busy <= 0;
            counter_sampling <= 0;
            counter_data <= 0;
            copy_data <= 0;
        end
        
        // new byte to send
        else if (start == 1 && idle == 0) begin
            idle <= 1;
            busy <= 1;
            copy_data <= byte_in;
        end
        
        // ---- 1: start bit (0) ----
        else if (idle == 1) begin
            tx <= 0;
            if (counter_sampling == 867) begin
                
                idle <= 2;
                counter_sampling <= 0;
            end else begin
                counter_sampling <= counter_sampling + 1;
            end
        end
        
        // ---- 2: the 8 data bits, counter_data = 8 means all sent ----
        else if (idle == 2) begin
            if (counter_data == 8) begin
                idle <= 3;
            end else begin
                if (counter_sampling == 867) begin
                    counter_sampling <= 0;
                    tx <= copy_data[counter_data];
                    counter_data <= counter_data + 1;
                end else begin
                    tx <= copy_data[counter_data];
                    counter_sampling <= counter_sampling + 1;
                end
            
            end
        end
        
        // ---- 3: stop bit (1) ----
        else if (idle == 3) begin
            tx <= 1;
            if (counter_sampling == 867) begin
                idle <= 0;
             end else begin
                counter_sampling <= counter_sampling + 1;
             end
        end
        
        // idle = 0 and nothing to send: clear everything, busy off
        else begin
            tx <= 1;
            busy <= 0;
            counter_sampling <= 0;
            counter_data <= 0;
            copy_data <= 0;
        end
        

        
    end
    
    
endmodule
