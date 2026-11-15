`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/22/2026 08:02:54 PM
// Design Name: 
// Module Name: link_tx
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


module link_tx_kb(
    input clk,
    input rst,
    input [6:0] keys,
    output tx
    );

    wire       start;      // packet_tx -> uart_tx : send byte_out now (1 clock)
    wire [7:0] byte_out;   // packet_tx -> uart_tx : the byte to send
    wire       busy;       // uart_tx -> packet_tx : still sending, wait

    packet_tx_kb u_packet_tx (
        .clk      (clk),
        .rst      (rst),
        .keys     (keys),
        .busy     (busy),
        .start    (start),
        .byte_out (byte_out)
    );

    uart_tx u_uart_tx (
        .clk     (clk),
        .rst     (rst),
        .start   (start),
        .byte_in (byte_out),
        .tx      (tx),
        .busy    (busy)
    );

endmodule