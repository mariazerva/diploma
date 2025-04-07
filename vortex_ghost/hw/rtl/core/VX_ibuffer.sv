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

module VX_ibuffer import VX_gpu_pkg::*; #(
    parameter CORE_ID = 0
) (
    input wire          clk,
    input wire          reset,

`ifdef PERF_ENABLE
    output reg [`PERF_CTR_BITS-1:0] perf_noisb_stalls,
    output reg [`PERF_CTR_BITS-1:0] perf_reorders,
    output reg [`PERF_CTR_BITS-1:0] perf_reorder_distances[15:1],
    output reg [`PERF_CTR_BITS-1:0] perf_isb_util,
    output reg [64-1:0] perf_isb_alloc_period,
    output reg [`PERF_CTR_BITS-1:0] perf_infl_util,
    output reg [64-1:0] perf_infl_alloc_period,
`endif

    // inputs
    VX_decode_if.slave  decode_if,
    VX_writeback_if.slave writeback_if[`ISSUE_WIDTH],

    // outputs
    VX_ibuffer_if.master ibuffer_if [`NUM_WARPS]
);
    `UNUSED_PARAM (CORE_ID)
    localparam DATAW = INFL_WIS_W + `UUID_WIDTH + `NUM_THREADS + `PC_BITS + 1 + `EX_BITS + `INST_OP_BITS + `INST_ARGS_BITS + (`NR_BITS * 4);
    localparam DEPEND_BITS = `ISB_INSTRS + `INFL_INSTRS;
    localparam DEPEND_WIS = `CLOG2(DEPEND_BITS);
    localparam DEPEND_WIS_W = `UP(DEPEND_WIS);

    typedef struct packed {
        logic [`UUID_WIDTH-1:0]     uuid;
        logic [`NW_WIDTH-1:0]       wid;
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
    } isb_data_t;

    typedef struct packed {
        logic allocated;
        logic [`UUID_WIDTH-1:0]     uuid;
        logic [`NW_WIDTH-1:0]       wid;
        logic [`NR_BITS-1:0]        rd;
    } infl_instrs_t;

    typedef struct packed {
        logic                       allocated;
        logic                       issued;
        isb_data_t                  data;
        logic [DEPEND_BITS-1:0]  dependencies; // lsb: isb, msb: in-flight
    } issue_buffer_t;

    typedef struct packed {
        logic [`UUID_WIDTH-1:0]     uuid;
        logic [`PC_BITS-1:0]        PC;
        logic [`NW_WIDTH-1:0]    wid;
        logic [INFL_WIS_W-1:0]   infl_id;
    } writeback_data_t;

    typedef struct packed {
        writeback_data_t data;
        logic           valid;
    } writeback_interface_t;

    issue_buffer_t [`ISB_INSTRS-1:0] issue_buffer, issue_buffer_n;
    infl_instrs_t [`INFL_INSTRS-1:0] infl_instrs, infl_instrs_n;
    writeback_interface_t writeback_interface;

    logic   [`ISB_INSTRS-1:0]   empty_isb;
    logic   [ISB_WIS_W-1:0]     isb_to_allocate;
    logic                       allocate_isb_valid;

    logic   [`INFL_INSTRS-1:0]  empty_infl;
    logic   [INFL_WIS_W-1:0]    infl_to_allocate;
    logic                       allocate_infl_valid;

    reg     decode_ready;
    logic   decode_ready_n;
    reg     [`UUID_WIDTH-1:0]   previous_uuid;
    reg     [`NW_WIDTH-1:0]     previous_wid;
    logic   [`UUID_WIDTH-1:0]   previous_uuid_n;
    logic   [`NW_WIDTH-1:0]     previous_wid_n;

    reg     uuid_overflow;
    logic   uuid_overflow_n;

    reg     check_dependencies;
    logic   check_dependencies_n;
    reg     [ISB_WIS_W-1:0]   isb_to_check;
    logic   [ISB_WIS_W-1:0]   isb_to_check_n;

    logic   [`ISB_INSTRS-1:0]   ready_isb;
    logic   [ISB_WIS_W-1:0]     isb_to_issue_1;
    logic   issue_isb_valid_1;

    logic   [`ISB_INSTRS-1:0]   low_uuid_isb;
    logic   [ISB_WIS_W-1:0]     isb_to_issue_2;
    logic   issue_isb_valid_2;

    reg     deallocate_isb;
    logic   deallocate_isb_n;
    logic   [ISB_WIS_W-1:0]     isb_to_deallocate;
    logic   [ISB_WIS_W-1:0]     isb_to_deallocate_n;

    reg     deallocate_infl;
    logic   deallocate_infl_n;
    logic   [INFL_WIS_W-1:0]   infl_to_deallocate;
    logic   [INFL_WIS_W-1:0]   infl_to_deallocate_n;

    `ifdef PERF_ENABLE
        logic noisb_stall;
        logic reorder;
        logic [3:0] reorder_distance;
        logic [ISB_WIS_W-1:0] isb_util;
        reg [`ISB_INSTRS-1:0][64-1:0] isb_alloc_time;
        logic [`ISB_INSTRS-1:0][64-1:0] isb_alloc_time_n;
        reg [`ISB_INSTRS-1:0][64-1:0] isb_alloc_period;
        logic [`ISB_INSTRS-1:0][64-1:0] isb_alloc_period_n;
        logic [INFL_WIS_W-1:0] infl_util;
        reg [`INFL_INSTRS-1:0][64-1:0] infl_alloc_time;
        logic [`INFL_INSTRS-1:0][64-1:0] infl_alloc_time_n;
        reg [`INFL_INSTRS-1:0][64-1:0] infl_alloc_period;
        logic [`INFL_INSTRS-1:0][64-1:0] infl_alloc_period_n;
    `endif

    always @(*) begin
        issue_buffer_n = issue_buffer;
        infl_instrs_n = infl_instrs;
        previous_uuid_n = previous_uuid;
        previous_wid_n = previous_wid;
        decode_ready_n = decode_ready;
        infl_to_deallocate_n = infl_to_deallocate;
        deallocate_infl_n = 0;
        low_uuid_isb = 0;
        ready_isb = 0;

        `ifdef PERF_ENABLE
            isb_alloc_time_n = isb_alloc_time;
            infl_alloc_time_n = infl_alloc_time;
            isb_alloc_period_n = isb_alloc_period;
            infl_alloc_period_n = infl_alloc_period;
        `endif


        // allocate isb entry
        if (!uuid_overflow && allocate_isb_valid && ((previous_wid != decode_if.data.wid) || (previous_uuid != decode_if.data.uuid)) && decode_if.valid) begin
            issue_buffer_n[isb_to_allocate].allocated = 1;
            issue_buffer_n[isb_to_allocate].data = decode_if.data;

            previous_uuid_n = decode_if.data.uuid;
            previous_wid_n = decode_if.data.wid;
            decode_ready_n = 1;

            check_dependencies_n = 1;
            isb_to_check_n = isb_to_allocate;

        `ifdef PERF_ENABLE
            isb_alloc_time_n[isb_to_allocate] = 64'($time);
        `endif

        end else begin 
            decode_ready_n = 0;
            previous_uuid_n = previous_uuid;
            previous_wid_n = previous_wid;

            check_dependencies_n = 0;
            isb_to_check_n = isb_to_check;
        end

        for (integer i = 0; i < `ISB_INSTRS; i++) begin
            empty_isb[i] = ~(issue_buffer[i].allocated);
        end

        for (integer i = 0; i < `INFL_INSTRS; i++) begin
            empty_infl[i] = ~(infl_instrs[i].allocated);
        end

        // check dependencies for the first time
        if (check_dependencies) begin
            // for in-flight instructions
            for (integer j = 0; j < `INFL_INSTRS; j++) begin
                if (infl_instrs[j].allocated && infl_instrs[j].wid == issue_buffer[isb_to_check].data.wid &&
                    // all in-flight instructions have wb==1
                    // RAW
                   (infl_instrs[j].rd == issue_buffer[isb_to_check].data.rs1 || 
                    infl_instrs[j].rd == issue_buffer[isb_to_check].data.rs2 || 
                    infl_instrs[j].rd == issue_buffer[isb_to_check].data.rs3 ||
                    // WAW
                    issue_buffer[isb_to_check].data.wb && infl_instrs[j].rd == issue_buffer[isb_to_check].data.rd)) begin
                    issue_buffer_n[isb_to_check].dependencies[DEPEND_WIS_W'(j+`ISB_INSTRS)] = 1'b1;
                end
            end
            // for isb instructions
            for (integer j = 0; j < `ISB_INSTRS; j++) begin
                //no need to only check previous instructions here
                if (issue_buffer[j].allocated && !issue_buffer[j].issued && issue_buffer[j].data.wid == issue_buffer[isb_to_check].data.wid && isb_to_check != j[ISB_WIS_W-1:0] &&
                    // RAW
                    issue_buffer[j].data.wb &&
                    (issue_buffer[j].data.rd == issue_buffer[isb_to_check].data.rs1 || 
                     issue_buffer[j].data.rd == issue_buffer[isb_to_check].data.rs2 || 
                     issue_buffer[j].data.rd == issue_buffer[isb_to_check].data.rs3 ||
                     // WAW
                     (issue_buffer[isb_to_check].data.wb && issue_buffer[j].data.rd == issue_buffer[isb_to_check].data.rd))) begin
                    issue_buffer_n[isb_to_check].dependencies[j[DEPEND_WIS_W-1:0]] = 1'b1;
                end
                if (issue_buffer[j].allocated && !issue_buffer[j].issued && issue_buffer[j].data.wid == issue_buffer[isb_to_check].data.wid && isb_to_check != j[ISB_WIS_W-1:0] &&
                    // WAR
                   (issue_buffer[isb_to_check].data.wb &&
                    (issue_buffer[j].data.rs1 == issue_buffer[isb_to_check].data.rd || 
                     issue_buffer[j].data.rs2 == issue_buffer[isb_to_check].data.rd || 
                     issue_buffer[j].data.rs3 == issue_buffer[isb_to_check].data.rd))) begin
                     issue_buffer_n[isb_to_check].dependencies[DEPEND_WIS_W'(j)] = 1'b1;
                end
            end
        end


        // ready to issue
        for (integer j = 0; j < `ISB_INSTRS; j++) begin

            if (issue_buffer[j].allocated && !issue_buffer[j].issued && issue_buffer[j].dependencies == 0 && ISB_WIS_W'(j) != isb_to_check) begin
                ready_isb[j] = 1;
                // no reordering for LSU instructions
                for (integer k = 0; k < `ISB_INSTRS; k++) begin
                    if (issue_buffer[k].allocated && !issue_buffer[k].issued && issue_buffer[k].data.wid == issue_buffer[j].data.wid && 
                        ((issue_buffer[k].data.uuid < issue_buffer[j].data.uuid) && (issue_buffer[k].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]!=2'b00 || issue_buffer[j].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]!=2'b11)) ||
                        (issue_buffer[k].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b11 && issue_buffer[j].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b00)) begin
                        if (issue_buffer[k].data.ex_type == `EX_LSU && issue_buffer[j].data.ex_type == `EX_LSU) begin
                            ready_isb[j] = 0;
                        end
                    end
                end
            end

            if (issue_buffer[j].allocated && !issue_buffer[j].issued) begin
                low_uuid_isb[j] = 1;                
                for (integer k = 0; k < `ISB_INSTRS; k++) begin
                    if (issue_buffer[k].allocated && !issue_buffer[k].issued && issue_buffer[k].data.wid == issue_buffer[j].data.wid && 
                        ((issue_buffer[k].data.uuid < issue_buffer[j].data.uuid) && (issue_buffer[k].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]!=2'b00 || issue_buffer[j].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]!=2'b11)) ||
                        (issue_buffer[k].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b11 && issue_buffer[j].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b00)) begin
                        low_uuid_isb[j] = 0;
                    end
                end
            end
        end

        // instruction issue
        if (instr_buf_valid_in) begin

            // allocate in-flight entry
            if (issue_buffer[isb_to_issue].data.wb) begin
                infl_instrs_n[infl_to_allocate].allocated = 1;
                infl_instrs_n[infl_to_allocate].uuid = issue_buffer[isb_to_issue].data.uuid;
                infl_instrs_n[infl_to_allocate].wid = issue_buffer[isb_to_issue].data.wid;
                infl_instrs_n[infl_to_allocate].rd = issue_buffer[isb_to_issue].data.rd;
            
            `ifdef PERF_ENABLE
                infl_alloc_time_n[infl_to_allocate] = 64'($time);
            `endif
            end

            issue_buffer_n[isb_to_issue].issued = 1;
            isb_to_deallocate_n = isb_to_issue;
            deallocate_isb_n = 1;

            // check again for dependencies with issuing instruction
            for (integer j = 0; j < `ISB_INSTRS; j++) begin
                if (issue_buffer[j].allocated && !issue_buffer[j].issued && issue_buffer[j].dependencies[DEPEND_WIS_W'(isb_to_issue)] && 
                    issue_buffer[j].data.wid == issue_buffer[isb_to_issue].data.wid && isb_to_issue != j[ISB_WIS_W-1:0]) begin
                    
                    issue_buffer_n[j].dependencies[DEPEND_WIS_W'(isb_to_issue)] = 1'b0;

                    if (issue_buffer[isb_to_issue].data.wb &&
                        //RAW
                        (issue_buffer[j].data.rs1 == issue_buffer[isb_to_issue].data.rd || 
                         issue_buffer[j].data.rs2 == issue_buffer[isb_to_issue].data.rd || 
                         issue_buffer[j].data.rs3 == issue_buffer[isb_to_issue].data.rd ||
                         //WAW
                         issue_buffer[j].data.wb && issue_buffer[j].data.rd == issue_buffer[isb_to_issue].data.rd)) begin
                        issue_buffer_n[j].dependencies[DEPEND_WIS_W'(DEPEND_WIS_W'(`ISB_INSTRS) + DEPEND_WIS_W'(infl_to_allocate))] = 1'b1;
                    end else begin 
                        issue_buffer_n[j].dependencies[DEPEND_WIS_W'(DEPEND_WIS_W'(`ISB_INSTRS) + DEPEND_WIS_W'(infl_to_allocate))] = 1'b0;
                    end
               
                end
            end

        end else begin
            isb_to_deallocate_n = isb_to_deallocate;
            deallocate_isb_n = 0;
        end

        // deallocate isb entry
        if (deallocate_isb) begin
            issue_buffer_n[isb_to_deallocate].allocated = 0;
            issue_buffer_n[isb_to_deallocate].issued = 0;
            issue_buffer_n[isb_to_deallocate].data = 0;
            issue_buffer_n[isb_to_deallocate].dependencies = 0;
            `ifdef PERF_ENABLE
                if (issue_buffer[isb_to_deallocate].allocated) begin
                    isb_alloc_period_n[isb_to_deallocate] = 64'($time) - isb_alloc_time[isb_to_deallocate];
                end
            `endif
        end

        if (writeback_interface.valid) begin
            // unset dependencies upon writeback instruction
            for (integer i = 0; i < `ISB_INSTRS; i++) begin
                if (issue_buffer[i].allocated && !issue_buffer[i].issued &&
                    issue_buffer[i].data.wid == writeback_interface.data.wid) begin
                    
                    issue_buffer_n[i].dependencies[DEPEND_WIS_W'(DEPEND_WIS_W'(`ISB_INSTRS) + DEPEND_WIS_W'(writeback_interface.data.infl_id))] = 1'b0;
                end
            end
            infl_to_deallocate_n = writeback_interface.data.infl_id;
            deallocate_infl_n = 1;
        end

        // deallocate infl entry
        if (deallocate_infl) begin
            infl_instrs_n[infl_to_deallocate].allocated = 0;
            infl_instrs_n[infl_to_deallocate].uuid = 0;
            infl_instrs_n[infl_to_deallocate].wid = 0;
            infl_instrs_n[infl_to_deallocate].rd = 0;
        `ifdef PERF_ENABLE
            infl_alloc_period_n[infl_to_deallocate] = 64'($time) - infl_alloc_time[infl_to_deallocate];
        `endif
        end

    end


    always @(posedge clk) begin
        if (reset) begin
            previous_uuid <= -1;
            previous_wid <= 0;
            uuid_overflow <= 0;
            decode_ready <= 1;
            check_dependencies <= 0;
            deallocate_isb <= 0;
            deallocate_infl <= 0;
            for (integer i = 0; i < `ISB_INSTRS; i++) begin
                issue_buffer[i].allocated <= 0;
                issue_buffer[i].issued <= 0;
                issue_buffer[i].data <= 0;
                issue_buffer[i].dependencies <= 0;
            end
            for (integer i = 0; i < `INFL_INSTRS; i++) begin
                infl_instrs[i].allocated <= 0;
                infl_instrs[i].uuid <= 0;
                infl_instrs[i].wid <= 0;
                infl_instrs[i].rd <= 0;
            end
        `ifdef PERF_ENABLE
            perf_noisb_stalls <= 0;
            perf_reorders <= 0;
            perf_isb_util <= 0;
            perf_isb_alloc_period <= 0;
            perf_infl_util <= 0;
            perf_infl_alloc_period <= 0;
            for (integer k = 1; k < 16; k = k + 1) begin
                    perf_reorder_distances[k] <= 0;
                end
                for (integer k = 0; k < `ISB_INSTRS; k = k + 1) begin
                    isb_alloc_time[k] <= 0;
                    isb_alloc_period[k] <= 0;
                end
                for (integer k = 0; k < `INFL_INSTRS; k = k + 1) begin
                    infl_alloc_time[k] <= 0;
                    infl_alloc_period[k] <= 0;
                end
        `endif
        end else begin
            issue_buffer <= issue_buffer_n;
            infl_instrs <= infl_instrs_n;
            previous_uuid <= previous_uuid_n;
            previous_wid <= previous_wid_n;
            uuid_overflow <= uuid_overflow_n;
            decode_ready <= decode_ready_n;
            check_dependencies <= check_dependencies_n;
            deallocate_isb <= deallocate_isb_n;
            deallocate_infl <= deallocate_infl_n;
        `ifdef PERF_ENABLE
            perf_noisb_stalls <= perf_noisb_stalls + `PERF_CTR_BITS'(noisb_stall);
            perf_reorders <= perf_reorders + `PERF_CTR_BITS'(reorder);

            if (reorder) begin
                perf_reorder_distances[reorder_distance] <= perf_reorder_distances[reorder_distance] + 1;
            end

            perf_isb_util <= perf_isb_util + `PERF_CTR_BITS'(isb_util);
            perf_infl_util <= perf_infl_util + `PERF_CTR_BITS'(infl_util);

            isb_alloc_period <= isb_alloc_period_n;
            isb_alloc_time <= isb_alloc_time_n;
            if (deallocate_isb) begin
                perf_isb_alloc_period <= perf_isb_alloc_period + 64'(isb_alloc_period_n[isb_to_deallocate]);
            end else begin
                perf_isb_alloc_period <= perf_isb_alloc_period;
            end

            infl_alloc_period <= infl_alloc_period_n;
            infl_alloc_time <= infl_alloc_time_n;
            if (deallocate_infl) begin
                perf_infl_alloc_period <= perf_infl_alloc_period + 64'(infl_alloc_period_n[infl_to_deallocate]);
            end else begin
                perf_infl_alloc_period <= perf_infl_alloc_period;
            end
        `endif
        end
        isb_to_check <= isb_to_check_n;
        isb_to_deallocate <= isb_to_deallocate_n;
        infl_to_deallocate <= infl_to_deallocate_n;
    end

    assign decode_if.ready = decode_ready;

    // for selecting an isb entry to allocate
    VX_lzc #(
        .N       (`ISB_INSTRS),
        .REVERSE (1)
    ) allocate_isb_select (
        .data_in   (empty_isb),
        .data_out  (isb_to_allocate),
        .valid_out (allocate_isb_valid)
    );

    // for selecting an isb instruction to issue (1)
    VX_lzc #(
        .N       (`ISB_INSTRS),
        .REVERSE (1)
    ) issue_isb_select_1 (
        .data_in   (ready_isb),
        .data_out  (isb_to_issue_1),
        .valid_out (issue_isb_valid_1)
    );

    // for selecting an isb instruction to issue (2)
    VX_lzc #(
        .N       (`ISB_INSTRS),
        .REVERSE (1)
    ) issue_isb_select_2 (
        .data_in   (low_uuid_isb),
        .data_out  (isb_to_issue_2),
        .valid_out (issue_isb_valid_2)
    );

    // for selecting an infl entry to allocate
    VX_lzc #(
        .N       (`INFL_INSTRS),
        .REVERSE (1)
    ) allocate_infl_select (
        .data_in   (empty_infl),
        .data_out  (infl_to_allocate),
        .valid_out (allocate_infl_valid)
    );


    always @(*) begin
        uuid_overflow_n = 1'b0;
    `ifdef PERF_ENABLE
        reorder = 0;
        reorder_distance = 0;
        isb_util = 0;
        infl_util = 0;
    `endif

        for (integer i = 0; i < `ISB_INSTRS; i++) begin
            if ($time>610 && decode_if.valid && (issue_buffer[i].data.wid == decode_if.data.wid) && (decode_if.data.uuid==`UUID_WIDTH'(-1)) && (issue_buffer[i].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]!=2'b11)) begin
                uuid_overflow_n = 1'b1;
                `ifdef DBG_TRACE_PIPELINE 
                    `TRACE(1, ("%d: uuid overflow detected: decode (PC=0x%h wid=%d) (#%0d), isb %d (PC=0x%h wid=%d) (#%0d)\n", $time, {decode_if.data.PC, 1'd0}, decode_if.data.wid, decode_if.data.uuid, i, {issue_buffer[i].data.PC, 1'd0}, issue_buffer[i].data.wid, issue_buffer[i].data.uuid));
                `endif
            end else if ($time>610 && decode_if.valid && (issue_buffer[i].data.wid == decode_if.data.wid) && (decode_if.data.uuid==`UUID_WIDTH'(63)) && (issue_buffer[i].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]!=2'b00)) begin
                uuid_overflow_n = 1'b1;
                `ifdef DBG_TRACE_PIPELINE 
                    `TRACE(1, ("%d: uuid overflow detected: decode (PC=0x%h wid=%d) (#%0d), isb %d (PC=0x%h wid=%d) (#%0d)\n", $time, {decode_if.data.PC, 1'd0}, decode_if.data.wid, decode_if.data.uuid, i, {issue_buffer[i].data.PC, 1'd0}, issue_buffer[i].data.wid, issue_buffer[i].data.uuid));
                `endif
            end
        end
    
    `ifdef PERF_ENABLE
        for (integer j = 0; j < `ISB_INSTRS; j++) begin
            if (issue_buffer[j].allocated && $time>610 && instr_buf_valid_in && j[ISB_WIS_W-1:0] != isb_to_issue && 
                issue_buffer[j].data.wid == issue_buffer[isb_to_issue].data.wid && 
                ((issue_buffer[j].data.uuid < issue_buffer[isb_to_issue].data.uuid && 
                !(issue_buffer[j].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b00 && issue_buffer[isb_to_issue].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b11)) 
                || (issue_buffer[j].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b11 && issue_buffer[isb_to_issue].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b00))) begin
                reorder = 1;
                if (issue_buffer[j].data.uuid < issue_buffer[isb_to_issue].data.uuid && 
                !(issue_buffer[j].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b00 && issue_buffer[isb_to_issue].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b11)) begin
                    if ((5'(issue_buffer[isb_to_issue].data.uuid - issue_buffer[j].data.uuid) > 5'(reorder_distance)) && (5'(issue_buffer[isb_to_issue].data.uuid - issue_buffer[j].data.uuid) < 16)) begin
                        reorder_distance = 4'(issue_buffer[isb_to_issue].data.uuid - issue_buffer[j].data.uuid);
                    end
                end else if (issue_buffer[j].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b11 && issue_buffer[isb_to_issue].data.uuid[`UUID_WIDTH-1:`UUID_WIDTH-2]==2'b00) begin
                    if (5'(`UUID_WIDTH'(-1) - issue_buffer[j].data.uuid + issue_buffer[isb_to_issue].data.uuid) > 5'(reorder_distance) && 5'(`UUID_WIDTH'(-1) - issue_buffer[j].data.uuid + issue_buffer[isb_to_issue].data.uuid) < 16) begin
                        reorder_distance = 4'(`UUID_WIDTH'(-1) - issue_buffer[j].data.uuid + issue_buffer[isb_to_issue].data.uuid);
                    end
                end
            end

            if (issue_buffer[j].allocated == 1) begin
                isb_util = isb_util + 1;
            end
        end

        for (integer j = 0; j < `INFL_INSTRS; j++) begin
            if (infl_instrs[j].allocated == 1) begin
                infl_util = infl_util + 1;
            end
        end
    `endif
    end

`ifdef PERF_ENABLE
    assign noisb_stall = (allocate_isb_valid==0) && (check_dependencies_n==0);
`endif

    wire [`NUM_WARPS-1:0] ibuf_ready_in;
    wire [ISB_WIS_W-1:0] isb_to_issue;
    wire issue_isb_valid;
    assign isb_to_issue = issue_isb_valid_1 ? isb_to_issue_1 : isb_to_issue_2;
    assign issue_isb_valid = issue_isb_valid_1 || issue_isb_valid_2;

    wire instr_buf_valid_in;
    assign instr_buf_valid_in = issue_isb_valid && ibuf_ready_in[issue_buffer[isb_to_issue].data.wid] && (allocate_infl_valid || !issue_buffer[isb_to_issue].data.wb);

    for (genvar i = 0; i < `NUM_WARPS; ++i) begin
        VX_elastic_buffer #(
            .DATAW   (DATAW),
            .SIZE    (`IBUF_SIZE),
            .OUT_REG (2) // use a 2-cycle FIFO
        ) instr_buf (
            .clk      (clk),
            .reset    (reset),
            .valid_in (instr_buf_valid_in && issue_buffer[isb_to_issue].data.wid == i),
            .data_in  ({
                issue_buffer[isb_to_issue].data.uuid,
                issue_buffer[isb_to_issue].data.tmask,
                issue_buffer[isb_to_issue].data.PC,
                issue_buffer[isb_to_issue].data.ex_type,
                issue_buffer[isb_to_issue].data.op_type,
                issue_buffer[isb_to_issue].data.op_args,
                issue_buffer[isb_to_issue].data.wb,
                issue_buffer[isb_to_issue].data.rd,
                issue_buffer[isb_to_issue].data.rs1,
                issue_buffer[isb_to_issue].data.rs2,
                issue_buffer[isb_to_issue].data.rs3,
                infl_to_allocate
                }),
            .ready_in (ibuf_ready_in[i]),
            .valid_out(ibuffer_if[i].valid),
            .data_out (ibuffer_if[i].data),
            .ready_out(ibuffer_if[i].ready)
        );
    `ifndef L1_ENABLE
        assign decode_if.ibuf_pop[i] = ibuffer_if[i].valid && ibuffer_if[i].ready;
    `endif
    end

    // writeback 
    for (genvar i = 0; i < `ISSUE_WIDTH; ++i) begin
        always @(*) begin
            if (writeback_if[i].valid) begin
                writeback_interface.data.wid = wis_to_wid(writeback_if[i].data.wis, i);
                writeback_interface.data.infl_id = writeback_if[i].data.infl_id;
                writeback_interface.valid = writeback_if[i].valid && writeback_if[i].data.eop;
                writeback_interface.data.uuid = writeback_if[i].data.uuid;
                writeback_interface.data.PC = writeback_if[i].data.PC;
            end else begin
                writeback_interface.valid = 0;
            end
        end
    end

`ifdef DBG_TRACE_PIPELINE 
    always @(posedge clk) begin
    if ($time > 610) begin
        // decode valid
        if (decode_if.valid) begin
            `TRACE(1, ("%d: decode valid (PC=0x%h wid=%d) (#%0d)\n", $time, {decode_if.data.PC, 1'd0}, decode_if.data.wid, decode_if.data.uuid));
            `TRACE(1, ("%d: empty isb: %b\n\n", $time, empty_isb));
        end

        // allocate isb entry
        if (!uuid_overflow && allocate_isb_valid && ((previous_wid != decode_if.data.wid) || (previous_uuid != decode_if.data.uuid)) && decode_if.valid) begin
            `TRACE(1, ("%d: allocating isb %d (PC=0x%h wid=%d) (#%0d)\n", $time, isb_to_allocate, {decode_if.data.PC, 1'd0}, decode_if.data.wid, decode_if.data.uuid));
            `TRACE(1, ("%d: empty isb: %b\n\n", $time, empty_isb));
        end

        // check dependencies
        if (check_dependencies) begin
            `TRACE(1, ("%d: check dependencies for isb %d (PC=0x%h wid=%d) rs1=%0d, rs2=%0d, rs3=%0d, rd=%0d, wb=%0d (#%0d)\n", $time, isb_to_check, {issue_buffer[isb_to_check].data.PC, 1'd0}, issue_buffer[isb_to_check].data.wid, issue_buffer[isb_to_check].data.rs1, issue_buffer[isb_to_check].data.rs2, issue_buffer[isb_to_check].data.rs3, issue_buffer[isb_to_check].data.rd, issue_buffer[isb_to_check].data.wb, issue_buffer[isb_to_check].data.uuid));
            for (integer j = 0; j < `ISB_INSTRS; j++) begin
                if (issue_buffer[j].allocated && !issue_buffer[j].issued && issue_buffer[j].data.wid == issue_buffer[isb_to_check].data.wid && isb_to_check != j[ISB_WIS_W-1:0]) begin
                    `TRACE(1, ("%d: with isb %d (PC=0x%h wid=%d) rs1=%0d, rs2=%0d, rs3=%0d, rd=%0d, wb=%0d dependency: %b (#%0d)\n", $time, j[ISB_WIS_W-1:0], {issue_buffer[j].data.PC, 1'd0}, issue_buffer[j].data.wid, issue_buffer[j].data.rs1, issue_buffer[j].data.rs2, issue_buffer[j].data.rs3, issue_buffer[j].data.rd, issue_buffer[j].data.wb, issue_buffer_n[isb_to_check].dependencies[DEPEND_WIS_W'(j)], issue_buffer[j].data.uuid));
                end
            end
            for (integer j = 0; j < `INFL_INSTRS; j++) begin
                if (infl_instrs[j].allocated && infl_instrs[j].wid == issue_buffer[isb_to_check].data.wid) begin
                    `TRACE(1, ("%d: with infl %d (wid=%d) rd=%0d dependency: %b (#%0d)\n", $time, j[INFL_WIS_W-1:0], issue_buffer[j].data.wid, infl_instrs[j].rd, issue_buffer_n[isb_to_check].dependencies[DEPEND_WIS_W'(j+`ISB_INSTRS)], infl_instrs[j].uuid));
                end
            end
            `TRACE(1, ("%d: isb %d dependencies: %b %b\n\n", $time, isb_to_check, issue_buffer_n[isb_to_check].dependencies[`ISB_INSTRS+`INFL_INSTRS-1:`ISB_INSTRS], issue_buffer_n[isb_to_check].dependencies[`ISB_INSTRS-1:0]));
        end

        // instr_buf_valid_in
        //if (!instr_buf_valid_in) begin
        //    `TRACE(1, ("%d: issue_isb_valid = %0d, wid = %0d, ibuf_ready_in[%d] = %d, allocate_infl_valid = %0d, wb = %0d\n\n", $time, issue_isb_valid, issue_buffer[isb_to_issue].data.wid, issue_buffer[isb_to_issue].data.wid, ibuf_ready_in[issue_buffer[isb_to_issue].data.wid], allocate_infl_valid, issue_buffer[isb_to_issue].data.wb));
        //end

        // issue isb entry
        if (instr_buf_valid_in) begin
            `TRACE(1, ("%d: ready isb %b, low uuid isb %b\n", $time, ready_isb, low_uuid_isb));
            `TRACE(1, ("%d: issue isb %d (PC=0x%h wid=%d) (#%0d)\n", $time, isb_to_issue, {issue_buffer[isb_to_issue].data.PC, 1'd0}, issue_buffer[isb_to_issue].data.wid, issue_buffer[isb_to_issue].data.uuid));
            if (issue_isb_valid_1) begin
                `TRACE(1, ("%d: issue isb with no dependencies, isb %d dependencies: %b %b\n", $time, isb_to_issue, issue_buffer[isb_to_issue].dependencies[`ISB_INSTRS+`INFL_INSTRS-1:`ISB_INSTRS], issue_buffer[isb_to_issue].dependencies[`ISB_INSTRS-1:0]));
            end else begin
                `TRACE(1, ("%d: issue isb with dependencies, isb %d dependencies: %b %b\n", $time, isb_to_issue, issue_buffer[isb_to_issue].dependencies[`ISB_INSTRS+`INFL_INSTRS-1:`ISB_INSTRS], issue_buffer[isb_to_issue].dependencies[`ISB_INSTRS-1:0]));
            end
            if (issue_buffer[isb_to_issue].data.wb) begin
                `TRACE(1, ("%d: allocating infl_id = %d\n\n", $time, infl_to_allocate));
            end

            `TRACE(1, ("%d: check again depend. with issue isb %d (PC=0x%h wid=%d) rs1=%0d, rs2=%0d, rs3=%0d, rd=%0d, wb=%0d (#%0d)\n", $time, isb_to_issue, {issue_buffer[isb_to_issue].data.PC, 1'd0}, issue_buffer[isb_to_issue].data.wid, issue_buffer[isb_to_issue].data.rs1, issue_buffer[isb_to_issue].data.rs2, issue_buffer[isb_to_issue].data.rs3, issue_buffer[isb_to_issue].data.rd, issue_buffer[isb_to_issue].data.wb, issue_buffer[isb_to_issue].data.uuid));
            for (integer j = 0; j < `ISB_INSTRS; j++) begin
                if (issue_buffer[j].allocated && !issue_buffer[j].issued && issue_buffer[j].data.wid == issue_buffer[isb_to_issue].data.wid && isb_to_issue != j[ISB_WIS_W-1:0]) begin
                    `TRACE(1, ("%d: isb %d (PC=0x%h wid=%d) rs1=%0d, rs2=%0d, rs3=%0d, rd=%0d, wb=%0d dependency: %b (#%0d)\n", $time, j[ISB_WIS_W-1:0], {issue_buffer[j].data.PC, 1'd0}, issue_buffer[j].data.wid, issue_buffer[j].data.rs1, issue_buffer[j].data.rs2, issue_buffer[j].data.rs3, issue_buffer[j].data.rd, issue_buffer[j].data.wb, issue_buffer_n[j].dependencies[DEPEND_WIS_W'(j)], issue_buffer[j].data.uuid));
                    `TRACE(1, ("%d: isb %d dependencies: %b %b\n", $time, j[ISB_WIS_W-1:0], issue_buffer_n[j].dependencies[`ISB_INSTRS+`INFL_INSTRS-1:`ISB_INSTRS], issue_buffer_n[j].dependencies[`ISB_INSTRS-1:0]));
                end
            end
        end

        // deallocate isb entry
        if (deallocate_isb) begin
            `TRACE(1, ("%d: deallocating isb %d (PC=0x%h wid=%d) (#%0d), wb=%d\n", $time, isb_to_deallocate, {issue_buffer[isb_to_deallocate].data.PC, 1'd0}, issue_buffer[isb_to_deallocate].data.wid, issue_buffer[isb_to_deallocate].data.uuid, issue_buffer[isb_to_deallocate].data.wb));
            `TRACE(1, ("%d: empty isb: %b\n\n", $time, empty_isb));
        end

        // allocate infl entry
        if (allocate_infl_valid) begin
            `TRACE(1, ("%d: allocating infl %d (PC=0x%h wid=%d) (#%0d)\n", $time, infl_to_allocate, {issue_buffer[isb_to_issue].data.PC, 1'd0}, issue_buffer[isb_to_issue].data.wid, issue_buffer[isb_to_issue].data.uuid));
            `TRACE(1, ("%d: empty infl: %b\n\n", $time, empty_infl));
        end

        // writeback
        
        if (writeback_if[0].valid) begin
            `TRACE(1, ("%d: writeback infl %d (PC=0x%h wid=%d) eop=%d (#%0d)\n", $time, writeback_if[0].data.infl_id, {writeback_if[0].data.PC, 1'd0}, wis_to_wid(writeback_if[0].data.wis,0), writeback_if[0].data.eop, writeback_if[0].data.uuid));
        end
        if (writeback_interface.valid) begin
            `TRACE(1, ("%d: writeback infl %d (PC=0x%h wid=%d) (#%0d)\n\n", $time, writeback_interface.data.infl_id, {writeback_interface.data.PC, 1'd0}, writeback_interface.data.wid, writeback_interface.data.uuid));
        end

        // deallocate infl entry
        if (deallocate_infl) begin
            `TRACE(1, ("%d: deallocating infl %d (wid=%d) (#%0d)\n", $time, infl_to_deallocate, issue_buffer[isb_to_issue].data.wid, infl_instrs[infl_to_deallocate].uuid));
            `TRACE(1, ("%d: empty infl: %b\n\n", $time, empty_infl));
        end
    end
    end 
`endif


endmodule
