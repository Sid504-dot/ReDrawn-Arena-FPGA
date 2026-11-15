`timescale 1ns / 1ps

module uart_rx(
    input clk,
    input rst,
    input rx,
    output reg [7:0] data = 0,
    output reg valid = 0
    );

    reg [9:0] counter_sampling = 0;   // 0 to 867
    reg [2:0] counter_data = 0;       // which data bit, 0 to 7
    reg [1:0] idle = 0;               // 0 wait, 1 start, 2 data, 3 stop
    reg [7:0] shift = 0;              // collects the bits before copying to data

    // rx comes from the other board, so pass it through 2 flip-flops first
    reg [1:0] rx_sync = 2'b11;
    always @ (posedge clk) begin
        rx_sync <= {rx_sync[0], rx};
    end
    wire rx_s = rx_sync[1];

    always @ (posedge clk) begin
        valid <= 0;                   // valid is only 1 for one clock

        if (rst == 1) begin
            idle <= 0;
            counter_sampling <= 0;
            counter_data <= 0;
        end

        // ---- 0: wait for the start bit ----
        else if (idle == 0) begin
            counter_sampling <= 0;
            counter_data <= 0;
            if (rx_s == 0) begin
                idle <= 1;
            end
        end

        // ---- 1: start bit ----
        else if (idle == 1) begin
            if (counter_sampling == 867) begin
                counter_sampling <= 0;
                idle <= 2;
            end else begin
                counter_sampling <= counter_sampling + 1;
            end

            if (counter_sampling == 434 && rx_s == 1) begin
                idle <= 0;            // back to 1 already: glitch, not a start bit
            end
        end

        // ---- 2: data bits ----
        else if (idle == 2) begin
            if (counter_sampling == 434) begin
                shift <= {rx_s, shift[7:1]};   // lowest bit comes first: shift right
            end

            if (counter_sampling == 867) begin
                counter_sampling <= 0;
                if (counter_data == 7) begin
                    idle <= 3;        // all 8 bits done
                end else begin
                    counter_data <= counter_data + 1;
                end
            end else begin
                counter_sampling <= counter_sampling + 1;
            end
        end

        // ---- 3: stop bit ----
        else if (idle == 3) begin
            counter_sampling <= counter_sampling + 1;
            if (counter_sampling == 434) begin
                if (rx_s == 1) begin  // good stop bit
                    data <= shift;
                    valid <= 1;
                end                   // bad stop bit: drop the byte
                idle <= 0;            // ready for the next byte
            end
        end
    end

endmodule