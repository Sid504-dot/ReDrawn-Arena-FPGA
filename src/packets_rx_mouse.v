`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/31/2026 09:01:05 PM
// Design Name: 
// Module Name: packets_rx_mouse
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: turns bytes from uart_rx back into the 2nd mouse's 21 bits
//              {x[9:0], y[8:0], left, right}
//              a packet is 5 bytes: B6 (header), 3 data bytes of 7 bits each
//              (bits 20-14, 13-7, 6-0, div counts which one), then a check byte
//              = the 3 data bytes xor'ed together. data/check bytes have bit 7 = 0
//              so they never look like the header
//              no good packet for 50 ms -> link_ok = 0 and the data goes to 0
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module packets_rx_mouse(
    input clk,
    input rst,
    input [7:0] data,                 // from uart_rx (one byte)
    input valid,                      // 1 for one clock when data is new
    output reg [20:0] keys_rx = 0,     // mouse data from the mouse board {x, y, left, right}
    output reg link_ok = 0,           // 1 = good packets are arriving
    output reg pkt_good = 0,          // 1 for one clock: a packet passed its check (for the OLED debug page)
    output reg pkt_bad = 0            // 1 for one clock: a packet failed its check
    );
    
    reg [1:0] step = 0; //0 = waiting for header, 1 = waiting for keys, 2 = waiting for checksum
    reg [20:0] hold = 0; // keep the keys data until checksum arrives
    reg [23:0] counter = 0;
    reg [1:0] div = 0; 
    // in case the line is silent for 50ms then reset everything
    // m = 5,000,000
    
    always @ (posedge clk) begin
        pkt_good <= 0;
        pkt_bad  <= 0;
        
        if (valid == 1) begin
            if (data == 8'hB6) begin
                step <= 1;
                div <= 0;  
            end else if (step == 1) begin
                if (data[7] == 1'b0) begin
                    if (div == 0) begin
                        hold[20:14] <= data[6:0];
                        div <= div + 1;   
                    end else if (div == 1) begin
                        hold[13:7] <= data[6:0];
                        div <= div + 1;   
                    end else if (div == 2) begin
                        hold[6:0] <= data[6:0];
                        div <= div + 1;
                        step <= 2;   
                    end 
                end
            end else if (step == 2) begin 
                if (data[7] == 1'b0) begin
                    // check byte = the 3 data bytes xor'ed
                    if (({ hold[20:14] ^ hold[13:7] ^ hold[6:0]} == data[6:0]) ) begin
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
        
        if (rst == 1) begin
            counter <= 0;
            link_ok <= 0;
            step <= 0;
            keys_rx <= 0;
            div <= 0;
        end
    
    end
    
    
    
    
endmodule

