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

interface VX_pipeline_perf_if ();
    wire [`PERF_CTR_BITS-1:0] sched_idles;
    wire [`PERF_CTR_BITS-1:0] sched_stalls;
    wire [`PERF_CTR_BITS-1:0] ibf_stalls;
    //wire [`PERF_CTR_BITS-1:0] scb_stalls;
    //wire [`PERF_CTR_BITS-1:0] units_uses [`NUM_EX_UNITS];
    //wire [`PERF_CTR_BITS-1:0] sfu_uses [`NUM_SFU_UNITS];
    wire [`PERF_CTR_BITS-1:0] nocu_stalls;
    wire [`PERF_CTR_BITS-1:0] rf_reads;
    wire [`PERF_CTR_BITS-1:0] rf_writes;
    wire [`PERF_CTR_BITS-1:0] reorders;
    wire [`PERF_CTR_BITS-1:0] reorder_distances[15:1];
    wire [`PERF_CTR_BITS-1:0] cu_util;
    wire [64-1:0] cu_alloc_period;
    wire [`PERF_CTR_BITS-1:0] ifetches;
    wire [`PERF_CTR_BITS-1:0] loads;
    wire [`PERF_CTR_BITS-1:0] stores;    
    wire [`PERF_CTR_BITS-1:0] ifetch_latency;
    wire [`PERF_CTR_BITS-1:0] load_latency;

    modport schedule (
        output sched_idles,
        output sched_stalls        
    );

    modport issue (
        output ibf_stalls,
        output nocu_stalls,
        output rf_reads,
        output rf_writes,
        output reorders,
        output reorder_distances,
        output cu_util,
        output cu_alloc_period
        //output scb_stalls,
        //output units_uses,
        //output sfu_uses
    );

    modport slave (
        input sched_idles,
        input sched_stalls,
        input ibf_stalls,
        input nocu_stalls,
        input rf_reads,
        input rf_writes,
        input reorders,
        input reorder_distances,
        input cu_util,
        input cu_alloc_period,
        //input scb_stalls,
        //input units_uses,
        //input sfu_uses,
        input ifetches,
        input loads,
        input stores,
        input ifetch_latency,
        input load_latency
    );

endinterface
