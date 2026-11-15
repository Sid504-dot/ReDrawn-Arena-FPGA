`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/22/2026 05:22:16 PM
// Design Name: 
// Module Name: packets_rx
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


module packet_rx(
    input clk,
    input rst,
    input [7:0] data,                 // from uart_rx
    input valid,                      // 1 for one clock when data is new
    output reg [6:0] keys_rx = 0,     // keys from the keyboard board
    output reg link_ok = 0,           // 1 = good packets are arriving
    output reg pkt_good = 0,          // 1 for one clock: a packet passed its check (for the OLED debug page)
    output reg pkt_bad = 0            // 1 for one clock: a packet failed its check
    );
    
    reg [1:0] step = 0; //0 = waiting for header, 1 = waiting for keys, 2 = waiting for checksum
    reg [6:0] hold = 0; // keep the keys data until checksum arrives
    reg [23:0] counter = 0; 
    // in case the line is silent for 50ms then reset everything
    // m = 5,000,000
    
    always @ (posedge clk) begin
        pkt_good <= 0;
        pkt_bad  <= 0;
        
        if (valid == 1) begin
            // header always restarts the packet, wherever we were
            if (data == 8'hA5) begin
                step <= 1;
            end else if (step == 1) begin
                if (data[7] == 1'b0) begin
                    hold <= data[6:0];
                    step <= 2;
                end
            end else if (step == 2) begin 
                if (data[7] == 1'b0) begin
                    // check byte must be the inverse of the keys
                    if ((hold ^ data[6:0]) == 7'b1111111) begin
                        link_ok <= 1;
                        keys_rx <= hold;
                        counter <= 0;
                        pkt_good <= 1;
                    end else begin
                        pkt_bad <= 1;
                    end
                        step <= 0;
                end
            end else begin
                step <= 0;
            end
            
        // no byte this clock: count the silence
        end else if (counter < 5000000) begin
            counter = counter + 1;
        end else begin
            keys_rx <= 0;
            link_ok <= 0;
        end
        
        // reset is last so it wins over everything above
        if (rst == 1) begin
            counter <= 0;
            link_ok <= 0;
            step <= 0;
            keys_rx <= 0;
        end
    
    end
    
    
    
    
endmodule
