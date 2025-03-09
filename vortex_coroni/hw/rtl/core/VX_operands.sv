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

`ifdef PERF_ENABLE
    output reg [`PERF_CTR_BITS-1:0] perf_nocu_stalls,
    output reg [`PERF_CTR_BITS-1:0] perf_rf_reads,
    output reg [`PERF_CTR_BITS-1:0] perf_rf_writes,
    output reg [`PERF_CTR_BITS-1:0] perf_reorders,
    output reg [`PERF_CTR_BITS-1:0] perf_reorder_distances[15:1],
    output reg [`PERF_CTR_BITS-1:0] perf_cu_util,
    output reg [64-1:0] perf_cu_alloc_period,
`endif

    VX_writeback_if.slave   writeback_if [`ISSUE_WIDTH],
    VX_ibuffer_if.slave     ibuffer_if [`ISSUE_WIDTH],
    VX_operands_if.master   operands_if [`ISSUE_WIDTH]

);

    typedef struct packed {
        logic [`UUID_WIDTH-1:0]     uuid;
        logic [ISSUE_WIS_W-1:0]     wis;
        logic [`NUM_THREADS-1:0]    tmask;
        logic [`PC_BITS-1:0]        PC;
        logic [`EX_BITS-1:0]        ex_type;
        logic [`INST_OP_BITS-1:0]   op_type;
        op_args_t                   op_args;
        logic                       wb;
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
        logic rd_valid;
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
    localparam DATAW = `UUID_WIDTH + ISSUE_WIS_W + `NUM_THREADS + `PC_BITS + 1 + `EX_BITS + `INST_OP_BITS + `INST_ARGS_BITS + `NR_BITS;
    localparam RAM_ADDRW = `LOG2UP(`NUM_REGS * ISSUE_RATIO);

    for (genvar i = 0; i < `ISSUE_WIDTH; ++i) begin
        
        /* verilator lint_off UNUSED */
        collector_unit_t [CU_RATIO-1:0] collector_units, collector_units_n;
        rat_data_t [`UP(ISSUE_RATIO)-1:0][`NUM_REGS-1:0] reg_alias_table, reg_alias_table_n;

        wire [`NUM_THREADS-1:0][`XLEN-1:0] gpr_rd_data;
        reg [`NR_BITS-1:0] gpr_rd_rid;
        logic [`NR_BITS-1:0] gpr_rd_rid_n;
        reg [ISSUE_WIS_W-1:0] gpr_rd_wis;
        logic [ISSUE_WIS_W-1:0] gpr_rd_wis_n;
        reg [`NUM_THREADS-1:0] gpr_wr_tmask;
        logic [`NUM_THREADS-1:0] gpr_wr_tmask_n;

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
        reg [ISSUE_WIS_W-1:0] previous_wis;
        logic [`UUID_WIDTH-1:0] previous_uuid_n;
        logic [ISSUE_WIS_W-1:0] previous_wis_n;

        reg [CU_WIS_W-1:0] cu_to_check_rat;
        logic [CU_WIS_W-1:0] cu_to_check_rat_n;
        reg check_rat;
        logic check_rat_n;
        wire [ISSUE_WIS_W-1:0] check_rat_wis;
        wire [`NR_BITS-1:0] check_rat_rs1, check_rat_rs2, check_rat_rs3;
        wire [`NR_BITS-1:0] check_rat_rd;

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

        reg [CU_WIS_W-1:0] cu_to_check_writeback;
        reg [CU_WIS_W-1:0] cu_to_deallocate;
        reg [CU_WIS_W-1:0] cu_to_dealloc_wb;
        logic [CU_WIS_W-1:0] cu_to_check_writeback_n;
        logic [CU_WIS_W-1:0] cu_to_deallocate_n;
        logic [CU_WIS_W-1:0] cu_to_dealloc_wb_n;
        reg deallocate;
        reg dealloc_wb;
        logic writeback;
        logic deallocate_n;
        logic dealloc_wb_n;
        reg [`NUM_THREADS-1:0][`XLEN-1:0] writeback_buffer;
        logic [`NUM_THREADS-1:0][`XLEN-1:0] writeback_buffer_n;

        reg uuid_overflow;
        logic uuid_overflow_n;
        /* verilator lint_on UNUSED */
        `ifdef PERF_ENABLE
            logic nocu_stall;
            logic rf_read;
            logic rf_write;
            logic reorder;
            logic [3:0] reorder_distance;
            logic [CU_WIS_W-1:0] cu_util;
            reg [CU_RATIO-1:0][64-1:0] cu_alloc_time;
            logic [CU_RATIO-1:0][64-1:0] cu_alloc_time_n;
            reg [CU_RATIO-1:0][64-1:0] cu_alloc_period;
            logic [CU_RATIO-1:0][64-1:0] cu_alloc_period_n;
        `endif


        assign check_rat_wis = collector_units[cu_to_check_rat].data.wis;
        assign check_rat_rs1 = collector_units[cu_to_check_rat].data.rs1;
        assign check_rat_rs2 = collector_units[cu_to_check_rat].data.rs2;
        assign check_rat_rs3 = collector_units[cu_to_check_rat].data.rs3;
        assign check_rat_rd = collector_units[cu_to_check_rat].data.rd;


        always @(*) begin

            // default values
            cache_data_n = cache_data;
            cache_reg_n = cache_reg;
            cache_tmask_n = cache_tmask;
            cache_eop_n = cache_eop;
            deallocate_n = 0;
            dealloc_wb_n = 0;
            writeback = 0;
            cu_to_check_writeback_n = cu_to_check_writeback;
            cu_to_deallocate_n = 0;
            cu_to_dealloc_wb_n = 0;
            cu_to_read_rf_n = cu_to_read_rf;
            read_cu_valid_n = read_cu_valid;
            gpr_rd_wis_n = gpr_rd_wis;
            gpr_rd_rid_n = gpr_rd_rid;
            reg_alias_table_n = reg_alias_table;
            collector_units_n = collector_units;
            check_rat_n = check_rat;
            state_n = state;
            previous_uuid_n = previous_uuid;
            previous_wis_n = previous_wis;
            ibuffer_ready_n = ibuffer_ready;
            writeback_buffer_n = writeback_buffer;
            gpr_wr_tmask_n = gpr_wr_tmask;
            uuid_overflow_n = uuid_overflow;
            `ifdef PERF_ENABLE
                cu_alloc_time_n = cu_alloc_time;
                cu_alloc_period_n = cu_alloc_period;
            `endif

            // allocate cu, be ready to check rat and to accept new data from ibuffer
            if (!uuid_overflow && ((previous_wis != ibuffer_if[i].data.wis) || (previous_uuid != ibuffer_if[i].data.uuid)) && allocate_cu_valid && ibuffer_if[i].valid) begin
                collector_units_n[cu_to_allocate].allocated = 1;
                collector_units_n[cu_to_allocate].data = ibuffer_if[i].data;
                previous_uuid_n = ibuffer_if[i].data.uuid;
                previous_wis_n = ibuffer_if[i].data.wis;
                `ifdef PERF_ENABLE
                    cu_alloc_time_n[cu_to_allocate] = $time;
                `endif

                // for unused rs1, rs2, rs3
                if (ibuffer_if[i].data.rs1 == 0) begin
                    collector_units_n[cu_to_allocate].rs1_ready = 1;
                    collector_units_n[cu_to_allocate].rs1_data = '0;
                end
                if (ibuffer_if[i].data.rs2 == 0) begin
                    collector_units_n[cu_to_allocate].rs2_ready = 1;
                    collector_units_n[cu_to_allocate].rs2_data = '0;
                end
                if (ibuffer_if[i].data.rs3 == 0) begin
                    collector_units_n[cu_to_allocate].rs3_ready = 1;
                    collector_units_n[cu_to_allocate].rs3_data = '0;
                end

                ibuffer_ready_n = 1;
                cu_to_check_rat_n = cu_to_allocate;
                check_rat_n = 1;
            end else begin
                ibuffer_ready_n = 0;
                cu_to_check_rat_n = cu_to_check_rat;
                check_rat_n = 0;
                previous_uuid_n = previous_uuid;
                previous_wis_n = previous_wis;
            end


            // empty cus
            for (integer j = 0; j < CU_RATIO; j++) begin
                empty_cus[j[CU_WIS_W-1:0]] = ~(collector_units[j[CU_WIS_W-1:0]].allocated);
            end

            // a cu is ready to read rf
            for (integer j = 0; j < CU_RATIO; j++) begin
                if (collector_units[j[CU_WIS_W-1:0]].allocated && (collector_units[j[CU_WIS_W-1:0]].rs1_from_rf && collector_units[j[CU_WIS_W-1:0]].rs1_ready==0) || 
                    collector_units[j[CU_WIS_W-1:0]].rs2_from_rf && collector_units[j[CU_WIS_W-1:0]].rs2_ready==0 || collector_units[j[CU_WIS_W-1:0]].rs3_from_rf && collector_units[j[CU_WIS_W-1:0]].rs3_ready==0) begin
                    reading_cus[j[CU_WIS_W-1:0]] = 1;
                end else begin
                    reading_cus[j[CU_WIS_W-1:0]] = 0;                        
                end
            end
           
            // broadcast: get rd_data from rs_source
            for (integer j = 0; j < CU_RATIO; j++) begin
                if (collector_units[j[CU_WIS_W-1:0]].allocated && collector_units[j[CU_WIS_W-1:0]].dispatched == 0 && (j[CU_WIS_W-1:0] != cu_to_check_rat || check_rat==0)) begin
                    if (collector_units[j[CU_WIS_W-1:0]].rs1_from_rf==0 && collector_units[collector_units[j[CU_WIS_W-1:0]].rs1_source].rd_valid && collector_units[j[CU_WIS_W-1:0]].rs1_ready==0) begin
                        // catch rs1 data
                        collector_units_n[j[CU_WIS_W-1:0]].rs1_data = writeback_buffer;
                        collector_units_n[j[CU_WIS_W-1:0]].rs1_ready = 1;
                    end
                    if (collector_units[j[CU_WIS_W-1:0]].rs2_from_rf==0 && collector_units[collector_units[j[CU_WIS_W-1:0]].rs2_source].rd_valid && collector_units[j[CU_WIS_W-1:0]].rs2_ready==0) begin
                        // catch rs2 data
                        collector_units_n[j[CU_WIS_W-1:0]].rs2_data = writeback_buffer;
                        collector_units_n[j[CU_WIS_W-1:0]].rs2_ready = 1;
                    end
                    if (collector_units[j[CU_WIS_W-1:0]].rs3_from_rf==0 && collector_units[collector_units[j[CU_WIS_W-1:0]].rs3_source].rd_valid && collector_units[j[CU_WIS_W-1:0]].rs3_ready==0) begin
                        // catch rs3 data
                        collector_units_n[j[CU_WIS_W-1:0]].rs3_data = writeback_buffer;
                        collector_units_n[j[CU_WIS_W-1:0]].rs3_ready = 1;
                    end
                end       
            end

            // writeback to cu
            if (writeback_if[i].valid) begin
                for (integer k = 0; k < `NUM_THREADS; k++) begin
                    if (writeback_if[i].data.tmask[k]) begin
                        // writeback data to cu
                        collector_units_n[writeback_if[i].data.cu_id].rd_data[k] = writeback_if[i].data.data[k];
                    end
                end
                if (writeback_if[i].data.eop) begin
                    // i have completed my writeback, i have valid data
                    collector_units_n[writeback_if[i].data.cu_id].rd_valid = 1;
                    cu_to_check_writeback_n = writeback_if[i].data.cu_id;
                    for (integer k = 0; k < `NUM_THREADS; k++) begin
                        if (writeback_if[i].data.tmask[k]) begin
                            writeback_buffer_n[k] = writeback_if[i].data.data[k];
                        end else if (collector_units[writeback_if[i].data.cu_id].data.tmask[k]) begin
                            writeback_buffer_n[k] = collector_units[writeback_if[i].data.cu_id].rd_data[k];
                        end
                    end
                    gpr_wr_tmask_n = collector_units[writeback_if[i].data.cu_id].data.tmask;
                end
            end

            // wait for cus to catch my data (only 1 cycle!) and then deallocate
            if (collector_units[cu_to_check_writeback].rd_valid) begin
                if (reg_alias_table[collector_units[cu_to_check_writeback].data.wis][collector_units[cu_to_check_writeback].data.rd].from_rf == 0 &&
                    reg_alias_table[collector_units[cu_to_check_writeback].data.wis][collector_units[cu_to_check_writeback].data.rd].cu_id == cu_to_check_writeback) begin
                    writeback = 1;
                    reg_alias_table_n[collector_units[cu_to_check_writeback].data.wis][collector_units[cu_to_check_writeback].data.rd].from_rf = 1;
                end
                cu_to_deallocate_n = cu_to_check_writeback;
                deallocate_n = 1;
                collector_units_n[cu_to_check_writeback].rd_valid = 0;
            end


            for (integer j = 0; j < CU_RATIO; j++) begin
                if (collector_units[j[CU_WIS_W-1:0]].allocated && (collector_units[j[CU_WIS_W-1:0]].dispatched == 0) && collector_units[j[CU_WIS_W-1:0]].rs1_ready && collector_units[j[CU_WIS_W-1:0]].rs2_ready && collector_units[j[CU_WIS_W-1:0]].rs3_ready) begin
                    // all rs are ready, cu can dispatch
                    ready_cus[j[CU_WIS_W-1:0]] = 1;

                    // no reordering for LSU instructions
                    for (integer k = 0; k < CU_RATIO; k++) begin
                        if (collector_units[k[CU_WIS_W-1:0]].dispatched==0 && collector_units[k[CU_WIS_W-1:0]].allocated && collector_units[k[CU_WIS_W-1:0]].data.wis == collector_units[j[CU_WIS_W-1:0]].data.wis && 
                            collector_units[k[CU_WIS_W-1:0]].data.ex_type == `EX_LSU && collector_units[j[CU_WIS_W-1:0]].data.ex_type == `EX_LSU) begin
                            if (((collector_units[k[CU_WIS_W-1:0]].data.uuid < collector_units[j[CU_WIS_W-1:0]].data.uuid) && (collector_units[k[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]!=2'b00 || collector_units[j[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]!=2'b11)) ||
                            (collector_units[k[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b11 && collector_units[j[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b00)) begin
                                ready_cus[j[CU_WIS_W-1:0]] = 0;
                            end //else begin
                                //ready_cus[k[CU_WIS_W-1:0]] = 0;
                            //end
                        end
                    end
                    // don't let an instruction with rd=x dispatch if a previous instruction is waiting to read x from RF
                    for (integer k = 0; k < j; k++) begin
                        if (collector_units[j[CU_WIS_W-1:0]].data.wis == collector_units[k[CU_WIS_W-1:0]].data.wis && 
                        ((collector_units[j[CU_WIS_W-1:0]].data.rd == collector_units[k[CU_WIS_W-1:0]].data.rs1 && collector_units[k[CU_WIS_W-1:0]].rs1_from_rf==1 && collector_units[k[CU_WIS_W-1:0]].rs1_ready==0) ||
                        (collector_units[j[CU_WIS_W-1:0]].data.rd == collector_units[k[CU_WIS_W-1:0]].data.rs2 && collector_units[k[CU_WIS_W-1:0]].rs2_from_rf==1 && collector_units[k[CU_WIS_W-1:0]].rs2_ready==0) ||
                        (collector_units[j[CU_WIS_W-1:0]].data.rd == collector_units[k[CU_WIS_W-1:0]].data.rs3 && collector_units[k[CU_WIS_W-1:0]].rs3_from_rf==1 && collector_units[k[CU_WIS_W-1:0]].rs3_ready==0)) &&
                        (((collector_units[k[CU_WIS_W-1:0]].data.uuid < collector_units[j[CU_WIS_W-1:0]].data.uuid) && (collector_units[k[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]!=2'b00 || collector_units[j[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]!=2'b11)) ||
                        (collector_units[k[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b11 && collector_units[j[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b00))) begin
                            ready_cus[j[CU_WIS_W-1:0]] = 0;
                        end
                    end
                    for (integer k = j + 1; k < CU_RATIO; k++) begin
                        if (collector_units[j[CU_WIS_W-1:0]].data.wis == collector_units[k[CU_WIS_W-1:0]].data.wis && 
                        ((collector_units[j[CU_WIS_W-1:0]].data.rd == collector_units[k[CU_WIS_W-1:0]].data.rs1 && collector_units[k[CU_WIS_W-1:0]].rs1_from_rf==1 && collector_units[k[CU_WIS_W-1:0]].rs1_ready==0) ||
                        (collector_units[j[CU_WIS_W-1:0]].data.rd == collector_units[k[CU_WIS_W-1:0]].data.rs2 && collector_units[k[CU_WIS_W-1:0]].rs2_from_rf==1 && collector_units[k[CU_WIS_W-1:0]].rs2_ready==0) ||
                        (collector_units[j[CU_WIS_W-1:0]].data.rd == collector_units[k[CU_WIS_W-1:0]].data.rs3 && collector_units[k[CU_WIS_W-1:0]].rs3_from_rf==1 && collector_units[k[CU_WIS_W-1:0]].rs3_ready==0)) &&
                        (((collector_units[k[CU_WIS_W-1:0]].data.uuid < collector_units[j[CU_WIS_W-1:0]].data.uuid) && (collector_units[k[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]!=2'b00 || collector_units[j[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]!=2'b11)) ||
                        (collector_units[k[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b11 && collector_units[j[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b00))) begin
                            ready_cus[j[CU_WIS_W-1:0]] = 0;
                        end
                    end
                end else begin
                    ready_cus[j[CU_WIS_W-1:0]] = 0;
                end
            end


            if (stg_valid_in) begin
                // dispatching a cu
                operands_if[i].data.rs1_data = collector_units[cu_to_dispatch].rs1_data;
                operands_if[i].data.rs2_data = collector_units[cu_to_dispatch].rs2_data;
                operands_if[i].data.rs3_data = collector_units[cu_to_dispatch].rs3_data;
                operands_if[i].data.cu_id = cu_to_dispatch;
                if (collector_units[cu_to_dispatch].data.wb == 0) begin
                    // deallocate a non-wb dispatching cu
                    cu_to_dealloc_wb_n = cu_to_dispatch;
                    dealloc_wb_n = 1;
                end
                collector_units_n[cu_to_dispatch].dispatched = 1;
            end else begin
                operands_if[i].data.rs1_data = operands_if[i].data.rs1_data;
                operands_if[i].data.rs2_data = operands_if[i].data.rs2_data;
                operands_if[i].data.rs3_data = operands_if[i].data.rs3_data;
                operands_if[i].data.cu_id = operands_if[i].data.cu_id;
            end

            // read rf
            if (read_cu_valid && state==0) begin
                if (collector_units[cu_to_read_rf].rs1_from_rf && ~(collector_units[cu_to_read_rf].rs1_ready)) begin
                    gpr_rd_rid_n = collector_units[cu_to_read_rf].data.rs1;
                    state_n = 1;
                end else if (collector_units[cu_to_read_rf].rs2_from_rf && ~(collector_units[cu_to_read_rf].rs2_ready)) begin
                    gpr_rd_rid_n = collector_units[cu_to_read_rf].data.rs2;
                    state_n = 2;
                end else if (collector_units[cu_to_read_rf].rs3_from_rf && ~(collector_units[cu_to_read_rf].rs3_ready)) begin
                    gpr_rd_rid_n = collector_units[cu_to_read_rf].data.rs3;
                    state_n = 3;
                end else begin
                    state_n = 0;
                    gpr_rd_rid_n = gpr_rd_rid;
                    gpr_rd_wis_n = collector_units[cu_to_read_rf_out].data.wis;
                end
            end else if (state==1) begin
                if (collector_units[cu_to_read_rf].rs2_from_rf && ~(collector_units[cu_to_read_rf].rs2_ready)) begin
                    gpr_rd_rid_n = collector_units[cu_to_read_rf].data.rs2;
                    state_n = 2;
                end else if (collector_units[cu_to_read_rf].rs3_from_rf && ~(collector_units[cu_to_read_rf].rs3_ready)) begin
                    gpr_rd_rid_n = collector_units[cu_to_read_rf].data.rs3;
                    state_n = 3;
                end else begin
                    state_n = 0;
                    gpr_rd_rid_n = gpr_rd_rid;
                    gpr_rd_wis_n = collector_units[cu_to_read_rf_out].data.wis;
                end
            end else if (state==2) begin
                if (collector_units[cu_to_read_rf].rs3_from_rf && ~(collector_units[cu_to_read_rf].rs3_ready)) begin
                    gpr_rd_rid_n = collector_units[cu_to_read_rf].data.rs3;
                    state_n = 3;
                end else begin
                    state_n = 0;
                    gpr_rd_rid_n = gpr_rd_rid;
                    gpr_rd_wis_n = collector_units[cu_to_read_rf_out].data.wis;
                end
            end else begin
                state_n = 0;
                gpr_rd_rid_n = gpr_rd_rid;
                gpr_rd_wis_n = collector_units[cu_to_read_rf_out].data.wis;
            end

            if (state == 1) begin
                // read rs1 now and be rs1_ready on the next cycle
                for (integer j = 0; j < `NUM_THREADS; j++) begin
                    collector_units_n[cu_to_read_rf].rs1_data[j] = gpr_rd_data[j];
                end
                collector_units_n[cu_to_read_rf].rs1_ready = 1;
            end else if (state == 2) begin
                // read rs2 now and be rs2_ready on the next cycle
                for (integer j = 0; j < `NUM_THREADS; j++) begin
                    collector_units_n[cu_to_read_rf].rs2_data[j] = gpr_rd_data[j];
                end
                collector_units_n[cu_to_read_rf].rs2_ready = 1;
            end else if (state == 3) begin
                // read rs3 now and be rs3_ready on the next cycle
                for (integer j = 0; j < `NUM_THREADS; j++) begin
                    collector_units_n[cu_to_read_rf].rs3_data[j] = gpr_rd_data[j];
                end
                collector_units_n[cu_to_read_rf].rs3_ready = 1;
            end


            // check rat
            if (check_rat) begin  
                if (check_rat_rs1 != 0) begin
                    // do i have to catch broadcasted data now?
                    if (reg_alias_table[check_rat_wis][check_rat_rs1].from_rf==0 && 
                    (collector_units[reg_alias_table[check_rat_wis][check_rat_rs1].cu_id].rd_valid)) begin
                        // catch valid data from rs1 source
                        collector_units_n[cu_to_check_rat].rs1_data = writeback_buffer;

                        collector_units_n[cu_to_check_rat].rs1_ready = 1;
                        collector_units_n[cu_to_check_rat].rs1_from_rf = 0;
                    end else begin
                        // not catching data from a cu now
                        collector_units_n[cu_to_check_rat].rs1_from_rf = reg_alias_table[check_rat_wis][check_rat_rs1].from_rf;
                    end
                    collector_units_n[cu_to_check_rat].rs1_source = reg_alias_table[check_rat_wis][check_rat_rs1].cu_id;                   
                end
                if (check_rat_rs2 != 0) begin
                    // same as rs1
                    if (reg_alias_table[check_rat_wis][check_rat_rs2].from_rf==0 && 
                    (collector_units[reg_alias_table[check_rat_wis][check_rat_rs2].cu_id].rd_valid)) begin
                        collector_units_n[cu_to_check_rat].rs2_data = writeback_buffer;

                        collector_units_n[cu_to_check_rat].rs2_ready = 1;
                        collector_units_n[cu_to_check_rat].rs2_from_rf = 0;
                    end else begin
                        collector_units_n[cu_to_check_rat].rs2_from_rf = reg_alias_table[check_rat_wis][check_rat_rs2].from_rf;
                    end
                    collector_units_n[cu_to_check_rat].rs2_source = reg_alias_table[check_rat_wis][check_rat_rs2].cu_id;
                end
                if (check_rat_rs3 != 0) begin
                    // same as rs1
                    if (reg_alias_table[check_rat_wis][check_rat_rs3].from_rf==0 && 
                    (collector_units[reg_alias_table[check_rat_wis][check_rat_rs3].cu_id].rd_valid)) begin
                        collector_units_n[cu_to_check_rat].rs3_data = writeback_buffer;

                        collector_units_n[cu_to_check_rat].rs3_ready = 1;
                        collector_units_n[cu_to_check_rat].rs3_from_rf = 0;
                    end else begin
                        collector_units_n[cu_to_check_rat].rs3_from_rf = reg_alias_table[check_rat_wis][check_rat_rs3].from_rf;
                    end
                    collector_units_n[cu_to_check_rat].rs3_source = reg_alias_table[check_rat_wis][check_rat_rs3].cu_id;
                end
                if (collector_units[cu_to_check_rat].data.wb) begin
                    // if a cu has to writeback, write its id to rd in rat
                    reg_alias_table_n[check_rat_wis][check_rat_rd].from_rf = 1'b0;
                    reg_alias_table_n[check_rat_wis][check_rat_rd].cu_id = cu_to_check_rat;
                end
            end


            if (deallocate) begin
                // deallocating cu after writeback
                collector_units_n[cu_to_deallocate].allocated = 0;
                collector_units_n[cu_to_deallocate].rs1_ready = 0;
                collector_units_n[cu_to_deallocate].rs2_ready = 0;
                collector_units_n[cu_to_deallocate].rs3_ready = 0;
                collector_units_n[cu_to_deallocate].rs1_from_rf = 0;
                collector_units_n[cu_to_deallocate].rs2_from_rf = 0;
                collector_units_n[cu_to_deallocate].rs3_from_rf = 0;
                collector_units_n[cu_to_deallocate].dispatched = 0;
                collector_units_n[cu_to_deallocate].data.wb = 0;
                collector_units_n[cu_to_deallocate].rd_valid = 0;
                `ifdef PERF_ENABLE
                    cu_alloc_period_n[cu_to_deallocate] = $time - cu_alloc_time[cu_to_deallocate];
                `endif
            end 

            if (dealloc_wb) begin
                // deallocating dispatched cu with no writeback
                collector_units_n[cu_to_dealloc_wb].allocated = 0;
                collector_units_n[cu_to_dealloc_wb].rs1_ready = 0;
                collector_units_n[cu_to_dealloc_wb].rs2_ready = 0;
                collector_units_n[cu_to_dealloc_wb].rs3_ready = 0;
                collector_units_n[cu_to_dealloc_wb].rs1_from_rf = 0;
                collector_units_n[cu_to_dealloc_wb].rs2_from_rf = 0;
                collector_units_n[cu_to_dealloc_wb].rs3_from_rf = 0;
                collector_units_n[cu_to_dealloc_wb].dispatched = 0;
                collector_units_n[cu_to_dealloc_wb].data.wb = 0;
                collector_units_n[cu_to_dealloc_wb].rd_valid = 0;
                `ifdef PERF_ENABLE
                    cu_alloc_period_n[cu_to_dealloc_wb] = $time - cu_alloc_time[cu_to_dealloc_wb];
                `endif
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

//        logic read_cu_ready;
//        assign read_cu_ready = (state!=0 && state_n==0);
//
//        VX_generic_arbiter #(
//            .NUM_REQS    (CU_RATIO),
//            .LOCK_ENABLE (1),
//            .TYPE        ("P")
//        ) arbiter (
//            .clk         (clk),
//            .reset       (reset),
//            .requests    (reading_cus),
//            .grant_valid (read_cu_valid_out),
//            .grant_index (cu_to_read_rf_out),
//            `UNUSED_PIN (grant_onehot),
//            .grant_unlock(read_cu_ready)
//        );


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
                dealloc_wb <= 1'b0;
                state <= 2'b0;
                previous_uuid <= -1;
                previous_wis <= -1;
                read_cu_valid <= 1'b0;
                uuid_overflow <= 1'b0;
                /* verilator lint_off UNSIGNED */
                for (integer k = 0; k < CU_RATIO; k = k + 1) begin
                    collector_units[k[CU_WIS_W-1:0]].data.PC <= 0;
                    collector_units[k[CU_WIS_W-1:0]].data.wis <= 0;
                    collector_units[k[CU_WIS_W-1:0]].data.uuid <= -1;
                    collector_units[k[CU_WIS_W-1:0]].data.rs1 <= 0;
                    collector_units[k[CU_WIS_W-1:0]].data.rs2 <= 0;
                    collector_units[k[CU_WIS_W-1:0]].data.rs3 <= 0;
                    collector_units[k[CU_WIS_W-1:0]].data.rd <= 0;
                    collector_units[k[CU_WIS_W-1:0]].data.ex_type <= 0;
                    collector_units[k[CU_WIS_W-1:0]].data.wb <= 0;
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
                    collector_units[k[CU_WIS_W-1:0]].rd_valid <= 1'b0;
                    collector_units[k[CU_WIS_W-1:0]].rs1_data <= 0;
                    collector_units[k[CU_WIS_W-1:0]].rs2_data <= 0;
                    collector_units[k[CU_WIS_W-1:0]].rs3_data <= 0;
                    collector_units[k[CU_WIS_W-1:0]].rd_data <= 0;
                end
                /* verilator lint_on UNSIGNED */
                for (integer k = 0; k < `UP(ISSUE_RATIO); k = k + 1) begin
                    for (integer l = 0; l < `NUM_REGS; l = l + 1) begin
                        reg_alias_table[k][l].from_rf <= 1;
                    end
                end
            `ifdef PERF_ENABLE
                perf_nocu_stalls <= 0;
                perf_rf_reads <= 0;
                perf_rf_writes <= 0;
                perf_reorders <= 0;
                perf_cu_alloc_period <= 0;
                perf_cu_util <= 0;
                for (integer k = 1; k < 16; k = k + 1) begin
                    perf_reorder_distances[k] <= 0;
                end
                for (integer k = 0; k < CU_RATIO; k = k + 1) begin
                    cu_alloc_time[k] <= 0;
                    cu_alloc_period[k] <= 0;
                end
            `endif
            end else begin
                collector_units <= collector_units_n;
                reg_alias_table <= reg_alias_table_n;
                cache_eop   <= cache_eop_n;
                check_rat <= check_rat_n;
                deallocate <= deallocate_n;
                dealloc_wb <= dealloc_wb_n;
                uuid_overflow <= uuid_overflow_n;
                if (state_n==0) begin
                    read_cu_valid <= read_cu_valid_out;
                    cu_to_read_rf <= cu_to_read_rf_out;
                end else begin
                    read_cu_valid <= read_cu_valid_n;
                    cu_to_read_rf <= cu_to_read_rf_n;
                end
                state <= state_n;
                ibuffer_ready <= ibuffer_ready_n;
                previous_uuid <= previous_uuid_n;
                previous_wis <= previous_wis_n;
            `ifdef PERF_ENABLE
                perf_nocu_stalls <= perf_nocu_stalls + `PERF_CTR_BITS'(nocu_stall);
                perf_rf_reads <= perf_rf_reads + `PERF_CTR_BITS'(rf_read);
                perf_rf_writes <= perf_rf_writes + `PERF_CTR_BITS'(rf_write);
                perf_reorders <= perf_reorders + `PERF_CTR_BITS'(reorder);

                if (reorder) begin
                    perf_reorder_distances[reorder_distance] <= perf_reorder_distances[reorder_distance] + 1;
                end

                perf_cu_util <= perf_cu_util + `PERF_CTR_BITS'(cu_util);

                cu_alloc_period <= cu_alloc_period_n;
                cu_alloc_time <= cu_alloc_time_n;
                if (deallocate && dealloc_wb) begin
                    perf_cu_alloc_period <= perf_cu_alloc_period + 64'(cu_alloc_period_n[cu_to_deallocate]) + 64'(cu_alloc_period_n[cu_to_dealloc_wb]);
                end else if (deallocate) begin
                    perf_cu_alloc_period <= perf_cu_alloc_period + 64'(cu_alloc_period_n[cu_to_deallocate]);
                end else if (dealloc_wb) begin
                    perf_cu_alloc_period <= perf_cu_alloc_period + 64'(cu_alloc_period_n[cu_to_dealloc_wb]);
                end else begin
                    perf_cu_alloc_period <= perf_cu_alloc_period;
                end
            `endif
            end
            gpr_rd_rid  <= gpr_rd_rid_n;
            gpr_rd_wis  <= gpr_rd_wis_n;        
            cache_data  <= cache_data_n;
            cache_reg   <= cache_reg_n;
            cache_tmask <= cache_tmask_n;
            cu_to_check_rat <= cu_to_check_rat_n;
            cu_to_deallocate <= cu_to_deallocate_n;
            cu_to_dealloc_wb <= cu_to_dealloc_wb_n;
            cu_to_check_writeback <= cu_to_check_writeback_n;
            writeback_buffer <= writeback_buffer_n;
            gpr_wr_tmask <= gpr_wr_tmask_n;
        end


        always @(posedge clk) begin
        `ifdef DBG_TRACE_PIPELINE
            if ($time>600) begin
            if (ibuffer_if[i].valid) begin
                //`TRACE(1, ("\n"));
                //`TRACE(1, ("%d: i=%d ibuffer valid (PC=0x%0h wid=%d)\n", $time, i[ISSUE_ISW_W-1:0],  {ibuffer_if[i].data.PC, 1'd0}, wis_to_wid(ibuffer_if[i].data.wis, i[ISSUE_ISW_W-1:0])));
                //`TRACE(1, ("%d: i=%d empty cus : %b\n\n", $time, i[ISSUE_ISW_W-1:0],  empty_cus));
            end
            if (((previous_wis != ibuffer_if[i].data.wis) || (previous_uuid != ibuffer_if[i].data.uuid)) && allocate_cu_valid && ibuffer_if[i].valid) begin
                `TRACE(1, ("%d: i=%d allocating cu %d (PC=0x%h wid=%d) (#%d)\n", $time, i[ISSUE_ISW_W-1:0],  cu_to_allocate, {collector_units_n[cu_to_allocate].data.PC, 1'd0}, wis_to_wid(collector_units_n[cu_to_allocate].data.wis, i[ISSUE_ISW_W-1:0]), collector_units_n[cu_to_allocate].data.uuid));
            end


            if (check_rat) begin  
                `TRACE (1, ("%d: i=%d checking rat for cu %d (PC=0x%h wid=%d)\n", $time, i[ISSUE_ISW_W-1:0], cu_to_check_rat, {collector_units[cu_to_check_rat].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_check_rat].data.wis, i[ISSUE_ISW_W-1:0])));
                if (collector_units[cu_to_check_rat].data.rs1 != 0) begin
                    if (reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs1].from_rf==0 && 
                    (collector_units[reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs1].cu_id].rd_valid)) begin
                        `TRACE(1, ("%d: caught rs1 from cu %d, data = 0x%h\n", $time, reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs1].cu_id, collector_units[reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units_n[cu_to_check_rat].data.rs1].cu_id].rd_data));
                    end else begin
                        if (reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs1].from_rf) begin
                            `TRACE(1, ("%d: rs1 to be read from RF\n", $time));
                        end else begin
                            `TRACE(1, ("%d: rs1 to be read from cu %d\n", $time, reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs1].cu_id));
                            //`TRACE(1, ("%d: rat[%d][%d].cu_id = %d, cus[%d].rd_valid = %d\n", $time, collector_units[cu_to_check_rat].data.wis, collector_units[cu_to_check_rat].data.rs1, reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs1].cu_id, reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs1].cu_id, collector_units[reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs1].cu_id].rd_valid));
                        end
                    end                  
                end
                if (collector_units[cu_to_check_rat].data.rs2 != 0) begin
                    if (reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs2].from_rf==0 && 
                    (collector_units[reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs2].cu_id].rd_valid)) begin
                        `TRACE(1, ("%d: caught rs2 from cu %d, data = 0x%h\n", $time, reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs2].cu_id, collector_units[reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units_n[cu_to_check_rat].data.rs2].cu_id].rd_data));
                    end else begin
                        if (reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs2].from_rf) begin
                            `TRACE(1, ("%d: rs2 to be read from RF\n", $time));
                        end else begin
                            `TRACE(1, ("%d: rs2 to be read from cu %d\n", $time, reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs2].cu_id));
                            //`TRACE(1, ("%d: rat[%d][%d].cu_id = %d, cus[%d].rd_valid = %d\n", $time, collector_units[cu_to_check_rat].data.wis, collector_units[cu_to_check_rat].data.rs2, reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs2].cu_id, reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs2].cu_id, collector_units[reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs2].cu_id].rd_valid));
                        end
                    end
                end
                if (collector_units[cu_to_check_rat].data.rs3 != 0) begin
                    if (reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs3].from_rf==0 && 
                    (collector_units[reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs3].cu_id].rd_valid)) begin
                        `TRACE(1, ("%d: caught rs3 from cu %d, data = 0x%h\n", $time, reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs3].cu_id, collector_units[reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units_n[cu_to_check_rat].data.rs3].cu_id].rd_data));
                    end else begin
                        if (reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs3].from_rf) begin
                            `TRACE(1, ("%d: rs3 to be read from RF\n", $time));
                        end else begin
                            `TRACE(1, ("%d: rs3 to be read from cu %d\n", $time, reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs3].cu_id));
                            //`TRACE(1, ("%d: rat[%d][%d].cu_id = %d, cus[%d].rd_valid = %d\n", $time, collector_units[cu_to_check_rat].data.wis, collector_units[cu_to_check_rat].data.rs3, reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs3].cu_id, reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs3].cu_id, collector_units[reg_alias_table[collector_units[cu_to_check_rat].data.wis][collector_units[cu_to_check_rat].data.rs3].cu_id].rd_valid));
                        end
                    end
                end
                if (collector_units[cu_to_check_rat].data.wb) begin
                    `TRACE(1, ("%d: wb to wis=%d reg=%d\n", $time, collector_units[cu_to_check_rat].data.wis, collector_units[cu_to_check_rat].data.rd));
                end
                `TRACE(1, ("\n"));
            end

            // broadcast: get rd_data from rs_source
            for (integer j = 0; j < CU_RATIO; j++) begin
                if (collector_units[j[CU_WIS_W-1:0]].allocated && collector_units[j[CU_WIS_W-1:0]].dispatched == 0 && (j[CU_WIS_W-1:0] != cu_to_check_rat || check_rat==0)) begin
                    if (collector_units[j[CU_WIS_W-1:0]].rs1_from_rf==0 && collector_units[collector_units[j[CU_WIS_W-1:0]].rs1_source].rd_valid && collector_units[j[CU_WIS_W-1:0]].rs1_ready==0) begin
                        `TRACE(1, ("%d: i=%d cu %d (PC=0x%h wid=%d) caught rs1 from cu %d, data = 0x%h\n\n", $time, i[ISSUE_ISW_W-1:0], j[CU_WIS_W-1:0], {collector_units[j[CU_WIS_W-1:0]].data.PC, 1'd0}, wis_to_wid(collector_units[j[CU_WIS_W-1:0]].data.wis, i[ISSUE_ISW_W-1:0]), collector_units[j[CU_WIS_W-1:0]].rs1_source, collector_units[collector_units[j[CU_WIS_W-1:0]].rs1_source].rd_data));
                    end
                    if (collector_units[j[CU_WIS_W-1:0]].rs2_from_rf==0 && collector_units[collector_units[j[CU_WIS_W-1:0]].rs2_source].rd_valid && collector_units[j[CU_WIS_W-1:0]].rs2_ready==0) begin
                        `TRACE(1, ("%d: i=%d cu %d (PC=0x%h wid=%d) caught rs2 from cu %d, data = 0x%h\n\n", $time, i[ISSUE_ISW_W-1:0], j[CU_WIS_W-1:0], {collector_units[j[CU_WIS_W-1:0]].data.PC, 1'd0}, wis_to_wid(collector_units[j[CU_WIS_W-1:0]].data.wis, i[ISSUE_ISW_W-1:0]), collector_units[j[CU_WIS_W-1:0]].rs2_source, collector_units[collector_units[j[CU_WIS_W-1:0]].rs2_source].rd_data));
                    end
                    if (collector_units[j[CU_WIS_W-1:0]].rs3_from_rf==0 && collector_units[collector_units[j[CU_WIS_W-1:0]].rs3_source].rd_valid && collector_units[j[CU_WIS_W-1:0]].rs3_ready==0) begin
                        `TRACE(1, ("%d: i=%d cu %d (PC=0x%h wid=%d) caught rs3 from cu %d, data = 0x%h\n\n", $time, i[ISSUE_ISW_W-1:0], j[CU_WIS_W-1:0], {collector_units[j[CU_WIS_W-1:0]].data.PC, 1'd0}, wis_to_wid(collector_units[j[CU_WIS_W-1:0]].data.wis, i[ISSUE_ISW_W-1:0]), collector_units[j[CU_WIS_W-1:0]].rs3_source, collector_units[collector_units[j[CU_WIS_W-1:0]].rs3_source].rd_data));
                    end
                end       
            end

            // writeback
            if (writeback_if[i].valid) begin
                `TRACE(1,("%d: i=%d writeback valid (PC=0x%0h wid=%d)\n", $time, i[ISSUE_ISW_W-1:0],  {writeback_if[i].data.PC, 1'd0}, wis_to_wid(writeback_if[i].data.wis, i[ISSUE_ISW_W-1:0])));
                if (writeback_if[i].data.eop) begin
                    `TRACE(1, ("%d: cu %d writeback found eop, data: 0x%h\n", $time, writeback_if[i].data.cu_id, writeback_if[i].data.data));
                    if (reg_alias_table[collector_units[writeback_if[i].data.cu_id].data.wis][collector_units[writeback_if[i].data.cu_id].data.rd].cu_id == writeback_if[i].data.cu_id) begin
                        `TRACE(1, ("%d: wb to rf rd=0x%h, data = 0x%h\n", $time, collector_units[writeback_if[i].data.cu_id].data.rd, writeback_if[i].data.data));
                    end else begin
                        `TRACE(1, ("%d: no wb to rf, rat cu_id=%d\n", $time, reg_alias_table_n[collector_units[writeback_if[i].data.cu_id].data.wis][collector_units[writeback_if[i].data.cu_id].data.rd].cu_id)); 
                    end
                end
                `TRACE(1, ("\n"));
            end

            if (collector_units[cu_to_check_writeback].rd_valid) begin
                `TRACE(1, ("%d: i=%d cu %d (PC=0x%h wid=%d) valid data = 0x%h\n", $time, i[ISSUE_ISW_W-1:0], cu_to_check_writeback, {collector_units[cu_to_check_writeback].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_check_writeback].data.wis, i[ISSUE_ISW_W-1:0]), collector_units[cu_to_check_writeback].rd_data));
                if (writeback) begin
                    `TRACE(1, ("%d: i=%d cu %d writeback to rf gpr_wr_addr=0x%h, tmask=%b, data=0x%h\n", $time, i[ISSUE_ISW_W-1:0], cu_to_check_writeback, gpr_wr_addr, collector_units[cu_to_check_writeback].data.tmask, collector_units[cu_to_check_writeback].rd_data));
                end
                `TRACE(1, ("%d: i=%d cu %d (PC=0x%h wid=%d) ready to deallocate\n\n", $time, i[ISSUE_ISW_W-1:0], cu_to_check_writeback, {collector_units[cu_to_check_writeback].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_check_writeback].data.wis, i[ISSUE_ISW_W-1:0])));
            end

            // read rf
            if (read_cu_valid && state==0) begin
                if (collector_units[cu_to_read_rf].rs1_from_rf && ~(collector_units[cu_to_read_rf].rs1_ready)) begin
                    `TRACE(1, ("%d: state=%d, state_n=%d, cu %d (PC=0x%h wid=%d) to read rs1 from RF\n", $time, state, state_n, cu_to_read_rf, {collector_units[cu_to_read_rf].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_read_rf].data.wis, i[ISSUE_ISW_W-1:0])));
                end else if (collector_units[cu_to_read_rf].rs2_from_rf && ~(collector_units[cu_to_read_rf].rs2_ready)) begin
                    `TRACE(1, ("%d: state=%d, state_n=%d, cu %d (PC=0x%h wid=%d) to read rs2 from RF\n", $time, state, state_n, cu_to_read_rf, {collector_units[cu_to_read_rf].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_read_rf].data.wis, i[ISSUE_ISW_W-1:0])));
                end else if (collector_units[cu_to_read_rf].rs3_from_rf && ~(collector_units[cu_to_read_rf].rs3_ready)) begin
                    `TRACE(1, ("%d: state=%d, state_n=%d, cu %d (PC=0x%h wid=%d) to read rs3 from RF\n", $time, state, state_n, cu_to_read_rf, {collector_units[cu_to_read_rf].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_read_rf].data.wis, i[ISSUE_ISW_W-1:0])));
                end else begin
                    `TRACE(1, ("%d: state=%d, state_n=%d, cu %d (PC=0x%h wid=%d) to not read data from RF\n", $time, state, state_n, cu_to_read_rf, {collector_units[cu_to_read_rf].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_read_rf].data.wis, i[ISSUE_ISW_W-1:0])));
                    //`TRACE(1, ("%d: cu %d rs1_ready=%d, rs2_ready=%d, rs3_ready=%d\n", $time, cu_to_read_rf, collector_units[cu_to_read_rf].rs1_ready, collector_units[cu_to_read_rf].rs2_ready, collector_units[cu_to_read_rf].rs3_ready));
                end
            end else if (state==1) begin
                if (collector_units[cu_to_read_rf].rs2_from_rf && ~(collector_units[cu_to_read_rf].rs2_ready)) begin
                    `TRACE(1, ("%d: state=%d, state_n=%d, cu %d (PC=0x%h wid=%d) to read rs2 from RF\n", $time, state, state_n, cu_to_read_rf, {collector_units[cu_to_read_rf].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_read_rf].data.wis, i[ISSUE_ISW_W-1:0])));
                end else if (collector_units[cu_to_read_rf].rs3_from_rf && ~(collector_units[cu_to_read_rf].rs3_ready)) begin
                    `TRACE(1, ("%d: state=%d, state_n=%d, cu %d (PC=0x%h wid=%d) to read rs3 from RF\n", $time, state, state_n, cu_to_read_rf, {collector_units[cu_to_read_rf].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_read_rf].data.wis, i[ISSUE_ISW_W-1:0])));
                end else begin
                    `TRACE(1, ("%d: state=%d, state_n=%d, cu %d (PC=0x%h wid=%d) to not read more data from RF\n", $time, state, state_n, cu_to_read_rf, {collector_units[cu_to_read_rf].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_read_rf].data.wis, i[ISSUE_ISW_W-1:0])));
                    //`TRACE(1, ("%d: cu %d rs1_ready=%d, rs2_ready=%d, rs3_ready=%d\n", $time, cu_to_read_rf, collector_units[cu_to_read_rf].rs1_ready, collector_units[cu_to_read_rf].rs2_ready, collector_units[cu_to_read_rf].rs3_ready));
                end
            end else if (state==2) begin
                if (collector_units[cu_to_read_rf].rs3_from_rf && ~(collector_units[cu_to_read_rf].rs3_ready)) begin
                    `TRACE(1, ("%d: state=%d, state_n=%d, cu %d (PC=0x%h wid=%d) to read rs3 from RF\n", $time, state, state_n, cu_to_read_rf, {collector_units[cu_to_read_rf].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_read_rf].data.wis, i[ISSUE_ISW_W-1:0])));
                end else begin
                    `TRACE(1, ("%d: state=%d, state_n=%d, cu %d (PC=0x%h wid=%d) to not read more data from RF\n", $time, state, state_n, cu_to_read_rf, {collector_units[cu_to_read_rf].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_read_rf].data.wis, i[ISSUE_ISW_W-1:0])));
                    //`TRACE(1, ("%d: cu %d rs1_ready=%d, rs2_ready=%d, rs3_ready=%d\n", $time, cu_to_read_rf, collector_units[cu_to_read_rf].rs1_ready, collector_units[cu_to_read_rf].rs2_ready, collector_units[cu_to_read_rf].rs3_ready));
                end
            end else begin
                //`TRACE(1, ("%d: state=%d, state_n=%d, cu %d (PC=0x%h wid=%d) to not read data from RF\n", $time, state, state_n, cu_to_read_rf, {collector_units[cu_to_read_rf].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_read_rf].data.wis, i[ISSUE_ISW_W-1:0])));
            end

            if (state==1) begin
                `TRACE(1, ("%d: i=%d read data from RF for cu %d (PC=0x%h wid=%d) rs1 : 0x%h, cu data : 0x%h (reading register=%d, gpr_rid_in= %d, gpr_rd_addr=0x%h)\n\n", $time, i[ISSUE_ISW_W-1:0],  cu_to_read_rf, {collector_units[cu_to_read_rf].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_read_rf].data.wis, i[ISSUE_ISW_W-1:0]), gpr_rd_data, collector_units[cu_to_read_rf].rs1_data, collector_units[cu_to_read_rf].data.rs1, gpr_rd_rid, gpr_rd_addr));
            end else if (state==2) begin
                `TRACE(1, ("%d: i=%d read data from RF for cu %d (PC=0x%h wid=%d) rs2 : 0x%h, cu data : 0x%h (reading register=%d, gpr_rid_in= %d, gpr_rd_addr=0x%h))\n\n", $time, i[ISSUE_ISW_W-1:0],  cu_to_read_rf, {collector_units[cu_to_read_rf].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_read_rf].data.wis, i[ISSUE_ISW_W-1:0]), gpr_rd_data, collector_units[cu_to_read_rf].rs2_data, collector_units[cu_to_read_rf].data.rs2, gpr_rd_rid, gpr_rd_addr));
            end else if (state==3) begin
                `TRACE(1, ("%d: i=%d read data from RF for cu %d (PC=0x%h wid=%d) rs3 : 0x%h, cu data : 0x%h (reading register=%d, gpr_rid_in= %d, gpr_rd_addr=0x%h))\n\n", $time, i[ISSUE_ISW_W-1:0],  cu_to_read_rf, {collector_units[cu_to_read_rf].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_read_rf].data.wis, i[ISSUE_ISW_W-1:0]), gpr_rd_data, collector_units[cu_to_read_rf].rs3_data, collector_units[cu_to_read_rf].data.rs3, gpr_rd_rid, gpr_rd_addr));
            end else if (read_cu_valid) begin
                //`TRACE(1, ("%d: i=%d state = %d, cu_to_read_rf = %d, read_cu_valid = %d\n", $time, i[ISSUE_ISW_W-1:0],  state, cu_to_read_rf, read_cu_valid));
            end

            if (stg_valid_in) begin
                `TRACE(1, ("%d: i=%d dispatching pt.1 cu %d (PC=0x%h wid=%d) ex=", $time, i[ISSUE_ISW_W-1:0],  cu_to_dispatch, {collector_units[cu_to_dispatch].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_dispatch].data.wis, i[ISSUE_ISW_W-1:0])));
                trace_ex_type(1, collector_units[cu_to_dispatch].data.ex_type);
                `TRACE(1, ("\n"));
                `TRACE(1, ("%d: i=%d operands rs1 : 0x%h, rs2 : 0x%h, rs3 : 0x%h\n", $time, i[ISSUE_ISW_W-1:0],  operands_if[i].data.rs1_data, operands_if[i].data.rs2_data, operands_if[i].data.rs3_data));
            end
            if (stg_ready_in && dispatch_cu_valid) begin
                `TRACE(1, ("%d: i=%d dispatching pt.2 cu %d (PC=0x%h wid=%d)\n\n", $time, i[ISSUE_ISW_W-1:0],  cu_to_dispatch, {collector_units[cu_to_dispatch].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_dispatch].data.wis, i[ISSUE_ISW_W-1:0])));
            end


            if (deallocate) begin
                `TRACE(1, ("%d: i=%d deallocating cu %d (PC=0x%h)\n", $time, i[ISSUE_ISW_W-1:0],  cu_to_deallocate, {collector_units[cu_to_deallocate].data.PC, 1'd0}));
                `TRACE(1, ("%d: i=%d empty cus : %b\n\n", $time, i[ISSUE_ISW_W-1:0],  empty_cus));
            end 

            if (dealloc_wb) begin
                `TRACE(1, ("%d: i=%d deallocating cu %d (PC=0x%h) because of wb=0\n", $time, i[ISSUE_ISW_W-1:0],  cu_to_dealloc_wb, {collector_units[cu_to_dealloc_wb].data.PC, 1'd0}));
                `TRACE(1, ("%d: i=%d empty cus : %b\n\n", $time, i[ISSUE_ISW_W-1:0],  empty_cus));
            end


            for (integer j = 0; j < CU_RATIO; j++) begin
                if (collector_units[j[CU_WIS_W-1:0]].allocated && (collector_units[j[CU_WIS_W-1:0]].dispatched == 0) && collector_units[j[CU_WIS_W-1:0]].rs1_ready && collector_units[j[CU_WIS_W-1:0]].rs2_ready && collector_units[j[CU_WIS_W-1:0]].rs3_ready) begin
                    `TRACE(1, ("%d: i=%d cu %d (PC=0x%h wid=%d) is ready to dispatch\n", $time, i[ISSUE_ISW_W-1:0],  j[CU_WIS_W-1:0], {collector_units[j[CU_WIS_W-1:0]].data.PC, 1'd0}, wis_to_wid(collector_units[j[CU_WIS_W-1:0]].data.wis, i[ISSUE_ISW_W-1:0])));

                    // no reordering for LSU instructions
                    if (collector_units[j[CU_WIS_W-1:0]].data.ex_type == `EX_LSU) begin 
                        for (integer k = 0; k < CU_RATIO; k++) begin
                            if (collector_units[k[CU_WIS_W-1:0]].dispatched==0 && collector_units[k[CU_WIS_W-1:0]].allocated && collector_units[k[CU_WIS_W-1:0]].data.wis == collector_units[j[CU_WIS_W-1:0]].data.wis && 
                                collector_units[k[CU_WIS_W-1:0]].data.ex_type == `EX_LSU &&
                                (((collector_units[k[CU_WIS_W-1:0]].data.uuid < collector_units[j[CU_WIS_W-1:0]].data.uuid) && (collector_units[k[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]!=2'b00 || collector_units[j[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]!=2'b11)) ||
                                (collector_units[k[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b11 && collector_units[j[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b00))) begin
                                `TRACE(1, ("%d: i=%d LSU conflict: cu %d (PC=0x%h wid=%d) (#%d) is not ready to dispatch because of cu %d (PC=0x%h wid=%d) (#%d)\n\n", $time, i[ISSUE_ISW_W-1:0],  j[CU_WIS_W-1:0], {collector_units[j[CU_WIS_W-1:0]].data.PC, 1'd0}, wis_to_wid(collector_units[j[CU_WIS_W-1:0]].data.wis, i[ISSUE_ISW_W-1:0]), collector_units[j[CU_WIS_W-1:0]].data.uuid, k[CU_WIS_W-1:0], {collector_units[k[CU_WIS_W-1:0]].data.PC, 1'd0}, wis_to_wid(collector_units[k[CU_WIS_W-1:0]].data.wis, i[ISSUE_ISW_W-1:0]), collector_units[k[CU_WIS_W-1:0]].data.uuid));
                            end
                        end 
                    end
                    // don't let an instruction with rd=x dispatch if a previous instruction is waiting to read x from RF
                    for (integer k = 0; k < CU_RATIO; k++) begin
                        if (collector_units[j[CU_WIS_W-1:0]].data.wis == collector_units[k[CU_WIS_W-1:0]].data.wis && 
                            ((collector_units[j[CU_WIS_W-1:0]].data.rd == collector_units[k[CU_WIS_W-1:0]].data.rs1 && collector_units[k[CU_WIS_W-1:0]].rs1_from_rf==1 && collector_units[k[CU_WIS_W-1:0]].rs1_ready==0) ||
                            (collector_units[j[CU_WIS_W-1:0]].data.rd == collector_units[k[CU_WIS_W-1:0]].data.rs2 && collector_units[k[CU_WIS_W-1:0]].rs2_from_rf==1 && collector_units[k[CU_WIS_W-1:0]].rs2_ready==0) ||
                            (collector_units[j[CU_WIS_W-1:0]].data.rd == collector_units[k[CU_WIS_W-1:0]].data.rs3 && collector_units[k[CU_WIS_W-1:0]].rs3_from_rf==1 && collector_units[k[CU_WIS_W-1:0]].rs3_ready==0)) &&
                            (((collector_units[k[CU_WIS_W-1:0]].data.uuid < collector_units[j[CU_WIS_W-1:0]].data.uuid) && (collector_units[k[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]!=2'b00 || collector_units[j[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]!=2'b11)) ||
                            (collector_units[k[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b11 && collector_units[j[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b00))) begin
                            `TRACE(1, ("%d: i=%d WAR conflict: cu %d (PC=0x%h wid=%d) (#%d) is not ready to dispatch because of cu %d (PC=0x%h wid=%d) (#%d)\n\n", $time, i[ISSUE_ISW_W-1:0],  j[CU_WIS_W-1:0], {collector_units[j[CU_WIS_W-1:0]].data.PC, 1'd0}, wis_to_wid(collector_units[j[CU_WIS_W-1:0]].data.wis, i[ISSUE_ISW_W-1:0]), collector_units[j[CU_WIS_W-1:0]].data.uuid, k[CU_WIS_W-1:0], {collector_units[k[CU_WIS_W-1:0]].data.PC, 1'd0}, wis_to_wid(collector_units[k[CU_WIS_W-1:0]].data.wis, i[ISSUE_ISW_W-1:0]), collector_units[k[CU_WIS_W-1:0]].data.uuid));
                        end
                    end
                end
            end


            if (ready_cus!=0) begin
                //`TRACE(1, ("%d: i=%d ready cus : %b\n", $time, i[ISSUE_ISW_W-1:0],  ready_cus));
                `TRACE(1, ("%d: i=%d stg_valid_in=%d, stg_ready_in=%d, operands_if ready=%d operands_if valid=%d\n", $time, i[ISSUE_ISW_W-1:0],  stg_valid_in, stg_ready_in, operands_if[i].ready, operands_if[i].valid));
                if (dispatch_cu_valid) begin
                    `TRACE(1, ("%d: i=%d valid cu_to_dispatch=%d (PC=0x%h wid=%d) ex_type=", $time, i[ISSUE_ISW_W-1:0],  cu_to_dispatch, {collector_units[cu_to_dispatch].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_dispatch].data.wis, i[ISSUE_ISW_W-1:0])));
                    trace_ex_type(1, collector_units[cu_to_dispatch].data.ex_type);
                    `TRACE(1, ("\n\n"));
                end
            end
            end
        `endif
        end

        always @(*) begin
            uuid_overflow_n = 1'b0;
        `ifdef PERF_ENABLE
            reorder = 0;
            reorder_distance = 0;
            cu_util = 0;
        `endif

            for (integer j = 0; j < CU_RATIO; j++) begin
                if ($time>610 && ibuffer_if[i].valid && (collector_units[j[CU_WIS_W-1:0]].data.wis == ibuffer_if[i].data.wis) && (ibuffer_if[i].data.uuid==`UUID_WIDTH'(-1)) && (collector_units[j[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b00)) begin
                    uuid_overflow_n = 1'b1;
                    `ifdef DBG_TRACE_PIPELINE 
                        `TRACE(1, ("%d: uuid overflow detected: ibuffer (PC=0x%h wid=%d) uuid=%d, cu %d (PC=0x%h wid=%d) uuid=%d\n", $time, {ibuffer_if[i].data.PC, 1'd0}, wis_to_wid(ibuffer_if[i].data.wis, i[ISSUE_ISW_W-1:0]), ibuffer_if[i].data.uuid, j[CU_WIS_W-1:0], {collector_units[j[CU_WIS_W-1:0]].data.PC, 1'd0}, wis_to_wid(collector_units[j[CU_WIS_W-1:0]].data.wis, i[ISSUE_ISW_W-1:0]), collector_units[j[CU_WIS_W-1:0]].data.uuid));
                    `endif
                end
            end

        `ifdef PERF_ENABLE
            for (integer j = 0; j < CU_RATIO; j++) begin
                if (collector_units[j[CU_WIS_W-1:0]].allocated && $time>610 && stg_valid_in && j[CU_WIS_W-1:0] != cu_to_dispatch && collector_units[j[CU_WIS_W-1:0]].dispatched == 0 && 
                collector_units[j[CU_WIS_W-1:0]].data.wis == collector_units[cu_to_dispatch].data.wis && 
                ((collector_units[j[CU_WIS_W-1:0]].data.uuid < collector_units[cu_to_dispatch].data.uuid && 
                !(collector_units[j[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b00 && collector_units[cu_to_dispatch].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b11)) 
                || (collector_units[j[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b11 && collector_units[cu_to_dispatch].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b00))) begin
                    reorder = 1;
                    `ifdef DBG_TRACE_PIPELINE
                        `TRACE(1, ("%d: reorder detected: cu %d (PC=0x%h wid=%d) uuid=%d, cu to dispatch %d (PC=0x%h wid=%d) uuid=%d\n", $time, j[CU_WIS_W-1:0], {collector_units[j[CU_WIS_W-1:0]].data.PC, 1'd0}, wis_to_wid(collector_units[j[CU_WIS_W-1:0]].data.wis, i[ISSUE_ISW_W-1:0]), collector_units[j[CU_WIS_W-1:0]].data.uuid, cu_to_dispatch, {collector_units[cu_to_dispatch].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_dispatch].data.wis, i[ISSUE_ISW_W-1:0]), collector_units[cu_to_dispatch].data.uuid));
                    `endif
                    if (collector_units[j[CU_WIS_W-1:0]].data.uuid < collector_units[cu_to_dispatch].data.uuid && 
                    !(collector_units[j[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b00 && collector_units[cu_to_dispatch].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b11)) begin
                        if ((5'(collector_units[cu_to_dispatch].data.uuid - collector_units[j[CU_WIS_W-1:0]].data.uuid) > 5'(reorder_distance)) && (5'(collector_units[cu_to_dispatch].data.uuid - collector_units[j[CU_WIS_W-1:0]].data.uuid) < 16)) begin
                            reorder_distance = 4'(collector_units[cu_to_dispatch].data.uuid - collector_units[j[CU_WIS_W-1:0]].data.uuid);
                        end
                    end else if (collector_units[j[CU_WIS_W-1:0]].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b11 && collector_units[cu_to_dispatch].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b00) begin
                        if (5'(`UUID_WIDTH'(-1) - collector_units[j[CU_WIS_W-1:0]].data.uuid + collector_units[cu_to_dispatch].data.uuid) > 5'(reorder_distance) && 5'(`UUID_WIDTH'(-1) - collector_units[j[CU_WIS_W-1:0]].data.uuid + collector_units[cu_to_dispatch].data.uuid) < 16) begin
                            reorder_distance = 4'(`UUID_WIDTH'(-1) - collector_units[j[CU_WIS_W-1:0]].data.uuid + collector_units[cu_to_dispatch].data.uuid);
                        end
                    end
                end

                if (collector_units[j[CU_WIS_W-1:0]].allocated == 1) begin
                    cu_util = cu_util + 1;
                end
            end
        `endif
        end
        //`RUNTIME_ASSERT((uuid_overflow==1 && $time>610), ("uuid overflow detected"));


        always @(posedge clk) begin
        `ifdef DBG_TRACE_METRICS
            // reset
            if (reset) begin
                `TRACE(1, ("%d: reset\n", $time));
            end

            // active threads
            if (((previous_wis != ibuffer_if[i].data.wis) || (previous_uuid != ibuffer_if[i].data.uuid)) && ibuffer_if[i].valid) begin
                `TRACE(1, ("%d: ibuffer valid (PC=0x%0h wid=%d) tmask=%b\n", $time, {ibuffer_if[i].data.PC, 1'd0}, wis_to_wid(ibuffer_if[i].data.wis, i[ISSUE_ISW_W-1:0]), ibuffer_if[i].data.tmask));
            end

            // cu occupancy
            if (((previous_wis != ibuffer_if[i].data.wis) || (previous_uuid != ibuffer_if[i].data.uuid)) && allocate_cu_valid && ibuffer_if[i].valid) begin
                `TRACE(1, ("%d: allocating cu %d (PC=0x%h wid=%d)\n", $time,  cu_to_allocate, {collector_units_n[cu_to_allocate].data.PC, 1'd0}, wis_to_wid(collector_units_n[cu_to_allocate].data.wis, i[ISSUE_ISW_W-1:0])));
                `TRACE(1, ("%d: empty cus : %b\n\n", $time, empty_cus));
            end
            if (deallocate) begin
                `TRACE(1, ("%d: deallocating cu %d (PC=0x%h wid=%d)\n", $time, cu_to_deallocate, {collector_units[cu_to_deallocate].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_deallocate].data.wis, i[ISSUE_ISW_W-1:0])));
                `TRACE(1, ("%d: empty cus : %b\n\n", $time, empty_cus));
            end
            if (dealloc_wb) begin
                `TRACE(1, ("%d: deallocating cu %d (PC=0x%h wid=%d)\n", $time, cu_to_dealloc_wb, {collector_units[cu_to_dealloc_wb].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_dealloc_wb].data.wis, i[ISSUE_ISW_W-1:0])));
                `TRACE(1, ("%d: empty cus : %b\n\n", $time, empty_cus));
            end

            // rf reads and writes
            if (read_cu_valid) begin
                `TRACE(1, ("%d: reading cus: %b\n", $time, reading_cus));
                if (collector_units[cu_to_read_rf].rs1_from_rf && ~(collector_units[cu_to_read_rf].rs1_ready)) begin
                    `TRACE(1, ("%d: reading cu %d (PC=0x%h wid=%d) rs1 from RF, state = %d\n", $time, cu_to_read_rf, {collector_units[cu_to_read_rf].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_read_rf].data.wis, i[ISSUE_ISW_W-1:0]), state));
                end else if (collector_units_n[cu_to_read_rf_n].rs2_from_rf && ~(collector_units[cu_to_read_rf].rs2_ready)) begin
                    `TRACE(1, ("%d: reading cu %d (PC=0x%h wid=%d) rs2 from RF, state = %d\n", $time, cu_to_read_rf, {collector_units[cu_to_read_rf].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_read_rf].data.wis, i[ISSUE_ISW_W-1:0]), state));
                end else if (collector_units_n[cu_to_read_rf_n].rs3_from_rf && ~(collector_units[cu_to_read_rf].rs3_ready)) begin
                    `TRACE(1, ("%d: reading cu %d (PC=0x%h wid=%d) rs3 from RF, state = %d\n", $time, cu_to_read_rf, {collector_units[cu_to_read_rf].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_read_rf].data.wis, i[ISSUE_ISW_W-1:0]), state));
                end
                `TRACE(1, ("\n"));
            end
            if (writeback) begin
                `TRACE(1, ("%d: writeback to rf cu %d (PC=0x%h wid=%d)\n", $time, cu_to_check_writeback, {collector_units[cu_to_check_writeback].data.PC, 1'd0}, wis_to_wid(collector_units[cu_to_check_writeback].data.wis, i[ISSUE_ISW_W-1:0])));
            end
        `endif
        end



        assign ibuffer_if[i].ready = ibuffer_ready;
        assign stg_valid_in = stg_ready_in && dispatch_cu_valid;
    `ifdef PERF_ENABLE
        assign nocu_stall = (allocate_cu_valid==0) && (check_rat_n==0);
        assign rf_read = (state!=0);
        assign rf_write = (writeback);
    `endif


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
                collector_units[cu_to_dispatch].data.op_args,
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
                operands_if[i].data.op_args,
                operands_if[i].data.rd
            }),
            .ready_out (operands_if[i].ready)
        );

        // GPR banks

        reg [RAM_ADDRW-1:0] gpr_rd_addr;    
        logic [RAM_ADDRW-1:0] gpr_rd_addr_n;
        wire [RAM_ADDRW-1:0] gpr_wr_addr;
        if (ISSUE_WIS != 0) begin
            assign gpr_wr_addr = {collector_units[cu_to_check_writeback].data.wis, collector_units[cu_to_check_writeback].data.rd};
            assign gpr_rd_addr_n = {gpr_rd_wis_n, gpr_rd_rid_n};
        end else begin
            assign gpr_wr_addr = collector_units[cu_to_check_writeback].data.rd;
            assign gpr_rd_addr_n = gpr_rd_rid_n;
        end
        always @(posedge clk) begin
            gpr_rd_addr <= gpr_rd_addr_n;
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
                .LUTRAM (1),
            `ifdef GPR_RESET
                .INIT_ENABLE (1),
                .INIT_VALUE (0),
            `endif
                .NO_RWCHECK (1)
            ) gpr_ram (
                .clk   (clk),
                .read  (1'b1),
                `UNUSED_PIN (wren),
            `ifdef GPR_RESET
                .write (wr_enabled && writeback && (gpr_wr_tmask[j])),
            `else
                .write (writeback),
            `endif              
                .waddr (gpr_wr_addr),
                .wdata (writeback_buffer[j]),
                .raddr (gpr_rd_addr),
                .rdata (gpr_rd_data[j])
            );
        end
    end
endmodule
