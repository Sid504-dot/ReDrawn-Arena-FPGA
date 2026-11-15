`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/22/2026 06:14:06 PM
// Design Name: 
// Module Name: link_rx
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


module link_rx(
    input clk,
    input rst,
    input rx,
    output [6:0] keys_rx,
    output link_ok,
    output pkt_good,        // 1 clock per good packet
    output pkt_bad          // 1 clock per packet that failed its check
    );
    
    // Step 2: internal wires between the two modules
    wire [7:0] data;     // byte from uart_rx
    wire       valid;    // 1 for one clock when data is new

    // Step 3: uart_rx  (wire -> bytes)
    uart_rx u_uart_rx (
        .clk   (clk),
        .rst   (rst),
        .rx    (rx),
        .data  (data),
        .valid (valid)
    );

    // Step 4: packet_rx  (bytes -> checked keys)
    packet_rx u_packet_rx (
        .clk     (clk),
        .rst     (rst),
        .data    (data),
        .valid   (valid),
        .keys_rx (keys_rx),
        .link_ok (link_ok),
        .pkt_good(pkt_good),
        .pkt_bad (pkt_bad)
    );
    
    
endmodule
