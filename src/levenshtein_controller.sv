`default_nettype none

module levenshtein_controller
    #(
        parameter MASTER_ADDR_WIDTH=24,
        parameter SLAVE_ADDR_WIDTH=24,
        parameter BITVECTOR_WIDTH=16
    )
    (
        input wire clk_i,
        input wire rst_i,

        //! @virtualbus WBM @dir out Wishbone master
        output wire wbm_cyc_o,
        output wire wbm_stb_o,
        output logic [MASTER_ADDR_WIDTH - 1 : 0] wbm_adr_o,
        output wire wbm_we_o,
        output wire [7:0] wbm_dat_o,
        input wire wbm_ack_i,
        input wire wbm_err_i,
        input wire wbm_rty_i,
        input wire [7:0] wbm_dat_i,
        //! @end

        //! @virtualbus WBS @dir in Wishbone slave
        input wire wbs_cyc_i,
        input wire wbs_stb_i,
        /* verilator lint_off UNUSEDSIGNAL */
        input wire [SLAVE_ADDR_WIDTH - 1 : 0] wbs_adr_i,
        /* verilator lint_on UNUSEDSIGNAL */
        input wire wbs_we_i,
        /* verilator lint_off UNUSEDSIGNAL */
        input wire [7:0] wbs_dat_i,
        /* verilator lint_on UNUSEDSIGNAL */
        output logic wbs_ack_o,
        output wire wbs_err_o,
        output wire wbs_rty_o,
        output logic [7:0] wbs_dat_o,
        //! @end

        output logic [1:0] sram_config
    );

    localparam DISTANCE_WIDTH = 8;
    localparam ID_WIDTH = 16;

    localparam WORD_LENGTH_REG_WIDTH = $clog2(BITVECTOR_WIDTH - 1);
    localparam WORD_LENGTH_WIDTH = $clog2(BITVECTOR_WIDTH);

    localparam ADDR_CTRL = 3'd0;
    localparam ADDR_SRAM_CTRL = 3'd1;
    localparam ADDR_LENGTH = 3'd2;
    localparam ADDR_DISTANCE = 3'd3;
    localparam ADDR_INDEX_HI = 3'd4;
    localparam ADDR_INDEX_LO = 3'd5;

    localparam WORD_TERMINATOR = 8'h00;
    localparam DICT_TERMINATOR = 8'h01;

    localparam DICT_ADDR = 'h400;

    logic enabled;
    logic [WORD_LENGTH_REG_WIDTH - 1 : 0] word_length_reg;
    wire [BITVECTOR_WIDTH - 1 : 0] mask;
    wire [BITVECTOR_WIDTH - 1 : 0] initial_vp;
    wire [WORD_LENGTH_WIDTH - 1 : 0] word_length;

    localparam STATE_READ_DICT = 2'd0;
    localparam STATE_READ_VECTOR_HI = 2'd1;
    localparam STATE_READ_VECTOR_LO = 2'd2;
    localparam STATE_LEVENSHTEIN = 2'd3;

    localparam DICT_ADDR_WIDTH = MASTER_ADDR_WIDTH;

    logic [1:0] state;
    logic [DICT_ADDR_WIDTH - 1 : 0] dict_address;
    logic cyc;
    logic [BITVECTOR_WIDTH - 1 : 0] pm;
    wire [BITVECTOR_WIDTH - 1 : 0] d0;
    wire [BITVECTOR_WIDTH - 1 : 0] hp;
    wire [BITVECTOR_WIDTH - 1 : 0] hn;
    wire [BITVECTOR_WIDTH - 1 : 0] next_vp;
    wire [BITVECTOR_WIDTH - 1 : 0] next_vn;
    logic [BITVECTOR_WIDTH - 1 : 0] vp;
    logic [BITVECTOR_WIDTH - 1 : 0] vn;
    logic [DISTANCE_WIDTH - 1 : 0] d;

    logic [ID_WIDTH - 1 : 0] idx;
    logic [ID_WIDTH - 1 : 0] best_idx;
    logic [DISTANCE_WIDTH - 1 : 0] best_distance;

    assign wbs_err_o = 1'b0;
    assign wbs_rty_o = 1'b0;
    assign wbm_cyc_o = cyc;
    assign wbm_stb_o = cyc;
    assign wbm_we_o = 1'b0;
    assign wbm_dat_o = 8'h00;
    assign word_length = WORD_LENGTH_WIDTH'(word_length_reg) + WORD_LENGTH_WIDTH'(1);

    assign d0 = (((pm & vp) + vp) ^ vp) | pm | vn;
    assign hp = vn | ~(d0 | vp);
    assign hn = d0 & vp;
    assign next_vp = (hn << 1) | ~(d0 | ((hp << 1) | BITVECTOR_WIDTH'(1)));
    assign next_vn = d0 & ((hp << 1) | BITVECTOR_WIDTH'(1));

    assign initial_vp = (1 << word_length) - 1;
    assign mask = 1 << (word_length - 1);

    always_comb begin
        if (state == STATE_READ_DICT) begin
            wbm_adr_o = dict_address;
        end else if (state == STATE_READ_VECTOR_HI) begin
            wbm_adr_o = MASTER_ADDR_WIDTH'({1'b1, pm[7:0], 1'b0});
        end else begin
            wbm_adr_o = MASTER_ADDR_WIDTH'({1'b1, pm[7:0], 1'b1});
        end
    end

    always_comb begin
        case (wbs_adr_i[2:0])
            ADDR_CTRL: wbs_dat_o = {7'b0000000, enabled};
            ADDR_SRAM_CTRL: wbs_dat_o = {6'b000000, sram_config};
            ADDR_LENGTH: wbs_dat_o = {4'b0000, word_length_reg};
            ADDR_DISTANCE: wbs_dat_o = best_distance;
            ADDR_INDEX_HI: wbs_dat_o = best_idx[15:8];
            ADDR_INDEX_LO: wbs_dat_o = best_idx[7:0];
            default: wbs_dat_o = 8'h00;
        endcase
    end

    always_ff @ (posedge clk_i) begin
        if (rst_i) begin
            enabled <= 1'b0;
            wbs_ack_o <= 1'b0;

            cyc <= 1'b0;

            dict_address <= DICT_ADDR_WIDTH'(DICT_ADDR);
            d <= DISTANCE_WIDTH'(0);
            vp <= BITVECTOR_WIDTH'(0);
            vn <= BITVECTOR_WIDTH'(0);
            state <= STATE_READ_DICT;

            idx <= ID_WIDTH'(0);
            best_idx <= ID_WIDTH'(0);
            best_distance <= DISTANCE_WIDTH'(-1);

            word_length_reg <= WORD_LENGTH_REG_WIDTH'(0);

            sram_config <= 2'd0;
        end else begin
            if (wbs_cyc_i && wbs_stb_i && !wbs_ack_o) begin
                if (wbs_we_i) begin
                    if (wbs_adr_i[2:0] == ADDR_CTRL) begin
                        enabled <= wbs_dat_i[0];
                        state <= STATE_READ_DICT;

                        dict_address <= DICT_ADDR_WIDTH'(DICT_ADDR);
                        d <= DISTANCE_WIDTH'(word_length);
                        vn <= BITVECTOR_WIDTH'(0);
                        vp <= initial_vp;

                        idx <= ID_WIDTH'(0);
                        best_idx <= ID_WIDTH'(0);
                        best_distance <= DISTANCE_WIDTH'(-1);
                    end else if (wbs_adr_i[2:0] == ADDR_SRAM_CTRL) begin
                        sram_config <= wbs_dat_i[1:0];
                    end else if (wbs_adr_i[2:0] == ADDR_LENGTH) begin
                        word_length_reg <= wbs_dat_i[WORD_LENGTH_REG_WIDTH - 1 : 0];
                    end
                end
                wbs_ack_o <= 1'b1;
            end else begin
                wbs_ack_o <= 1'b0;
            end
        
            if (enabled) begin
                case (state)
                    STATE_READ_DICT: begin
                        if (!cyc) begin
                            cyc <= 1'b1;
                        end else if (wbm_ack_i) begin
                            pm[7:0] <= wbm_dat_i;
                            if (wbm_dat_i == WORD_TERMINATOR) begin
                                if (d < best_distance) begin
                                    best_idx <= idx;
                                    best_distance <= d;
                                end
                                idx <= idx + ID_WIDTH'(1);
                                d <= DISTANCE_WIDTH'(word_length);
                                vn <= BITVECTOR_WIDTH'(0);
                                vp <= initial_vp;
                                state <= STATE_READ_DICT;
                            end else if (wbm_dat_i == DICT_TERMINATOR) begin
                                enabled <= 1'b0;
                            end else begin
                                state <= STATE_READ_VECTOR_HI;
                            end
                            cyc <= 1'b0;
                            dict_address <= dict_address + DICT_ADDR_WIDTH'(1);
                        end else if (wbm_err_i || wbm_rty_i) begin
                            cyc <= 1'b0;
                            enabled <= 1'b0;
                        end
                    end

                    STATE_READ_VECTOR_HI: begin
                        if (!cyc) begin
                            cyc <= 1'b1;
                        end else if (wbm_ack_i) begin
                            pm[15:8] <= wbm_dat_i;
                            state <= STATE_READ_VECTOR_LO;
                        end else if (wbm_err_i || wbm_rty_i) begin
                            cyc <= 1'b0;
                            enabled <= 1'b0;
                        end
                    end

                    STATE_READ_VECTOR_LO: begin
                        if (!cyc) begin
                            cyc <= 1'b1;
                        end else if (wbm_ack_i) begin
                            pm[7:0] <= wbm_dat_i;
                            cyc <= 1'b0;
                            state <= STATE_LEVENSHTEIN;
                        end else if (wbm_err_i || wbm_rty_i) begin
                            cyc <= 1'b0;
                            enabled <= 1'b0;
                        end
                    end

                    STATE_LEVENSHTEIN: begin
                        if ((hp & mask) != BITVECTOR_WIDTH'(0)) begin
                            d <= d + DISTANCE_WIDTH'(1);
                        end else if ((hn & mask) != BITVECTOR_WIDTH'(0)) begin
                            d <= d - DISTANCE_WIDTH'(1);
                        end
                        vp <= next_vp;
                        vn <= next_vn;
                        state <= STATE_READ_DICT;
                    end
                endcase
            end
        end
    end
endmodule
