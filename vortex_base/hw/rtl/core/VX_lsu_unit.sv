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

module VX_lsu_unit import VX_gpu_pkg::*; #(
    parameter CORE_ID = 0
) (    
    `SCOPE_IO_DECL

    input wire              clk,
    input wire              reset,

    // Inputs
    VX_dispatch_if.slave    dispatch_if [`ISSUE_WIDTH],

    // Outputs    
    VX_commit_if.master     commit_if [`ISSUE_WIDTH],
    VX_lsu_mem_if.master    lsu_mem_if [`NUM_LSU_BLOCKS]
);
    localparam BLOCK_SIZE = `NUM_LSU_BLOCKS;
    localparam NUM_LANES  = `NUM_LSU_LANES;

`ifdef SCOPE
    localparam scope_lsu = 0;
    `SCOPE_IO_SWITCH (BLOCK_SIZE);
`endif
    
    VX_execute_if #(
        .NUM_LANES (NUM_LANES)
    ) per_block_execute_if[BLOCK_SIZE]();

    VX_dispatch_unit #(
        .BLOCK_SIZE (BLOCK_SIZE),
        .NUM_LANES  (NUM_LANES),
        .OUT_BUF    (1)
    ) dispatch_unit (
        .clk        (clk),
        .reset      (reset),
        .dispatch_if(dispatch_if),
        .execute_if (per_block_execute_if)
    );

    VX_commit_if #(
        .NUM_LANES (NUM_LANES)
    ) per_block_commit_if[BLOCK_SIZE]();

    for (genvar block_idx = 0; block_idx < BLOCK_SIZE; ++block_idx) begin

        `RESET_RELAY (block_reset, reset);

        VX_lsu_slice #(
            .CORE_ID  (CORE_ID),
            .BLOCK_ID (block_idx)
        ) lsu_slice(
            `SCOPE_IO_BIND  (scope_lsu+block_idx)
            .clk        (clk),
            .reset      (block_reset),
            .execute_if (per_block_execute_if[block_idx]),
            .commit_if  (per_block_commit_if[block_idx]),
            .lsu_mem_if (lsu_mem_if[block_idx])
        );
    end

    `ifdef DBG_TRACE_METRICS
    for (genvar b = 0; b < BLOCK_SIZE; ++b) begin
        always @(posedge clk) begin
            if ($time == 609) begin
                `TRACE(1, ("%d: LSU BLOCK_SIZE=%0d, NUM_LANES=%0d\n", $time, BLOCK_SIZE, NUM_LANES));
            end
            if (per_block_execute_if[b].valid) begin
                `TRACE(1, ("%d: per block dispatch valid: LSU wid=%0d, PC=0x%0h\n",
                    $time, per_block_execute_if[b].data.wid, per_block_execute_if[b].data.PC));
            end
            if (per_block_commit_if[b].valid) begin
                `TRACE(1, ("%d: per block commit valid: LSU wid=%0d, PC=0x%0h\n",
                    $time, per_block_commit_if[b].data.wid, per_block_commit_if[b].data.PC));
            end
        end
    end
    `endif
    
    VX_gather_unit #(
        .BLOCK_SIZE (BLOCK_SIZE),
        .NUM_LANES  (NUM_LANES),
        .OUT_BUF    (3)
    ) gather_unit (
        .clk           (clk),
        .reset         (reset),
        .commit_in_if  (per_block_commit_if),
        .commit_out_if (commit_if)
    );
    
endmodule
