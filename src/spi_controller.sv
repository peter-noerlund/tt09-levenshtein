`default_nettype none

module spi_controller
    (
        input wire clk_i,
        input wire rst_i,

        input wire cyc_i,
        input wire stb_i,
        input wire [23:0] adr_i,
        input wire we_i,
        input wire [7:0] dat_i,
        input wire [2:0] cti_i,
        input wire [1:0] bte_i,
        output reg ack_o,
        output wire err_o,
        output wire rty_o,
        output reg [7:0] dat_o,

        output reg sck,
        output reg mosi,
        input wire miso,
        
        output wire cs_n,
        output wire cs2_n,
        output wire cs3_n,

        input wire [1:0] sram_config
    );

    localparam CONFIG_CS = 2'd1;
    localparam CONFIG_CS2 = 2'd2;
    localparam CONFIG_CS3 = 2'd3;

    localparam CTI_INCREMENT_BURST = 3'b010;
    localparam BTE_LINEAR = 2'b00;

    reg ss_n;
    reg [5:0] bit_counter;

    assign err_o = 1'b0;
    assign rty_o = 1'b0;

    assign cs_n = sram_config == CONFIG_CS ? ss_n : 1'b1;
    assign cs2_n = sram_config == CONFIG_CS2 ? ss_n : 1'b1;
    assign cs3_n = sram_config == CONFIG_CS3 ? ss_n : 1'b1;

    always @ (posedge clk_i) begin
        if (rst_i) begin
            ack_o <= 1'b0;
            ss_n <= 1'b1;
            sck <= 1'b0;
            bit_counter <= 6'd0;
            mosi <= 1'b0;
        end else begin
            if (cyc_i && stb_i && !ack_o) begin
                if (ss_n) begin
                    ss_n <= 1'b0;
                end
                if (!ss_n) begin
                    sck <= ~sck;
                end
                if (sck) begin
                    if (bit_counter <= 6'd4) begin
                        mosi <= 1'b0;
                    end else if (bit_counter == 6'd5) begin
                        mosi <= 1'b1;
                    end else if (bit_counter == 6'd6) begin
                        mosi <= !we_i;                        
                    end else if (bit_counter >= 6'd7 && bit_counter <= 6'd30) begin
                        mosi <= adr_i[5'd23 - 5'(bit_counter - 6'd7)];
                    end else if (bit_counter >= 6'd31 && bit_counter <= 6'd38) begin
                        ack_o <= 1'b0;
                        mosi <= dat_i[3'd7 - 3'(bit_counter - 6'd31)];
                        dat_o <= {dat_o[6:0], miso};
                    end else if (bit_counter == 6'd39) begin
                        if (cti_i == CTI_INCREMENT_BURST && bte_i == BTE_LINEAR) begin
                            bit_counter <= 6'd31;
                        end else begin
                            mosi <= 1'b0;
                            ss_n <= 1'b1;
                        end
                        ack_o <= 1'b1;
                        dat_o <= {dat_o[6:0], miso};
                    end
                    bit_counter <= bit_counter + 6'd1;
                end
            end else begin
                ack_o <= 1'b0;
                ss_n <= 1'b1;
                sck <= 1'b0;
                bit_counter <= 6'd0;
            end
        end
    end
endmodule
