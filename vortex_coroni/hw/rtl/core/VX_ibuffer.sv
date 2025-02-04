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

    // inputs
    VX_decode_if.slave  decode_if,

    // outputs
    VX_ibuffer_if.master ibuffer_if [`ISSUE_WIDTH]
);
    `UNUSED_PARAM (CORE_ID)
    localparam DATAW = ISSUE_WIS_W +`UUID_WIDTH + `NUM_THREADS + `PC_BITS + 1 + `EX_BITS + `INST_OP_BITS + `INST_ARGS_BITS + (`NR_BITS * 4);

    wire [`ISSUE_WIDTH-1:0] ibuf_ready_in;
    wire [ISSUE_WIS_W-1:0] ibuffer_wis;
    wire [ISSUE_ISW_W-1:0] ibuffer_isw;

    assign decode_if.ready = ibuf_ready_in[ibuffer_isw];

    for (genvar i = 0; i < `ISSUE_WIDTH; ++i) begin
    assign ibuffer_wis = wid_to_wis(decode_if.data.wid);
    assign ibuffer_isw = wid_to_isw(decode_if.data.wid);

        VX_elastic_buffer #(
            .DATAW   (DATAW),
            .SIZE    (`IBUF_SIZE),
            .OUT_REG (2) // use a 2-cycle FIFO
        ) instr_buf (
            .clk      (clk),
            .reset    (reset),
            .valid_in (decode_if.valid && ibuffer_isw == i),
            .data_in  ({
                decode_if.data.uuid,
                ibuffer_wis,
                decode_if.data.tmask,
                decode_if.data.PC,
                decode_if.data.ex_type,
                decode_if.data.op_type,
                decode_if.data.op_args,
                decode_if.data.wb,
                decode_if.data.rd,
                decode_if.data.rs1,
                decode_if.data.rs2,
                decode_if.data.rs3}),
            .ready_in (ibuf_ready_in[i]),
            .valid_out(ibuffer_if[i].valid),
            .data_out (ibuffer_if[i].data),
            .ready_out(ibuffer_if[i].ready)
        );
    `ifndef L1_ENABLE
        assign decode_if.ibuf_pop[i] = ibuffer_if[i].valid && ibuffer_if[i].ready;
    `endif
    end

//`ifdef DBG_TRACE_PIPELINE 
//    always @(posedge clk) begin
//        $display("%d: decode valid= %d for warp: %d, instr pc : 0x%h", $time, decode_if.valid, decode_if.data.wid, decode_if.data.PC);
//        $display("%d: ibuf ready: %d", $time, ibuf_ready_in);
//    end 
//`endif


endmodule
