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
        logic [`NUM_THREADS-1:0][`XLEN-1:0] rd_data;
        logic [CU_WIS_W-1:0] rs1_source;
        logic [CU_WIS_W-1:0] rs2_source;
        logic [CU_WIS_W-1:0] rs3_source;
        logic rs1_from_rf;
        logic rs2_from_rf;
        logic rs3_from_rf;
        logic dispatched;
    } collector_unit_t;

    typedef struct packed {
        logic [CU_WIS_W-1:0] cu_id;
        logic from_rf;
    } rat_data_t;

    `UNUSED_PARAM (CORE_ID)
    localparam DATAW = `UUID_WIDTH + ISSUE_WIS_W + `NUM_THREADS + `XLEN + 1 + `EX_BITS + `INST_OP_BITS + `INST_MOD_BITS + 1 + 1 + `XLEN + `NR_BITS;
    localparam RAM_ADDRW = `LOG2UP(`NUM_REGS * ISSUE_RATIO);
    localparam int cu_lt_bits = (CU_RATIO > 16) ? 32 : 4;

    for (genvar i = 0; i < `ISSUE_WIDTH; ++i) begin
        
        /* verilator lint_off UNUSED */

        collector_unit_t [CU_RATIO-1:0] collector_units, collector_units_n;
        rat_data_t [`UP(ISSUE_RATIO)-1:0][`NUM_REGS-1:0] reg_alias_table, reg_alias_table_n;

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

        logic [CU_RATIO-1:0] empty_cus;
        logic [CU_WIS_W-1:0] cu_to_allocate;
        logic allocate_cu_valid;
        reg ibuffer_ready;
        logic ibuffer_ready_n;
        reg [`UUID_WIDTH-1:0] previous_uuid;
        logic [`UUID_WIDTH-1:0] previous_uuid_n;

        reg [CU_WIS_W-1:0] cu_to_check_rat;
        logic [CU_WIS_W-1:0] cu_to_check_rat_n;
        reg check_rat;
        logic check_rat_n;

        logic [CU_RATIO-1:0] reading_cus;
        reg [1:0] state;
        logic [1:0] state_n;
        reg read_cu_valid;
        logic read_cu_valid_n, read_cu_valid_out;
        reg [CU_WIS_W-1:0] cu_to_read_rf;
        logic [CU_WIS_W-1:0] cu_to_read_rf_n, cu_to_read_rf_out;

        logic [CU_RATIO-1:0] ready_cus;
        logic [CU_WIS_W-1:0] cu_to_dispatch;
        logic dispatch_cu_valid;
        logic stg_valid_in;
        logic stg_ready_in;

        logic [CU_WIS_W-1:0] cu_to_writeback;
        reg [CU_WIS_W-1:0] cu_to_broadcast;
        logic [CU_WIS_W-1:0] cu_to_broadcast_n;
        reg broadcast;
        logic broadcast_n;
        reg [CU_WIS_W-1:0] cu_to_deallocate;
        logic [CU_WIS_W-1:0] cu_to_deallocate_n;
        reg deallocate, writeback;
        logic deallocate_n;

        logic debugging_n;
        reg debugging;
        logic [CU_WIS_W-1:0] debug_cu;
        
        /* verilator lint_on UNUSED */



        always @(*) begin
            // Initialize all signals to their default values
            cache_data_n = cache_data;
            cache_reg_n = cache_reg;
            cache_tmask_n = cache_tmask;
            cache_eop_n = cache_eop;
            deallocate_n = 0;
            broadcast_n = 0;
            writeback = 0;
            cu_to_deallocate_n = 0;
            cu_to_broadcast_n = 0;
            cu_to_writeback = 0;
            debug_cu = 0;
            debugging_n = 0;
            if (reset) begin
                previous_uuid_n = -1;
                ibuffer_ready_n = 1;
                check_rat_n = 0;
                state_n = 2'b0;
                for (logic[cu_lt_bits-1:0] j = 0; j < CU_RATIO; j = j + 1) begin
                    collector_units_n[j[CU_WIS_W-1:0]].allocated = 0;
                    collector_units_n[j[CU_WIS_W-1:0]].rs1_ready = 0;
                    collector_units_n[j[CU_WIS_W-1:0]].rs2_ready = 0;
                    collector_units_n[j[CU_WIS_W-1:0]].rs3_ready = 0;
                    collector_units_n[j[CU_WIS_W-1:0]].rs1_from_rf = 0;
                    collector_units_n[j[CU_WIS_W-1:0]].rs2_from_rf = 0;
                    collector_units_n[j[CU_WIS_W-1:0]].rs3_from_rf = 0;
                    collector_units_n[j[CU_WIS_W-1:0]].dispatched = 0;
                end
                for (integer j = 0; j < `UP(ISSUE_RATIO); j = j + 1) begin
                    for (integer k = 0; k < `NUM_REGS; k = k + 1) begin
                        reg_alias_table_n[j][k].from_rf = 1;
                    end
                end
            end else begin
                previous_uuid_n = previous_uuid;
                ibuffer_ready_n = ibuffer_ready;
                check_rat_n = check_rat;
                state_n = state;
                collector_units_n = collector_units;
                reg_alias_table_n = reg_alias_table;
            end


            // allocate cu, be ready to check rat and to accept new data from ibuffer
            if ((previous_uuid != ibuffer_if[i].data.uuid) && allocate_cu_valid && ibuffer_if[i].valid) begin
                collector_units_n[cu_to_allocate].allocated = 1;
                collector_units_n[cu_to_allocate].data = ibuffer_if[i].data;
                previous_uuid_n = ibuffer_if[i].data.uuid;

                // for unused rs1, rs2, rs3
                if (ibuffer_if[i].data.rs1 == 0) begin
                    collector_units_n[cu_to_allocate].rs1_ready = 1;
                    collector_units_n[cu_to_allocate].rs1_data = '0;
                    collector_units_n[cu_to_allocate].rs1_from_rf = 0;
                end
                if (ibuffer_if[i].data.rs2 == 0) begin
                    collector_units_n[cu_to_allocate].rs2_ready = 1;
                    collector_units_n[cu_to_allocate].rs2_data = '0;
                    collector_units_n[cu_to_allocate].rs2_from_rf = 0;
                end
                if (ibuffer_if[i].data.rs3 == 0) begin
                    collector_units_n[cu_to_allocate].rs3_ready = 1;
                    collector_units_n[cu_to_allocate].rs3_data = '0;
                    collector_units_n[cu_to_allocate].rs3_from_rf = 0;
                end

                ibuffer_ready_n = 1;
                cu_to_check_rat_n = cu_to_allocate;
                check_rat_n = 1;
            end else begin
                ibuffer_ready_n = 0;
                cu_to_check_rat_n = cu_to_check_rat;
                check_rat_n = 0;
                previous_uuid_n = previous_uuid;
            end

            /* verilator lint_off UNSIGNED */
            for (integer j = 0; j < CU_RATIO; j++) begin

                empty_cus[j[CU_WIS_W-1:0]] = ~(collector_units[j[CU_WIS_W-1:0]].allocated);

                if (collector_units[j[CU_WIS_W-1:0]].allocated) begin
                    
                    // a cu needs to check rf
                    if ((collector_units[j[CU_WIS_W-1:0]].rs1_from_rf && collector_units[j[CU_WIS_W-1:0]].rs1_ready==0) || collector_units[j[CU_WIS_W-1:0]].rs2_from_rf && collector_units[j[CU_WIS_W-1:0]].rs2_ready==0 || collector_units[j[CU_WIS_W-1:0]].rs3_from_rf && collector_units[j[CU_WIS_W-1:0]].rs3_ready==0) begin
                        reading_cus[j[CU_WIS_W-1:0]] = 1;
                    end else begin
                        reading_cus[j[CU_WIS_W-1:0]] = 0;                        
                    end

                    if (broadcast) begin
                        if (collector_units[j[CU_WIS_W-1:0]].rs1_from_rf==0 && (collector_units[j[CU_WIS_W-1:0]].rs1_source == cu_to_broadcast) && collector_units[j[CU_WIS_W-1:0]].rs1_ready==0) begin
                            if (j[CU_WIS_W-1:0] != cu_to_check_rat || check_rat==0) begin
                                for (integer k = 0; k < `NUM_THREADS; k++) begin
                                    collector_units_n[j[CU_WIS_W-1:0]].rs1_data[k] = collector_units[cu_to_broadcast].rd_data[k];
                                end
                                collector_units_n[j[CU_WIS_W-1:0]].rs1_ready = 1;
                            end
                        end
                        if (collector_units[j[CU_WIS_W-1:0]].rs2_from_rf==0 && (collector_units[j[CU_WIS_W-1:0]].rs2_source == cu_to_broadcast) && collector_units[j[CU_WIS_W-1:0]].rs2_ready==0) begin
                            if (j[CU_WIS_W-1:0] != cu_to_check_rat || check_rat==0) begin
                                for (integer k = 0; k < `NUM_THREADS; k++) begin
                                    collector_units_n[j[CU_WIS_W-1:0]].rs2_data[k] = collector_units[cu_to_broadcast].rd_data[k];
                                end
                                collector_units_n[j[CU_WIS_W-1:0]].rs2_ready = 1;
                            end
                        end 
                        if (collector_units[j[CU_WIS_W-1:0]].rs3_from_rf==0 && (collector_units[j[CU_WIS_W-1:0]].rs3_source == cu_to_broadcast) && collector_units[j[CU_WIS_W-1:0]].rs3_ready==0) begin
                            if (j[CU_WIS_W-1:0] != cu_to_check_rat || check_rat==0) begin
                                for (integer k = 0; k < `NUM_THREADS; k++) begin
                                    collector_units_n[j[CU_WIS_W-1:0]].rs3_data[k] = collector_units[cu_to_broadcast].rd_data[k];
                                end
                                collector_units_n[j[CU_WIS_W-1:0]].rs3_ready = 1;
                            end
                        end
                        cu_to_deallocate_n = cu_to_broadcast;
                        deallocate_n = 1;

                    end 

                    if (collector_units[j[CU_WIS_W-1:0]].dispatched && (collector_units[j[CU_WIS_W-1:0]].data.wb == 0)) begin
                        collector_units_n[j[CU_WIS_W-1:0]].allocated = 0;
                        collector_units_n[j[CU_WIS_W-1:0]].rs1_ready = 0;
                        collector_units_n[j[CU_WIS_W-1:0]].rs2_ready = 0;
                        collector_units_n[j[CU_WIS_W-1:0]].rs3_ready = 0;
                        collector_units_n[j[CU_WIS_W-1:0]].rs1_from_rf = 0;
                        collector_units_n[j[CU_WIS_W-1:0]].rs2_from_rf = 0;
                        collector_units_n[j[CU_WIS_W-1:0]].rs3_from_rf = 0;
                        collector_units_n[j[CU_WIS_W-1:0]].dispatched = 0;
                    end

                    // a cu is ready to use operands_if to dispatch
                    if ((collector_units[j[CU_WIS_W-1:0]].dispatched == 0) && collector_units[j[CU_WIS_W-1:0]].rs1_ready && collector_units[j[CU_WIS_W-1:0]].rs2_ready && collector_units[j[CU_WIS_W-1:0]].rs3_ready) begin
                        ready_cus[j[CU_WIS_W-1:0]] = 1;
                    end else begin
                        ready_cus[j[CU_WIS_W-1:0]] = 0;
                    end
                    
                end else begin
                    reading_cus[j[CU_WIS_W-1:0]] = 0;
                    ready_cus[j[CU_WIS_W-1:0]] = 0;
                end
            end
            /* verilator lint_on UNSIGNED */


            if (stg_valid_in) begin
                for (integer k = 0; k < `NUM_THREADS; k++) begin
                    operands_if[i].data.rs1_data[k] = collector_units[cu_to_dispatch].rs1_data[k];
                    operands_if[i].data.rs2_data[k] = collector_units[cu_to_dispatch].rs2_data[k];
                    operands_if[i].data.rs3_data[k] = collector_units[cu_to_dispatch].rs3_data[k];
                    collector_units_n[cu_to_dispatch].dispatched = 1;
                end
            end else begin
                for (integer k = 0; k < `NUM_THREADS; k++) begin
                    operands_if[i].data.rs1_data[k] = operands_if[i].data.rs1_data[k];
                    operands_if[i].data.rs2_data[k] = operands_if[i].data.rs2_data[k];
                    operands_if[i].data.rs3_data[k] = operands_if[i].data.rs3_data[k];
                end
            end

//TODO : in basic cu 0 dispatches and never commits 
// also cu 3 checks rat and needs to read rs2 from cu 0 but at the same cycle catches broadcast from cu 1 
// checking rat and broadcasting at the same cycle is causing issues

            // new cu to read rf
            if (state == 0) begin
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
            end else if (read_cu_valid && collector_units[cu_to_read_rf].rs2_from_rf && ~(collector_units[cu_to_read_rf].rs2_ready)) begin
                gpr_rd_rid_n = collector_units[cu_to_read_rf].data.rs2;
                state_n = 2;
            end else if (read_cu_valid && collector_units[cu_to_read_rf].rs3_from_rf && ~(collector_units[cu_to_read_rf].rs3_ready)) begin
                gpr_rd_rid_n = collector_units[cu_to_read_rf].data.rs3;
                state_n = 3;
            end else begin
                state_n = 0;
                gpr_rd_rid_n = gpr_rd_rid;
            end

            if (state == 1) begin
                for (integer j = 0; j < `NUM_THREADS; j++) begin
                    collector_units_n[cu_to_read_rf].rs1_data[j] = gpr_rd_data[j];
                end
                collector_units_n[cu_to_read_rf].rs1_ready = 1;
            end else if (state == 2) begin
                for (integer j = 0; j < `NUM_THREADS; j++) begin
                    collector_units_n[cu_to_read_rf].rs2_data[j] = gpr_rd_data[j];
                end
                collector_units_n[cu_to_read_rf].rs2_ready = 1;
            end else if (state == 3) begin
                for (integer j = 0; j < `NUM_THREADS; j++) begin
                    collector_units_n[cu_to_read_rf].rs3_data[j] = gpr_rd_data[j];
                end
                collector_units_n[cu_to_read_rf].rs3_ready = 1;
            end


            if (writeback_if[i].valid) begin
                /* verilator lint_off UNSIGNED */
                debugging_n = 1;
                for (logic[cu_lt_bits-1:0] j = 0; j < CU_RATIO; j++) begin
                    if ((collector_units[j[CU_WIS_W-1:0]].data.PC == writeback_if[i].data.PC) && (collector_units[j[CU_WIS_W-1:0]].data.wis == writeback_if[i].data.wis)) begin
                        cu_to_writeback = j[CU_WIS_W-1:0]; 
                        cu_to_broadcast_n = j[CU_WIS_W-1:0]; 
                        broadcast_n = 1;
                        debugging_n = 0;
                        if (reg_alias_table[collector_units[j[CU_WIS_W-1:0]].data.wis][collector_units[j[CU_WIS_W-1:0]].data.rd].cu_id == j[CU_WIS_W-1:0]) begin
                            reg_alias_table_n[collector_units[j[CU_WIS_W-1:0]].data.wis][collector_units[j[CU_WIS_W-1:0]].data.rd].from_rf = 1;
                            writeback = 1;
                        end
                        for (integer k = 0; k < `NUM_THREADS; k++) begin
                            collector_units_n[j[CU_WIS_W-1:0]].rd_data[k] = writeback_if[i].data.data[k];
                        end
                    end
                end
                /* verilator lint_on UNSIGNED */
            end

            if (check_rat) begin  
                if (collector_units[cu_to_check_rat].data.rs1 != 0) begin
                    if (broadcast && collector_units[cu_to_check_rat].rs1_source == cu_to_broadcast) begin
                        collector_units_n[cu_to_check_rat].rs1_from_rf = 1;
                    end else begin
                        if (collector_units[reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs1].cu_id].data.wb!=0 && reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs1].cu_id != cu_to_check_rat) begin
                            collector_units_n[cu_to_check_rat].rs1_from_rf = reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs1].from_rf;
                            collector_units_n[cu_to_check_rat].rs1_source = reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs1].cu_id;
                        end else begin 
                            collector_units_n[cu_to_check_rat].rs1_from_rf = 1;
                        end
                    end
                end
                if (collector_units[cu_to_check_rat].data.rs2 != 0) begin
                    if (broadcast && collector_units[cu_to_check_rat].rs2_source == cu_to_broadcast) begin
                        collector_units_n[cu_to_check_rat].rs2_from_rf = 1;
                    end else begin
                        if (collector_units[reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs2].cu_id].data.wb!=0 && reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs2].cu_id != cu_to_check_rat) begin
                            collector_units_n[cu_to_check_rat].rs2_from_rf = reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs2].from_rf;
                            collector_units_n[cu_to_check_rat].rs2_source = reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs2].cu_id;
                        end else begin
                            collector_units_n[cu_to_check_rat].rs2_from_rf = 1;
                        end
                    end
                end
                if (collector_units[cu_to_check_rat].data.rs3 != 0) begin
                    if (broadcast && collector_units[cu_to_check_rat].rs3_source == cu_to_broadcast) begin
                        collector_units_n[cu_to_check_rat].rs3_from_rf = 1;
                    end else begin
                        if (collector_units[reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs3].cu_id].data.wb!=0 && reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs3].cu_id != cu_to_check_rat) begin
                            collector_units_n[cu_to_check_rat].rs3_from_rf = reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs3].from_rf;
                            collector_units_n[cu_to_check_rat].rs3_source = reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs3].cu_id;
                        end else begin
                            collector_units_n[cu_to_check_rat].rs3_from_rf = 1;
                        end
                    end
                end
                if (collector_units[cu_to_check_rat].data.wb != 0) begin
                    reg_alias_table_n[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rd].from_rf = 0;
                    reg_alias_table_n[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rd].cu_id = cu_to_check_rat;
                end
            end

            if (deallocate) begin
                collector_units_n[cu_to_deallocate].allocated = 0;
                collector_units_n[cu_to_deallocate].rs1_ready = 0;
                collector_units_n[cu_to_deallocate].rs2_ready = 0;
                collector_units_n[cu_to_deallocate].rs3_ready = 0;
                collector_units_n[cu_to_deallocate].rs1_from_rf = 0;
                collector_units_n[cu_to_deallocate].rs2_from_rf = 0;
                collector_units_n[cu_to_deallocate].rs3_from_rf = 0;
                collector_units_n[cu_to_deallocate].dispatched = 0;
                collector_units_n[cu_to_deallocate].data.wb = 0;
            end 

            if (CACHE_ENABLE != 0 && writeback_if[i].valid) begin
                if ((cache_reg[writeback_if[i].data.wis] == writeback_if[i].data.rd) 
                 || (cache_eop[writeback_if[i].data.wis] && writeback_if[i].data.sop)) begin
                    for (integer j = 0; j < `NUM_THREADS; j++) begin
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
            .N       (CU_RATIO),
            .REVERSE (1)
        ) allocate_cu_select (
            .data_in   (empty_cus),
            .data_out  (cu_to_allocate),
            .valid_out (allocate_cu_valid)
        );

        // for selecting a cu to read rf
        VX_lzc #(
            .N       (CU_RATIO),
            .REVERSE (1)
        ) reading_cu_select (
            .data_in   (reading_cus),
            .data_out  (cu_to_read_rf_out),
            .valid_out (read_cu_valid_out)
        );

        // for selecting a cu to dispatch
        VX_lzc #(
            .N       (CU_RATIO),
            .REVERSE (1)
        ) dispatch_cu_select (
            .data_in   (ready_cus),
            .data_out  (cu_to_dispatch),
            .valid_out (dispatch_cu_valid)
        );


        always @(posedge clk)  begin
            if (reset) begin 
                cache_eop   <= {ISSUE_RATIO{1'b1}};
                ibuffer_ready <= 1'b1;
                check_rat <= 1'b0;
                deallocate <= 1'b0;
                broadcast <= 1'b0;
                state <= 2'b0;
                previous_uuid <= -1;
                /* verilator lint_off UNSIGNED */
                for (logic[cu_lt_bits-1:0] k = 0; k < CU_RATIO; k = k + 1) begin
                    collector_units[k[CU_WIS_W-1:0]].allocated <= 1'b0;
                    collector_units[k[CU_WIS_W-1:0]].rs1_ready <= 1'b0;
                    collector_units[k[CU_WIS_W-1:0]].rs2_ready <= 1'b0;
                    collector_units[k[CU_WIS_W-1:0]].rs3_ready <= 1'b0;
                    collector_units[k[CU_WIS_W-1:0]].rs1_from_rf <= 1'b0;
                    collector_units[k[CU_WIS_W-1:0]].rs2_from_rf <= 1'b0;
                    collector_units[k[CU_WIS_W-1:0]].rs3_from_rf <= 1'b0;
                    collector_units[k[CU_WIS_W-1:0]].dispatched <= 1'b0;
                    collector_units[k[CU_WIS_W-1:0]].rs1_source <= 0;
                    collector_units[k[CU_WIS_W-1:0]].rs2_source <= 0;
                    collector_units[k[CU_WIS_W-1:0]].rs3_source <= 0;
                end
                /* verilator lint_on UNSIGNED */
                for (integer k = 0; k < `UP(ISSUE_RATIO); k = k + 1) begin
                    for (integer l = 0; l < `NUM_REGS; l = l + 1) begin
                        reg_alias_table[k][l].from_rf <= 1;
                    end
                end
            end else begin
                cache_eop   <= cache_eop_n;
                check_rat <= check_rat_n;
                deallocate <= deallocate_n;
                broadcast <= broadcast_n;
                state <= state_n;
                ibuffer_ready <= ibuffer_ready_n;
                previous_uuid <= previous_uuid_n;
                reg_alias_table <= reg_alias_table_n;
                debugging <= debugging_n;
            end
            gpr_rd_rid  <= gpr_rd_rid_n;
            gpr_rd_wis  <= gpr_rd_wis_n;        
            cache_data  <= cache_data_n;
            cache_reg   <= cache_reg_n;
            cache_tmask <= cache_tmask_n;
            cu_to_check_rat <= cu_to_check_rat_n;
            cu_to_read_rf <= cu_to_read_rf_n;
            cu_to_deallocate <= cu_to_deallocate_n;
            cu_to_broadcast <= cu_to_broadcast_n;
            read_cu_valid <= read_cu_valid_n;
            collector_units <= collector_units_n;
            reg_alias_table <= reg_alias_table_n;

            `ifdef DBG_TRACE_CORE_PIPELINE
            if (ibuffer_if[i].valid) begin
                $display("%d: ibuffer valid (PC=0x%h wis=%d)", $time, ibuffer_if[i].data.PC, ibuffer_if[i].data.wis);
                $display("%d: empty cus : %b\n", $time, empty_cus);
            end

            if (collector_units_n[cu_to_allocate].allocated && allocate_cu_valid) begin
                $display("%d: allocating cu %d (PC=0x%h wis=%d)", $time, cu_to_allocate, collector_units_n[cu_to_allocate].data.PC, collector_units_n[cu_to_allocate].data.wis);
                $display("%d: ibuffer ready : %b\n", $time, ibuffer_ready);
            end

            if (check_rat) begin
                $display("%d: checking RAT for cu %d (PC=0x%h wis=%d)", $time, cu_to_check_rat, collector_units_n[cu_to_check_rat].data.PC, collector_units_n[cu_to_check_rat].data.wis);
                if (collector_units_n[cu_to_check_rat].rs1_ready==0) begin
                    if (broadcast && collector_units[cu_to_check_rat].rs1_source == cu_to_broadcast) begin
                        $display("%d: rs1 to be read from rf because of broadcast", $time);
                    end else if (collector_units[reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs1].cu_id].data.wb!=0 && reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs1].cu_id != cu_to_check_rat) begin
                        if (collector_units_n[cu_to_check_rat].rs1_from_rf) begin
                            $display("%d: rs1 to be read from rf", $time);
                        end else begin
                            $display("%d: rs1 to be read from cu %d", $time, collector_units_n[cu_to_check_rat].rs1_source);
                        end
                    end else begin
                        $display("%d: rs1 to be read from rf - no writeback", $time);
                    end
                end
                if (collector_units_n[cu_to_check_rat].rs2_ready==0) begin
                    if (broadcast && collector_units[cu_to_check_rat].rs2_source == cu_to_broadcast) begin
                        $display("%d: rs2 to be read from rf because of broadcast", $time);
                    end else if (collector_units[reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs2].cu_id].data.wb!=0 && reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs2].cu_id != cu_to_check_rat) begin
                        if (collector_units_n[cu_to_check_rat].rs2_from_rf) begin
                            $display("%d: rs2 to be read from rf", $time);
                        end else begin
                            $display("%d: rs2 to be read from cu %d", $time, collector_units_n[cu_to_check_rat].rs2_source);
                        end
                    end else begin
                        $display("%d: rs2 to be read from rf - no writeback", $time);
                    end
                end
                if (collector_units_n[cu_to_check_rat].rs3_ready==0) begin
                    if (broadcast && collector_units[cu_to_check_rat].rs3_source == cu_to_broadcast) begin
                        $display("%d: rs3 to be read from rf because of broadcast", $time);
                    end else if (collector_units[reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs3].cu_id].data.wb!=0 && reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs3].cu_id != cu_to_check_rat) begin
                        if (collector_units_n[cu_to_check_rat].rs3_from_rf) begin
                            $display("%d: rs3 to be read from rf", $time);
                        end else begin
                            $display("%d: rs3 to be read from cu %d", $time, collector_units_n[cu_to_check_rat].rs3_source);
                        end
                    end else begin
                        $display("%d: rs3 to be read from rf - no writeback", $time);
                    end
                end
                if (collector_units_n[cu_to_check_rat].data.wb) begin
                    $display("%d: rat wis %d reg %d field from_rf is now : %d", $time, collector_units_n[cu_to_check_rat].data.wis, collector_units_n[cu_to_check_rat].data.rd, reg_alias_table_n[collector_units_n[cu_to_check_rat].data.wis][collector_units_n[cu_to_check_rat].data.rd].from_rf);
                end else begin
                    $display("%d: no writeback for cu %d", $time, cu_to_check_rat);
                end
                $display("%d: ibuffer ready : %b\n", $time, ibuffer_ready);
            end

            if (read_cu_valid) begin
                $display("%d: reading cus: %b", $time, reading_cus);
                if (collector_units[cu_to_read_rf].rs1_from_rf && ~(collector_units[cu_to_read_rf].rs1_ready)) begin
                    $display("%d: reading cu %d (PC=0x%h wis=%d) rs1 from RF, state = %d\n", $time, cu_to_read_rf, collector_units[cu_to_read_rf].data.PC, collector_units[cu_to_read_rf].data.wis, state_n);
                end else if (collector_units[cu_to_read_rf].rs2_from_rf && ~(collector_units[cu_to_read_rf].rs2_ready)) begin
                    $display("%d: reading cu %d (PC=0x%h wis=%d) rs2 from RF, state = %d\n", $time, cu_to_read_rf, collector_units[cu_to_read_rf].data.PC, collector_units[cu_to_read_rf].data.wis, state_n);
                end else if (collector_units[cu_to_read_rf].rs3_from_rf && ~(collector_units[cu_to_read_rf].rs3_ready)) begin
                    $display("%d: reading cu %d (PC=0x%h wis=%d) rs3 from RF, state = %d\n", $time, cu_to_read_rf, collector_units[cu_to_read_rf].data.PC, collector_units[cu_to_read_rf].data.wis, state_n);
                end
            end

            if (state==1) begin
                $display("%d: read data from RF for cu %d (PC=0x%h wis=%d) rs1 : 0x%h, cu data : 0x%h (reading register=%d, gpr_rid_in= %d, gpr_rd_addr=0x%h)\n", $time, cu_to_read_rf, collector_units[cu_to_read_rf].data.PC, collector_units_n[cu_to_read_rf].data.wis, gpr_rd_data, collector_units_n[cu_to_read_rf].rs1_data, collector_units[cu_to_read_rf].data.rs1, gpr_rd_rid, gpr_rd_addr);
            end else if (state==2) begin
                $display("%d: read data from RF for cu %d (PC=0x%h wis=%d) rs2 : 0x%h, cu data : 0x%h (reading register=%d, gpr_rid_in= %d, gpr_rd_addr=0x%h))\n", $time, cu_to_read_rf, collector_units[cu_to_read_rf].data.PC, collector_units_n[cu_to_read_rf].data.wis, gpr_rd_data, collector_units_n[cu_to_read_rf].rs2_data, collector_units[cu_to_read_rf].data.rs2, gpr_rd_rid, gpr_rd_addr);
            end else if (state==3) begin
                $display("%d: read data from RF for cu %d (PC=0x%h wis=%d) rs3 : 0x%h, cu data : 0x%h (reading register=%d, gpr_rid_in= %d, gpr_rd_addr=0x%h))\n", $time, cu_to_read_rf, collector_units[cu_to_read_rf].data.PC, collector_units_n[cu_to_read_rf].data.wis, gpr_rd_data, collector_units_n[cu_to_read_rf].rs3_data, collector_units[cu_to_read_rf].data.rs3, gpr_rd_rid, gpr_rd_addr);
            end 

            if (stg_valid_in) begin
                `TRACE(1, ("%d: dispatching cu %d (PC=0x%h wis=%d) ex=", $time, cu_to_dispatch, collector_units_n[cu_to_dispatch].data.PC, collector_units_n[cu_to_dispatch].data.wis));
                trace_ex_type(1, collector_units_n[cu_to_dispatch].data.ex_type);
                $display("");
                $display("%d: operands rs1 : 0x%h, rs2 : 0x%h, rs3 : 0x%h\n", $time, operands_if[i].data.rs1_data, operands_if[i].data.rs2_data, operands_if[i].data.rs3_data);
            end

            if (writeback_if[i].valid) begin
                $display("%d: writeback valid for cu %d (PC=0x%h wis=%d), data : 0x%h", $time, cu_to_writeback, collector_units_n[cu_to_writeback].data.PC, collector_units_n[cu_to_writeback].data.wis, writeback_if[i].data.data);
            end 

            if (broadcast) begin
                $display("%d: broadcast from cu %d (PC=0x%h wis=%d), data : 0x%h", $time, cu_to_broadcast, collector_units[cu_to_broadcast].data.PC, collector_units[cu_to_broadcast].data.wis, collector_units_n[cu_to_broadcast].rd_data);
                for (integer j = 0; j < CU_RATIO; j = j + 1) begin
                    if (collector_units[j[CU_WIS_W-1:0]].allocated) begin
                        if (collector_units[j[CU_WIS_W-1:0]].rs1_from_rf==0 && (collector_units[j[CU_WIS_W-1:0]].rs1_source == cu_to_broadcast) && collector_units[j[CU_WIS_W-1:0]].rs1_ready==0) begin
                            if (j[CU_WIS_W-1:0] != cu_to_check_rat || check_rat==0) begin
                                $display("%d: cu %d (PC=0x%h wis=%d) caught broadcast data 0x%h from cu %d", $time, j[CU_WIS_W-1:0], collector_units_n[j[CU_WIS_W-1:0]].data.PC, collector_units_n[j[CU_WIS_W-1:0]].data.wis, collector_units_n[j[CU_WIS_W-1:0]].rs1_data, cu_to_broadcast);
                            end
                        end
                        if (collector_units[j[CU_WIS_W-1:0]].rs2_from_rf==0 && (collector_units[j[CU_WIS_W-1:0]].rs2_source == cu_to_broadcast) && collector_units[j[CU_WIS_W-1:0]].rs2_ready==0) begin
                            if (j[CU_WIS_W-1:0] != cu_to_check_rat || check_rat==0) begin
                                $display("%d: cu %d (PC=0x%h wis=%d) caught broadcast data 0x%h from cu %d", $time, j[CU_WIS_W-1:0], collector_units_n[j[CU_WIS_W-1:0]].data.PC, collector_units_n[j[CU_WIS_W-1:0]].data.wis, collector_units_n[j[CU_WIS_W-1:0]].rs2_data, cu_to_broadcast);
                            end
                        end
                        if (collector_units[j[CU_WIS_W-1:0]].rs3_from_rf==0 && (collector_units[j[CU_WIS_W-1:0]].rs3_source == cu_to_broadcast) && collector_units[j[CU_WIS_W-1:0]].rs3_ready==0) begin
                            if (j[CU_WIS_W-1:0] != cu_to_check_rat || check_rat==0) begin
                                $display("%d: cu %d (PC=0x%h wis=%d) caught broadcast data 0x%h from cu %d", $time, j[CU_WIS_W-1:0], collector_units_n[j[CU_WIS_W-1:0]].data.PC, collector_units_n[j[CU_WIS_W-1:0]].data.wis, collector_units_n[j[CU_WIS_W-1:0]].rs3_data, cu_to_broadcast);
                            end
                        end
                    end 
                end
                $display("");
            end

            if (writeback) begin
                $display("%d: writeback to RF from cu %d (PC=0x%h), data : 0x%h, gpr wr addr : 0x%h", $time, cu_to_writeback, collector_units_n[cu_to_writeback].data.PC, writeback_if[i].data.data, gpr_wr_addr);
                $display("%d: rat wis %d reg %d field from_rf is now : %d\n", $time, collector_units_n[cu_to_writeback].data.wis, collector_units_n[cu_to_writeback].data.rd, reg_alias_table_n[collector_units_n[cu_to_writeback].data.wis][collector_units_n[cu_to_writeback].data.rd].from_rf);
            end

            if (debugging) begin
                $display("%d: DEBUGGING = 1\n", $time);
            end

            if (deallocate) begin
                $display("%d: deallocating cu %d (PC=0x%h)", $time, cu_to_deallocate, collector_units_n[cu_to_deallocate].data.PC);
                $display("%d: empty cus : %b\n", $time, empty_cus);
            end 

            for (integer j = 0; j < CU_RATIO; j = j + 1) begin
                if (collector_units_n[j[CU_WIS_W-1:0]].dispatched && (collector_units_n[j[CU_WIS_W-1:0]].data.wb == 0)) begin
                    $display("%d: deallocating cu %d (PC=0x%h) - no writeback", $time, j[CU_WIS_W-1:0], collector_units_n[j[CU_WIS_W-1:0]].data.PC);
                    $display("%d: empty cus : %b\n", $time, empty_cus);
                end
            end
            `endif
        end       

        assign ibuffer_if[i].ready = ibuffer_ready;
        assign stg_valid_in = stg_ready_in && dispatch_cu_valid;


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

        for (genvar j = 0; j < `NUM_THREADS; j++) begin
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
                .read  (1),
                `UNUSED_PIN (wren),
            `ifdef GPR_RESET
                .write (wr_enabled && writeback && writeback_if[i].data.tmask[j]),
            `else
                .write (writeback && writeback_if[i].data.tmask[j]),
            `endif              
                .waddr (gpr_wr_addr),
                .wdata (writeback_if[i].data.data[j]),
                .raddr (gpr_rd_addr),
                .rdata (gpr_rd_data[j])
            );
        end
    end
    

endmodule
