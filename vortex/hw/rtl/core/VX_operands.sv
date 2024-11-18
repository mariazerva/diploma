// Copyright © 2019-2023
// 
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
// 
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "VX_define.vh"

module VX_operands import VX_gpu_pkg::*; #(
    parameter CORE_ID = 0,
    parameter CACHE_ENABLE = 0
) (
    input wire              clk,
    input wire              reset,

    VX_writeback_if.slave   writeback_if [`ISSUE_WIDTH],
    VX_ibuffer_if.slave     ibuffer_if [`ISSUE_WIDTH],
    VX_operands_if.master   operands_if [`ISSUE_WIDTH]
);

    typedef struct packed {
        logic [`UUID_WIDTH-1:0]     uuid;
        logic [ISSUE_WIS_W-1:0]     wis;
        logic [`NUM_THREADS-1:0]    tmask;
        logic [`EX_BITS-1:0]        ex_type;    
        logic [`INST_OP_BITS-1:0]   op_type;
        logic [`INST_MOD_BITS-1:0]  op_mod;    
        logic                       wb;
        logic                       use_PC;
        logic                       use_imm;
        logic [`XLEN-1:0]           PC;
        logic [`XLEN-1:0]           imm;
        logic [`NR_BITS-1:0]        rd;
        logic [`NR_BITS-1:0]        rs1;
        logic [`NR_BITS-1:0]        rs2;
        logic [`NR_BITS-1:0]        rs3;
    } data_t;

    typedef struct packed {
        logic allocated;
        data_t data;
        logic rs1_ready;
        logic rs2_ready;
        logic rs3_ready;
        logic [`NUM_THREADS-1:0][`XLEN-1:0] rs1_data;
        logic [`NUM_THREADS-1:0][`XLEN-1:0] rs2_data;
        logic [`NUM_THREADS-1:0][`XLEN-1:0] rs3_data;
        logic [`CU_WIS_W-1:0] rs1_source;
        logic [`CU_WIS_W-1:0] rs2_source;
        logic [`CU_WIS_W-1:0] rs3_source;
        logic rs1_from_rf;
        logic rs2_from_rf;
        logic rs3_from_rf;
    } collector_unit_t;

    typedef struct packed {
        logic [`CU_WIS_W-1:0] cu_id;
        logic from_rf;
    } rat_data_t;

    `UNUSED_PARAM (CORE_ID)
    localparam DATAW = `UUID_WIDTH + ISSUE_WIS_W + `NUM_THREADS + `XLEN + 1 + `EX_BITS + `INST_OP_BITS + `INST_MOD_BITS + 1 + 1 + `XLEN + `NR_BITS;
    localparam RAM_ADDRW = `LOG2UP(`NUM_REGS * ISSUE_RATIO);

    for (genvar i = 0; i < `ISSUE_WIDTH; ++i) begin
        
        collector_unit_t [`CU_RATIO-1:0] collector_units;
        rat_data_t [`UP(`ISSUE_RATIO)-1:0][`NUM_REGS-1:0] reg_alias_table;

        wire [`NUM_THREADS-1:0][`XLEN-1:0] gpr_rd_data;
        reg [`NR_BITS-1:0] gpr_rd_rid, gpr_rd_rid_n;
        reg [ISSUE_WIS_W-1:0] gpr_rd_wis, gpr_rd_wis_n;

        reg [`NUM_THREADS-1:0][`XLEN-1:0] cache_data [ISSUE_RATIO-1:0];
        reg [`NUM_THREADS-1:0][`XLEN-1:0] cache_data_n [ISSUE_RATIO-1:0];
        reg [`NR_BITS-1:0] cache_reg [ISSUE_RATIO-1:0];
        reg [`NR_BITS-1:0] cache_reg_n [ISSUE_RATIO-1:0];
        reg [`NUM_THREADS-1:0] cache_tmask [ISSUE_RATIO-1:0];
        reg [`NUM_THREADS-1:0] cache_tmask_n [ISSUE_RATIO-1:0];
        reg [ISSUE_RATIO-1:0] cache_eop, cache_eop_n;
        wire [`CU_WIS_W-1:0] cu_to_allocate;
        wire [`CU_WIS_W-1:0] cu_to_read_rf_out;
        wire [`CU_RATIO-1:0] empty_cus;
        wire [`CU_RATIO-1:0] reading_cus;
        wire [`CU_RATIO-1:0] ready_cus;
        wire allocate_cu_valid, dispatch_cu_valid, read_cu_valid_out, read_cu_valid;
        reg [`CU_WIS_W-1:0] cu_to_read_rf, cu_to_read_rf_n;
        reg [`CU_WIS_W-1:0] cu_to_dispatch, cu_to_deallocate;
        wire deallocate;
        wire [`CU_WIS_W-1:0] cu_to_dispatch_n;

        wire stg_valid_in;
        wire stg_ready_in;
        reg ibuffer_ready, ibuffer_ready_n;
        reg stg_ready, stg_ready_n;
        reg [`CU_WIS_W-1:0] cu_to_check_rat, cu_to_check_rat_n;
        reg check_rat, check_rat_n;
        reg rf_ready, rf_ready_n;
        reg [`XLEN-1:0] previous_pc;
        reg [1:0] state, state_n;

        always @(*) begin
            cache_data_n = cache_data;
            cache_reg_n  = cache_reg;
            cache_tmask_n= cache_tmask;
            cache_eop_n  = cache_eop;
            gpr_rd_rid_n = gpr_rd_rid;
            gpr_rd_wis_n = gpr_rd_wis;
            stg_ready_n = stg_ready_in;

            // allocate cu, be ready to check rat and to accept new data from ibuffer
            if ((previous_pc != ibuffer_if[i].data.PC) && allocate_cu_valid && ibuffer_if[i].valid) begin
                collector_units[cu_to_allocate].allocated = 1;
                collector_units[cu_to_allocate].data = ibuffer_if[i].data;
                previous_pc = ibuffer_if[i].data.PC;

                ibuffer_ready_n = 1;
                cu_to_check_rat_n = cu_to_allocate;
                check_rat_n = 1;
            end else begin
                ibuffer_ready_n = 0;
                cu_to_check_rat_n = cu_to_check_rat;
                check_rat_n = 0;
            end
            
            for (int j = 0; j < `CU_RATIO; j++) begin

                empty_cus[j] = ~(collector_units[j].allocated);

                if (collector_units[j].allocated) begin
                    // for unused rs1, rs2, rs3 set ready to 1
                    if (collector_units[j].data.rs1 == 0) begin
                        collector_units[j].rs1_ready = 1;
                        collector_units[j].rs1_data = '0;
                        collector_units[j].rs1_from_rf = 0;
                    end
                    if (collector_units[j].data.rs2 == 0) begin
                        collector_units[j].rs2_ready = 1;
                        collector_units[j].rs2_data = '0;
                        collector_units[j].rs2_from_rf = 0;
                    end
                    if (collector_units[j].data.rs3 == 0) begin
                        collector_units[j].rs3_ready = 1;
                        collector_units[j].rs3_data = '0;
                        collector_units[j].rs3_from_rf = 0;
                    end

                    // a cu needs to check rf
                    if ((collector_units[j].rs1_from_rf && collector_units[j].rs1_ready==0) || collector_units[j].rs2_from_rf && collector_units[j].rs2_ready==0 || collector_units[j].rs3_from_rf && collector_units[j].rs3_ready==0) begin
                        reading_cus[j] = 1;
                    end else begin
                        reading_cus[j] = 0;                        
                    end

                    // a cu is ready to use operands_if to dispatch
                    if (collector_units[j].rs1_ready && collector_units[j].rs2_ready && collector_units[j].rs3_ready) begin
                        ready_cus[j] = 1;
                    end else begin
                        ready_cus[j] = 0;
                    end
                    
                end else begin
                    reading_cus[j] = 0;
                    ready_cus[j] = 0;
                end
            end

            if (stg_valid_in) begin
                operands_if[i].data.rs1_data = collector_units[cu_to_dispatch].rs1_data;
                operands_if[i].data.rs2_data = collector_units[cu_to_dispatch].rs2_data;
                operands_if[i].data.rs3_data = collector_units[cu_to_dispatch].rs3_data;
                cu_to_deallocate = cu_to_dispatch;
                deallocate = 1;
            end 

            // new cu to read rf
            if (rf_ready) begin
                cu_to_read_rf_n = cu_to_read_rf_out;
                read_cu_valid_n = read_cu_valid_out;
                gpr_rd_wis_n = collector_units[cu_to_read_rf_out].data.wis;
            end else begin
                cu_to_read_rf_n = cu_to_read_rf;
                read_cu_valid_n = read_cu_valid;
                gpr_rd_wis_n = gpr_rd_wis;
            end

            if (read_cu_valid && collector_units[cu_to_read_rf].rs1_from_rf && ~(collector_units[cu_to_read_rf].rs1_ready)) begin
                gpr_rd_rid_n = collector_units[cu_to_read_rf].data.rs1;
                state_n = 1;
                rf_ready_n = 0;
            end else if (read_cu_valid && collector_units[cu_to_read_rf].rs2_from_rf && ~(collector_units[cu_to_read_rf].rs2_ready)) begin
                gpr_rd_rid_n = collector_units[cu_to_read_rf].data.rs2;
                state_n = 2;
                rf_ready_n = 0;
            end else if (read_cu_valid && collector_units[cu_to_read_rf].rs3_from_rf && ~(collector_units[cu_to_read_rf].rs3_ready)) begin
                gpr_rd_rid_n = collector_units[cu_to_read_rf].data.rs3;
                state_n = 3;
                rf_ready_n = 0;
            end else begin
                state_n = 0;
                rf_ready_n = 1;
            end

            if (state == 1) begin
                collector_units[cu_to_read_rf].rs1_data = gpr_rd_data;
                collector_units[cu_to_read_rf].rs1_ready = 1;
            end else if (state == 2) begin
                collector_units[cu_to_read_rf].rs2_data = gpr_rd_data;
                collector_units[cu_to_read_rf].rs2_ready = 1;
            end else if (state == 3) begin
                collector_units[cu_to_read_rf].rs3_data = gpr_rd_data;
                collector_units[cu_to_read_rf].rs3_ready = 1;
            end

            if (CACHE_ENABLE != 0 && writeback_if[i].valid) begin
                if ((cache_reg[writeback_if[i].data.wis] == writeback_if[i].data.rd) 
                 || (cache_eop[writeback_if[i].data.wis] && writeback_if[i].data.sop)) begin
                    for (integer j = 0; j < `NUM_THREADS; ++j) begin
                        if (writeback_if[i].data.tmask[j]) begin
                            cache_data_n[writeback_if[i].data.wis][j] = writeback_if[i].data.data[j];
                        end
                    end
                    cache_reg_n[writeback_if[i].data.wis] = writeback_if[i].data.rd;
                    cache_eop_n[writeback_if[i].data.wis] = writeback_if[i].data.eop;
                    cache_tmask_n[writeback_if[i].data.wis] = writeback_if[i].data.sop ? writeback_if[i].data.tmask : 
                                                                    (cache_tmask_n[writeback_if[i].data.wis] | writeback_if[i].data.tmask);
                end
            end
        end

        // for selecting a cu to allocate
        VX_lzc #(
            .N       (`CU_RATIO),
            .REVERSE (1)
        ) allocate_cu_select (
            .data_in   (empty_cus),
            .data_out  (cu_to_allocate),
            .valid_out (allocate_cu_valid)
        );

        // for selecting a cu to read rf
        VX_lzc #(
            .N       (`CU_RATIO),
            .REVERSE (1)
        ) reading_cu_select (
            .data_in   (reading_cus),
            .data_out  (cu_to_read_rf_out),
            .valid_out (read_cu_valid_out)
        );

        // for selecting a cu to dispatch
        VX_lzc #(
            .N       (`CU_RATIO),
            .REVERSE (1)
        ) dispatch_cu_select (
            .data_in   (ready_cus),
            .data_out  (cu_to_dispatch_n),
            .valid_out (dispatch_cu_valid)
        );


        always @(posedge clk)  begin
            if (reset) begin 
                cache_eop   <= {ISSUE_RATIO{1'b1}};
                for (i = 0; i < `CU_RATIO; i = i + 1) begin
                    collector_units[i].allocated <= 1'b0;
                    collector_units[i].rs1_ready <= 1'b0;
                    collector_units[i].rs2_ready <= 1'b0;
                    collector_units[i].rs3_ready <= 1'b0;
                    collector_units[i].rs1_from_rf <= 1'b0;
                    collector_units[i].rs2_from_rf <= 1'b0;
                    collector_units[i].rs3_from_rf <= 1'b0;
                end
                for (i = 0; i < `UP(`ISSUE_RATIO); i = i + 1) begin
                    for (j = 0; j < `NUM_REGS; j = j + 1) begin
                        reg_alias_table[i][j].from_rf <= 1;
                    end
                end
                ibuffer_ready <= 1'b0;
                stg_ready <= 1'b0;
                check_rat <= 1'b0;
                previous_pc <= 0;
            end else begin
                cache_eop   <= cache_eop_n;
                check_rat <= check_rat_n;
                stg_ready <= stg_ready_n;
            end
            gpr_rd_rid  <= gpr_rd_rid_n;
            gpr_rd_wis  <= gpr_rd_wis_n;        
            cache_data  <= cache_data_n;
            cache_reg   <= cache_reg_n;
            cache_tmask <= cache_tmask_n;
            ibuffer_ready <= ibuffer_ready_n;
            cu_to_check_rat <= cu_to_check_rat_n;
            cu_to_read_rf <= cu_to_read_rf_n;
            cu_to_dispatch <= cu_to_dispatch_n;
            state <= state_n;
            read_cu_valid <= read_cu_valid_n;

            if (check_rat) begin  
                if (collector_units[cu_to_check_rat].data.rs1 != 0) begin
                    collector_units[cu_to_check_rat].rs1_from_rf <= reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs1].from_rf;
                    collector_units[cu_to_check_rat].rs1_source <= reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs1].cu_id;
                end
                if (collector_units[cu_to_check_rat].data.rs2 != 0) begin
                    collector_units[cu_to_check_rat].rs2_from_rf <= reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs2].from_rf;
                    collector_units[cu_to_check_rat].rs2_source <= reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs2].cu_id;
                end
                if (collector_units[cu_to_check_rat].data.rs3 != 0) begin
                    collector_units[cu_to_check_rat].rs3_from_rf <= reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs3].from_rf;
                    collector_units[cu_to_check_rat].rs3_source <= reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs3].cu_id;
                end
                reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rd].from_rf <= 0;
                reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rd].cu_id <= cu_to_check_rat;
            end

            if (deallocate) begin
                collector_units[cu_to_deallocate].allocated <= 0;
                collector_units[cu_to_deallocate].rs1_ready <= 0;
                collector_units[cu_to_deallocate].rs2_ready <= 0;
                collector_units[cu_to_deallocate].rs3_ready <= 0;
                collector_units[cu_to_deallocate].rs1_from_rf <= 0;
                collector_units[cu_to_deallocate].rs2_from_rf <= 0;
                collector_units[cu_to_deallocate].rs3_from_rf <= 0;
            end
        end       

        assign ibuffer_if[i].ready = ibuffer_ready;
        assign stg_valid_in = stg_ready && dispatch_cu_valid;

        VX_toggle_buffer #(
            .DATAW (DATAW)
        ) staging_buffer (
            .clk       (clk),
            .reset     (reset),
            .valid_in  (stg_valid_in),
            .data_in   ({
                collector_units[cu_to_dispatch].data.uuid,
                collector_units[cu_to_dispatch].data.wis,
                collector_units[cu_to_dispatch].data.tmask,
                collector_units[cu_to_dispatch].data.PC, 
                collector_units[cu_to_dispatch].data.wb,
                collector_units[cu_to_dispatch].data.ex_type,
                collector_units[cu_to_dispatch].data.op_type,
                collector_units[cu_to_dispatch].data.op_mod,
                collector_units[cu_to_dispatch].data.use_PC,
                collector_units[cu_to_dispatch].data.use_imm,
                collector_units[cu_to_dispatch].data.imm,
                collector_units[cu_to_dispatch].data.rd
            }),
            .ready_in  (stg_ready_in),
            .valid_out (operands_if[i].valid),
            .data_out  ({
                operands_if[i].data.uuid,
                operands_if[i].data.wis,
                operands_if[i].data.tmask,
                operands_if[i].data.PC, 
                operands_if[i].data.wb,
                operands_if[i].data.ex_type,
                operands_if[i].data.op_type,
                operands_if[i].data.op_mod,
                operands_if[i].data.use_PC,
                operands_if[i].data.use_imm,
                operands_if[i].data.imm,
                operands_if[i].data.rd
            }),
            .ready_out (operands_if[i].ready)
        );

        // GPR banks

        reg [RAM_ADDRW-1:0] gpr_rd_addr;       
        wire [RAM_ADDRW-1:0] gpr_wr_addr;
        if (ISSUE_WIS != 0) begin
            assign gpr_wr_addr = {writeback_if[i].data.wis, writeback_if[i].data.rd};
            always @(posedge clk) begin
                gpr_rd_addr <= {gpr_rd_wis_n, gpr_rd_rid_n};
            end
        end else begin
            assign gpr_wr_addr = writeback_if[i].data.rd;
            always @(posedge clk) begin
                gpr_rd_addr <= gpr_rd_rid_n;
            end
        end
        
    `ifdef GPR_RESET
        reg wr_enabled = 0;
        always @(posedge clk) begin
            if (reset) begin
                wr_enabled <= 1;
            end
        end
    `endif

        for (genvar j = 0; j < `NUM_THREADS; ++j) begin
            VX_dp_ram #(
                .DATAW (`XLEN),
                .SIZE (`NUM_REGS * ISSUE_RATIO),
            `ifdef GPR_RESET
                .INIT_ENABLE (1),
                .INIT_VALUE (0),
            `endif
                .NO_RWCHECK (1)
            ) gpr_ram (
                .clk   (clk),
                .read  (read_cu_valid),
                `UNUSED_PIN (wren),
            `ifdef GPR_RESET
                .write (wr_enabled && writeback_if[i].valid && writeback_if[i].data.tmask[j]),
            `else
                .write (writeback_if[i].valid && writeback_if[i].data.tmask[j]),
            `endif              
                .waddr (gpr_wr_addr),
                .wdata (writeback_if[i].data.data[j]),
                .raddr (gpr_rd_addr),
                .rdata (gpr_rd_data[j])
            );
        end
    end

endmodule
