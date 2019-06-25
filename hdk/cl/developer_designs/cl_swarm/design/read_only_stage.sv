import swarm::*;

module read_only_stage
#(
   parameter TILE_ID=1
) (
   input clk,
   input rstn,

   input logic           [N_SUB_TYPES-1:0]  task_in_valid,
   output logic          [N_SUB_TYPES-1:0]  task_in_ready,
   input task_t          [N_SUB_TYPES-1:0]  in_task, 
   input data_t          [N_SUB_TYPES-1:0]  in_data, 
   input cq_slice_slot_t [N_SUB_TYPES-1:0]  in_cq_slot,
   input                 [N_SUB_TYPES-1:0]  in_last,
   
   input  fifo_size_t    [N_SUB_TYPES-1:0]  in_fifo_occ,

   input logic [2**LOG_CQ_SLICE_SIZE-1:0]    task_aborted,
   
   output logic        arvalid,
   input               arready,
   output logic [31:0] araddr,
   output id_t         arid,

   input               rvalid,
   output logic        rready,
   input id_t          rid,
   input logic [511:0] rdata,

   output logic                  out_valid,
   input                         out_ready,
   output task_t                 out_task,
   output subtype_t              out_subtype,
   output cq_slice_slot_t        out_cq_slot,
   output data_t                 out_data,
   output logic                  out_last,
   
   output logic                  child_valid,
   input                         child_ready,
   output task_t                 child_task,
   output logic                  child_untied,
   output cq_slice_slot_t        child_cq_slot,
   output child_id_t             child_id,
  
   output logic                  finish_task_valid,
   input                         finish_task_ready,
   output cq_slice_slot_t        finish_task_slot,
   output child_id_t             finish_task_num_children,


   output logic                  idle, // all threads accounted for
   
   reg_bus_t         reg_bus,
   pci_debug_bus_t   pci_debug
);

localparam FREE_LIST_SIZE = 5;

logic [FREE_LIST_SIZE-1:0] arid_free_list_add;
logic [FREE_LIST_SIZE-1:0] arid_free_list_next;
logic arid_free_list_add_valid;
logic arid_free_list_remove_valid;
logic arid_free_list_empty;

fifo_size_t fifo_out_almost_full_thresh;

thread_id_t thread_free_list_add;
logic thread_free_list_add_valid;
logic thread_free_list_remove_valid;
logic thread_free_list_empty;
   
typedef struct packed {
   thread_id_t       thread;
   logic [15:0]      valid_words;
   logic [2:0]       arsize;
} ro_stage_mshr_t;

ro_stage_mshr_t ro_mshr [0:2**FREE_LIST_SIZE-1];

task_t mem_task [0:N_THREADS-1];
subtype_t mem_subtype [0:N_THREADS-1];
cq_slice_slot_t       mem_cq_slot [0:N_THREADS-1];
logic mem_resp_mark_last [0:N_THREADS-1];

logic [31:0] mem_last_word[0:N_THREADS-1];

typedef logic [7:0] remaining_words_t;
remaining_words_t remaining_words [0:N_THREADS-1];

logic reg_rvalid, reg_rready;
logic [511:0] reg_rdata;
id_t  reg_rid;
ro_stage_mshr_t rid_mshr;

logic [15:0] next_valid_words;

logic [N_SUB_TYPES-1:0] s_arvalid;
logic [31:0] s_araddr [N_SUB_TYPES-1:0];
logic [2:0] s_arsize [N_SUB_TYPES-1:0];
byte_t [N_SUB_TYPES-1:0] s_arlen;
task_t s_resp_task [N_SUB_TYPES-1:0];
subtype_t s_resp_subtype [N_SUB_TYPES-1:0];
logic [N_SUB_TYPES-1:0] s_resp_mark_last;
task_t s_out_task [N_SUB_TYPES-1:0];
logic [N_SUB_TYPES-1:0] s_out_valid;
subtype_t s_out_subtype [N_SUB_TYPES-1:0];
logic [N_SUB_TYPES-1:0] s_out_task_is_child;

logic reg_arvalid;
logic [31:0] reg_araddr;
thread_id_t           reg_thread;
logic [2:0] reg_arsize; 
logic [7:0] reg_n_words;

logic last_read_in_burst;

logic s_finish_task_valid, s_finish_task_ready;
logic s_arready;
logic s_out_ready;

logic [N_SUB_TYPES-1:0] s_sched_task_valid;
logic [N_SUB_TYPES-1:0] s_sched_task_ready;
logic [N_SUB_TYPES-1:0] s_sched_task_aborted;

ro_stage_mshr_t write_mshr; 

// TODO sizes other than 64
logic [31:0] out_data_word_0;
logic [31:0] out_data_word_1;
logic out_data_word_0_valid;
logic out_data_word_1_valid;
thread_id_t rid_thread;

thread_id_t in_thread;

logic         mem_access_subtype_valid;
subtype_t     mem_access_subtype;
logic         non_mem_subtype_valid;
subtype_t     non_mem_subtype;

logic [N_SUB_TYPES-1:0] task_in_can_schedule;

cq_slice_slot_t s_finish_task_slot; 
child_id_t      s_finish_task_num_children;

cq_slice_slot_t mem_access_cq_slot;
cq_slice_slot_t non_mem_cq_slot;

always_comb begin
   mem_access_cq_slot = in_cq_slot[mem_access_subtype];
   non_mem_cq_slot = in_cq_slot[non_mem_subtype];
end

genvar i;
generate
   for (i=0;i<N_SUB_TYPES-1;i++) begin
      assign task_in_can_schedule[i] = task_in_valid[i] & (in_fifo_occ[i+1] < fifo_out_almost_full_thresh);
   end
endgenerate
assign task_in_can_schedule[N_SUB_TYPES-1] = task_in_valid[N_SUB_TYPES-1];



// Memory Request

free_list #(
   .LOG_DEPTH(FREE_LIST_SIZE)
) FREE_LIST_ARID  (
   .clk(clk),
   .rstn(rstn),

   .wr_en(arid_free_list_add_valid),
   .rd_en(arid_free_list_remove_valid),
   .wr_data(arid_free_list_add),

   .full(), 
   .empty(arid_free_list_empty),
   .rd_data(arid_free_list_next),

   .size()
);

logic [3:0] ar_read_words; // number of set bits in valid_words[]
always_ff @(posedge clk) begin
   if (!rstn) begin
      reg_arvalid <= 1'b0;
      reg_araddr <= 'x;
      reg_arsize <= 'x;
   end else begin
      if (mem_access_subtype_valid & s_arready) begin
         reg_arvalid <= 1'b1;
         reg_araddr <= s_araddr[mem_access_subtype];
         reg_arsize <= s_arsize[mem_access_subtype];
         reg_thread <= in_thread;
         mem_task[in_thread] <= s_resp_task[mem_access_subtype];
         mem_subtype[in_thread] <= s_resp_subtype[mem_access_subtype];
         mem_cq_slot[in_thread] <= mem_access_cq_slot;
         mem_resp_mark_last[in_thread] <= s_resp_mark_last[mem_access_subtype];
         case (s_arsize[mem_access_subtype]) 
           2: reg_n_words <= (s_arlen[mem_access_subtype] + 1);
           3: reg_n_words <= (s_arlen[mem_access_subtype] + 1) << 1;
           // TODO
         endcase
      end else if (reg_arvalid) begin
         if (arvalid & arready) begin
            if (!last_read_in_burst) begin
               reg_araddr <= reg_araddr + (ar_read_words * 4); 
               reg_n_words <= reg_n_words - ar_read_words;
            end else begin
               reg_arvalid <= 1'b0;
            end
         end
      end

   end
end

assign thread_free_list_remove_valid = mem_access_subtype_valid; 

generate 
   for (i=0;i<16;i++) begin
      assign write_mshr.valid_words[i] = (i >= reg_araddr[5:2]) & (i <  (reg_araddr[5:2] + reg_n_words));
   end
endgenerate
assign write_mshr.thread = reg_thread;
assign write_mshr.arsize = reg_arsize;

assign araddr = reg_araddr;
assign arvalid = reg_arvalid & !arid_free_list_empty;
assign arid =  arid_free_list_next;
assign s_arready = !thread_free_list_empty & ( !reg_arvalid | (arvalid & arready & last_read_in_burst) );
assign last_read_in_burst = ((reg_araddr[5:2] + reg_n_words) <= 16);
// if the number of words remaining in the cache line is greater than number of
// words requested..
assign ar_read_words = ( (16- reg_araddr[5:2])  > reg_n_words) ? reg_n_words : (16 - reg_araddr[5:2]);

always_ff @(posedge clk) begin
   if (arvalid & arready) begin
     ro_mshr[arid_free_list_next] <= write_mshr;
   end
end
assign arid_free_list_remove_valid = (arvalid & arready);

// Memory Response
logic [31:0] out_data_word_from_mem;
logic is_last_resp;
logic [3:0] out_data_word_id;

always_comb begin
   next_valid_words = rid_mshr.valid_words;
   for (int j=0;j<16;j++) begin
      if (out_data_word_0_valid & (j == out_data_word_id)) begin
         next_valid_words[j] = 1'b0;
      end else if (out_data_word_1_valid & (j== (out_data_word_id + 1))) begin
         next_valid_words[j] = 1'b0;
      end
   end
end

assign rready = !reg_rvalid;
always_ff @(posedge clk) begin
   if (!rstn) begin
      reg_rvalid <= 1'b0;
   end else begin
      if (rvalid & rready) begin
         rid_mshr <= ro_mshr[rid[FREE_LIST_SIZE-1:0]];
         rid_thread <= ro_mshr[rid[FREE_LIST_SIZE-1:0]].thread;
         reg_rid <= rid;
         reg_rvalid <= rvalid;
         reg_rdata <= rdata;
      end else begin
         if (reg_rvalid) begin
            if ( (out_valid & out_ready) | (!out_valid & next_valid_words == 0)) begin
               rid_mshr.valid_words <= next_valid_words;
               if (next_valid_words == 0) begin
                  reg_rvalid <= 1'b0;
               end
            end
         end
      end
   end
end

generate
   for (i=0;i<N_THREADS;i++) begin
      always_ff @(posedge clk) begin
         if (!rstn) begin
            remaining_words[i] <= 0;
         end else begin
            if (mem_access_subtype_valid & s_arready & (in_thread == i)) begin
               case (s_arsize[mem_access_subtype]) 
                 3'd2: remaining_words[i] <= (s_arlen[mem_access_subtype] + 1);
                 3'd3: remaining_words[i] <= (s_arlen[mem_access_subtype] + 1) << 1;
                 default: remaining_words[i] <= remaining_words[i];
               endcase
            end else if (reg_rvalid & ( i == rid_thread)) begin
               if (out_valid) begin
                  if (out_ready & out_data_word_0_valid & out_data_word_1_valid) begin
                     remaining_words[i] <= remaining_words[i] -2;
                  end
               end else if (out_data_word_0_valid | out_data_word_1_valid) begin
                  remaining_words[i] <= remaining_words[i] -1;
               end
            end
         end

      end
   end

endgenerate

assign arid_free_list_add_valid = rvalid & rready;
assign arid_free_list_add = rid[7:0];
assign thread_free_list_add_valid = is_last_resp & (out_valid & out_ready);
assign thread_free_list_add = rid_thread;


remaining_words_t remaining_words_cur_rid;
always_comb begin
   remaining_words_cur_rid = remaining_words[rid_thread];
end

always_ff @(posedge clk) begin
   if (reg_rvalid) begin
      mem_last_word[rid_thread] <= out_data_word_0; 
   end
end

logic [$clog2(N_THREADS):0] thread_free_list_occ;


// out task

child_id_t num_children [0:2**LOG_CQ_SLICE_SIZE-1];

   lowbit #(
      .OUT_WIDTH(4),
      .IN_WIDTH(16)   
   ) VALID_WORD  (
      .in(rid_mshr.valid_words),
      .out(out_data_word_id)
   );

always_comb begin 
   out_data_word_0 = reg_rdata[ out_data_word_id * 32 +: 32]; 
   out_data_word_1 = reg_rdata[ (out_data_word_id + 1) * 32 +: 32]; 
   out_data_word_0_valid = rid_mshr.valid_words[out_data_word_id];
   out_data_word_1_valid = (out_data_word_id < 15) & rid_mshr.valid_words[out_data_word_id + 1];
   out_data_word_from_mem = mem_last_word[rid_thread];
end

always_comb begin
   out_task = mem_task[rid_thread]; 
   out_cq_slot = mem_cq_slot[rid_thread]; 
   out_subtype = mem_subtype[rid_thread];
   out_data = 'x;
   out_valid = 1'b0;
   is_last_resp = 1'b0;
   if (reg_rvalid) begin
      if (out_data_word_0_valid && out_data_word_1_valid) begin
         out_data[31: 0] = out_data_word_0;
         out_data[63:32] = out_data_word_1;
         out_valid = 1'b1;
         is_last_resp = (remaining_words_cur_rid == 2);
      end else if (out_data_word_id == 0) begin
         out_data[31: 0] = out_data_word_from_mem ;
         out_data[63:32] = out_data_word_0; 
         out_valid = (remaining_words_cur_rid == 1);
         is_last_resp = (remaining_words_cur_rid == 1);
      end else if (out_data_word_id == 15) begin
         out_data[31: 0] = out_data_word_0; 
         out_data[63:32] = out_data_word_from_mem ;
         out_valid = (remaining_words_cur_rid == 1);
         is_last_resp = (remaining_words_cur_rid == 1);
      end 
   end
   out_last = is_last_resp & mem_resp_mark_last[rid_thread];
end

logic s_child_valid;
always_comb begin
   assign s_child_valid = non_mem_subtype_valid & s_out_valid[non_mem_subtype] & s_out_task_is_child[non_mem_subtype];
end

always_ff @(posedge clk) begin
   if (!rstn) begin
      child_valid <= 1'b0;
      child_task <= 'x;
   end else begin
      if (s_child_valid & s_out_ready) begin
         child_valid <= 1'b1;
         child_task <= s_out_task[non_mem_subtype];
         child_cq_slot <= non_mem_cq_slot;
         child_id <= num_children[non_mem_cq_slot];
      end else if (child_valid & child_ready) begin
         child_valid <= 1'b0;
      end
   end
end
assign child_untied = 1'b0;
assign s_out_ready = !child_valid | child_ready;


initial begin
   for (int i=0;i<2**LOG_CQ_SLICE_SIZE;i++) begin
      num_children[i] = 0;
   end
end
always_ff @(posedge clk) begin
   if (s_finish_task_valid) begin 
      num_children[s_finish_task_slot] <= 0;
   end else if (s_child_valid & s_out_ready) begin
      num_children[non_mem_cq_slot] <= num_children[non_mem_cq_slot] + 1;
   end
end


assign s_finish_task_slot = non_mem_cq_slot;
always_comb begin
   s_finish_task_num_children = num_children[non_mem_cq_slot] + 
        ( (s_child_valid & s_out_ready) ? 1 : 0);
end


logic finish_task_fifo_empty, finish_task_fifo_full;

fifo #(
      .WIDTH( $bits(finish_task_slot) + $bits(finish_task_num_children)),
      .LOG_DEPTH(1)
   ) FINISHED_TASK_FIFO (
      .clk(clk),
      .rstn(rstn),
      .wr_en(s_finish_task_valid & s_finish_task_ready),
      .wr_data({s_finish_task_slot, s_finish_task_num_children}),

      .full(finish_task_fifo_full),
      .empty(finish_task_fifo_empty),

      .rd_en(finish_task_valid & finish_task_ready),
      .rd_data({finish_task_slot, finish_task_num_children})

   );
assign finish_task_valid = !finish_task_fifo_empty;
assign s_finish_task_ready = !finish_task_fifo_full;


free_list #(
   .LOG_DEPTH($clog2(N_THREADS))
) FREE_LIST_THREAD_ID  (
   .clk(clk),
   .rstn(rstn),

   .wr_en(thread_free_list_add_valid),
   .rd_en(thread_free_list_remove_valid),
   .wr_data(thread_free_list_add),

   .full(idle), 
   .empty(thread_free_list_empty),
   .rd_data(in_thread),

   .size(thread_free_list_occ)
);

logic [63:0] cycle;
always_ff @(posedge clk) begin
   if (!rstn) cycle <=0;
   else cycle <= cycle + 1;
end


generate 

for (i=0;i<N_SUB_TYPES;i++) begin
sssp_worker
#(
   .TILE_ID(TILE_ID),
   .SUBTYPE(i)
) 
   WORKER 
(
   .clk  (clk),
   .rstn (rstn),

   .task_in_valid(task_in_can_schedule[i]),
   .task_in_ready(task_in_ready[i]),

   .in_task (in_task[i]), 
   .in_data (in_data[i]),
   .in_last (in_last[i]),
   
   .arvalid      (s_arvalid[i]),
   .araddr       (s_araddr[i]),
   .arsize       (s_arsize[i]),
   .arlen        (s_arlen[i]),

   .resp_task    (s_resp_task[i]), //each mem resp will create a new task with this parameters
   .resp_subtype (s_resp_subtype[i]),
   .resp_mark_last(s_resp_mark_last[i]), // mark the last resp task as last

   .out_valid              (s_out_valid[i]),
   .out_task               (s_out_task [i]),
   .out_subtype            (s_out_subtype[i]),

   .out_task_is_child      (s_out_task_is_child[i]),     // if 0, out_task is re-enqueued back to a FIFO, else sent to CM
   
   .sched_task_valid       (s_sched_task_valid[i]),
   .sched_task_ready       (s_sched_task_ready[i]),

   .reg_bus      (reg_bus)


);

always_comb begin
   s_sched_task_aborted[i] = s_sched_task_valid[i] & task_aborted[in_cq_slot[i]];
end

`ifdef XILINX_SIMULATOR
   always_ff @(posedge clk) begin
      if (task_in_valid[i] & task_in_ready[i]) begin
         $display("[%5d] [rob-%2d] [ro %2d] [%3d] ts:%8d locale:%4d data:(%5d %5d)",
            cycle, TILE_ID, i, in_cq_slot[i],
            in_task[i].ts, in_task[i].locale, in_data[i][31:0], in_data[i][63:32]) ;
      end
   end 
`endif

end 
endgenerate

ro_scheduler SCHEDULER
(
   .clk   (clk),
   .rstn  (rstn),

   .task_valid    (s_sched_task_valid),
   .arvalid       (s_arvalid & ~s_sched_task_aborted),
   .arlen         (s_arlen),
   .task_cq_slot  (in_cq_slot),
   
   .out_valid     (s_out_valid & ~s_sched_task_aborted),
   .out_task_is_child (s_out_task_is_child),

   .task_aborted  (task_aborted),

   .task_ready    (s_sched_task_ready),

   .s_arready     (s_arready),
   .child_out_ready (s_out_ready),
   .finish_task_ready (s_finish_task_ready),

   .mem_access_subtype_valid (mem_access_subtype_valid),
   .mem_access_subtype       (mem_access_subtype),
   .non_mem_subtype_valid    (non_mem_subtype_valid),
   .non_mem_subtype          (non_mem_subtype), 

   .non_mem_task_finish      (s_finish_task_valid)

);


logic [LOG_LOG_DEPTH:0] log_size; 
always_ff @(posedge clk) begin
   if (!rstn) begin
      fifo_out_almost_full_thresh <= '1;
   end else begin
      if (reg_bus.wvalid) begin
         case (reg_bus.waddr) 
            CORE_FIFO_OUT_ALMOST_FULL_THRESHOLD : fifo_out_almost_full_thresh <= reg_bus.wdata;
         endcase
      end
   end
end
always_ff @(posedge clk) begin
   if (!rstn) begin
      reg_bus.rvalid <= 1'b0;
      reg_bus.rdata <= 'x;
   end else
   if (reg_bus.arvalid) begin
      reg_bus.rvalid <= 1'b1;
      casex (reg_bus.araddr) 
         DEBUG_CAPACITY : reg_bus.rdata <= log_size;
         CORE_FIFO_OUT_ALMOST_FULL_THRESHOLD : reg_bus.rdata <= 
               {in_fifo_occ[3], in_fifo_occ[2], in_fifo_occ[1], in_fifo_occ[0]};
         CORE_THREAD_ID_FIFO_OCC : reg_bus.rdata <= thread_free_list_occ;
      endcase
   end else begin
      reg_bus.rvalid <= 1'b0;
   end
end

if (READ_ONLY_STAGE_LOGGING) begin
   logic log_valid;
   typedef struct packed {
     
      logic [3:0] remaining_words_cur_rid;
      logic [4:0] rid_mshr_thread_id;
      logic [2:0] out_data_word_valid;
      logic [19:0] remaining_words;
      logic [31:0] valid_words;

      logic task_in_valid;
      logic task_in_ready;
      logic task_out_valid;
      logic task_out_ready;
      logic arvalid;
      logic arready;
      logic rvalid;
      logic rready;
      logic [7:0] out_fifo_occ;
      logic [7:0] in_cq_slot;
      logic [3:0] in_last;
      logic [3:0] out_last;

      logic [7:0] arid;
      logic [7:0] rid;
      logic [7:0] thread_id;
      logic [7:0] thread_fifo_occ;
      
      logic [159:0] in_task;
      logic [95:0] out_task;
      logic [63:0] out_data;
      
   } rw_read_log_t;
   rw_read_log_t log_word;
   always_comb begin
      log_valid = (task_in_valid & task_in_ready) | (out_valid & out_ready) | (arvalid & arready) | (rvalid & rready) ;

      log_word = '0;
   
      log_word.remaining_words_cur_rid = remaining_words_cur_rid[3:0];
      log_word.remaining_words = {  
                                   remaining_words[4][3:0], remaining_words[3][3:0],
                                   remaining_words[2][3:0], remaining_words[1][3:0],
                                   remaining_words[0][3:0]};
      log_word.valid_words = {rid_mshr.valid_words[15:0], next_valid_words};
      log_word.rid_mshr_thread_id = rid_thread;
      log_word.out_data_word_valid = {out_data_word_0_valid, out_data_word_1_valid};

      log_word.task_in_valid = task_in_valid;
      log_word.task_in_ready = task_in_ready;
      log_word.task_out_valid = out_valid;
      log_word.task_out_ready = out_ready;
      log_word.arvalid = arvalid;
      log_word.arready = arready;
      log_word.rvalid = rvalid;
      log_word.rready = rready;
      log_word.out_fifo_occ = in_fifo_occ[0];

      log_word.in_cq_slot = in_cq_slot;
      log_word.in_last = in_last;
      log_word.out_last = out_last;

      log_word.arid = arid[7:0];
      log_word.rid = rid[7:0];
      log_word.thread_id = in_thread;
      log_word.thread_fifo_occ = thread_free_list_occ;

      log_word.in_task = in_task;
      log_word.out_task = out_task;
      log_word.out_data = out_data;
   end

   log #(
      .WIDTH($bits(log_word)),
      .LOG_DEPTH(LOG_LOG_DEPTH)
   ) RW_READ_LOG (
      .clk(clk),
      .rstn(rstn),

      .wvalid(log_valid),
      .wdata(log_word),

      .pci(pci_debug),

      .size(log_size)

   );
end

endmodule


module sssp_worker
#(
   parameter TILE_ID,
   parameter SUBTYPE=0
) (

   input clk,
   input rstn,

   input logic             task_in_valid,
   output logic            task_in_ready,

   input task_t            in_task, 
   input data_t            in_data,
   input logic             in_last,
   
   output logic            arvalid,
   output logic [31:0]     araddr,
   output logic [2:0]      arsize,
   output logic [7:0]      arlen,
   output task_t           resp_task, //each mem resp will create a new task with this parameters
   output subtype_t        resp_subtype,
   output logic            resp_mark_last, // mark the last resp task as last

   output logic            out_valid,
   output task_t           out_task,
   output subtype_t        out_subtype,

   output logic            out_task_is_child, // if 0, out_task is re-enqueued back to a FIFO, else sent to CM

   output logic            sched_task_valid,
   input logic             sched_task_ready,


   reg_bus_t               reg_bus

);

logic [31:0] offset_base_addr;
logic [31:0] neighbors_base_addr;

assign sched_task_valid = task_in_valid;
assign task_in_ready = sched_task_ready;

assign resp_task = in_task;
always_comb begin
   araddr = 'x;
   arsize = 2;
   arlen = 0;
   arvalid = 1'b0;
   out_valid = 1'b0;
   resp_mark_last = 1'b0;
   out_task = in_task;
   out_task_is_child = 1'b1;
   resp_subtype = 'x;
   
   if (task_in_valid) begin
      case (SUBTYPE) 
         0: begin
            araddr = offset_base_addr + (in_task.locale <<  2);
            arsize = 3;
            arvalid = 1'b1;
            arlen = 0;
            resp_subtype = 1;
         end
         1: begin
            araddr = neighbors_base_addr + (in_data[31:0] <<  3);
            arvalid = (in_data[63:32] != in_data[31:0]);
            arsize = 3;
            arlen = (in_data[63:32] - in_data[31:0])-1;
            resp_subtype = 2;
            resp_mark_last = 1'b1;
         end
         2: begin
            out_valid = 1'b1;
            out_task.locale = in_data[31:0];
            out_task.ts = in_task.ts + in_data[63:32];
            out_task_is_child = 1'b1;
         end
      endcase

   end 
end

always_ff @(posedge clk) begin
   if (!rstn) begin
      offset_base_addr <= 0;
      neighbors_base_addr <= 0;
   end else begin
      if (reg_bus.wvalid) begin
         case (reg_bus.waddr)
            OFFSET_BASE_ADDR : offset_base_addr <= (reg_bus.wdata << 2);
            NEIGHBOR_BASE_ADDR : neighbors_base_addr <= (reg_bus.wdata << 2);
         endcase
      end
   end
end



endmodule


module ro_scheduler 
(
   input clk,
   input rstn,

   input logic [N_SUB_TYPES-1:0] task_valid,
   input logic [N_SUB_TYPES-1:0] arvalid,
   input byte_t [N_SUB_TYPES-1:0] arlen,
   input cq_slice_slot_t [N_SUB_TYPES-1:0] task_cq_slot,
   input logic [N_SUB_TYPES-1:0] out_valid,
   input logic [N_SUB_TYPES-1:0] out_task_is_child,

   input [2**LOG_CQ_SLICE_SIZE-1:0] task_aborted,

   output logic [N_SUB_TYPES-1:0] task_ready,

   input s_arready,
   input child_out_ready,
   input finish_task_ready,

   output logic         mem_access_subtype_valid,
   output subtype_t     mem_access_subtype,
   output logic         non_mem_subtype_valid, // set only if non_mem task has a child/successor
   output subtype_t     non_mem_subtype, 

   output logic         non_mem_task_finish

);


// Needed to figure out when a task has finished.  
byte_t n_dequeues [2**LOG_CQ_SLICE_SIZE];
byte_t n_enqueues [2**LOG_CQ_SLICE_SIZE];


highbit #(
   .OUT_WIDTH(LOG_N_SUB_TYPES),
   .IN_WIDTH(N_SUB_TYPES)
) MEM_SUBTYPE_SELECT (
   .in(arvalid), // assumes arvalid will not be set without task_valid being set
   .out(mem_access_subtype)
);

logic [N_SUB_TYPES-1:0] non_mem_valid_tasks;
assign non_mem_valid_tasks = task_valid & ~arvalid;

subtype_t non_mem_valid_subtype;
highbit #(
   .OUT_WIDTH(LOG_N_SUB_TYPES),
   .IN_WIDTH(N_SUB_TYPES)
) NON_MEM_SUBTYPE_SELECT (
   .in(non_mem_valid_tasks), // assumes arvalid will not be set without task_valid being set
   .out(non_mem_valid_subtype)
);

cq_slice_slot_t mem_access_cq_slot, non_mem_cq_slot;


logic mem_task_enq_child; 
assign mem_task_enq_child = arvalid[mem_access_subtype] & out_valid[mem_access_subtype];

assign non_mem_subtype = (mem_task_enq_child) ? mem_access_subtype : non_mem_valid_subtype;

always_comb begin
   mem_access_cq_slot = task_cq_slot[mem_access_subtype];
   non_mem_cq_slot = task_cq_slot[non_mem_subtype];
end

logic is_non_mem_task_finished;
always_comb begin
   is_non_mem_task_finished = 1'b0;
   if (task_valid[non_mem_subtype]) begin
      if (mem_task_enq_child) begin
         // TODO
      end else begin
         if (non_mem_subtype==0) begin
            is_non_mem_task_finished = 1'b1;
         end else begin
            is_non_mem_task_finished = (n_dequeues[non_mem_cq_slot] + 1 == n_enqueues[non_mem_cq_slot]);
         end
      end
   end
end  

logic can_process_mem_task, process_mem_task;
logic can_process_non_mem_task, process_non_mem_task;

assign non_mem_task_finish = process_non_mem_task & is_non_mem_task_finished;


always_comb begin
   can_process_mem_task = task_valid[mem_access_subtype] & arvalid[mem_access_subtype] & s_arready;
   can_process_non_mem_task =  (task_valid[non_mem_subtype]) &
            (! is_non_mem_task_finished | finish_task_ready) &
            (! out_valid[non_mem_subtype] | child_out_ready);

   if (mem_task_enq_child) begin
      process_mem_task = (can_process_non_mem_task & can_process_mem_task);
      process_non_mem_task = (can_process_non_mem_task & can_process_mem_task);
   end else begin
      process_mem_task = can_process_mem_task;
      process_non_mem_task = can_process_non_mem_task;
   end
end


always_comb begin
   mem_access_subtype_valid = process_mem_task;
   non_mem_subtype_valid = process_non_mem_task;
end

initial begin
   for (int i=0;i<2**LOG_CQ_SLICE_SIZE;i++) begin
      n_dequeues[i] = 0;
      n_enqueues[i] = 0;
   end
end
always_ff @(posedge clk) begin
   if (process_mem_task) begin
      n_enqueues[ mem_access_cq_slot] <= n_enqueues[mem_access_cq_slot] 
         + (mem_access_subtype_valid ? (arlen[mem_access_subtype] + 1) : 0)
         - ((mem_access_subtype == 0)? 0 : 1);
   end
end
always_ff @(posedge clk) begin
   if (process_non_mem_task) begin
      n_dequeues[ non_mem_cq_slot] <= n_dequeues[non_mem_cq_slot]
               + ((non_mem_subtype == 0)? 0 : 1)
               - ( (out_valid[non_mem_subtype] & !out_task_is_child[non_mem_subtype]) ? 1 :0);
   end
end

genvar i;
generate 
for (i=0;i<N_SUB_TYPES;i++) begin
   always_comb begin
      task_ready[i] = 1'b0;
      if (process_mem_task & (mem_access_subtype==i)) begin
         task_ready[i] = 1'b1;
      end else if (process_non_mem_task & (non_mem_subtype == i)) begin
         task_ready[i] = 1'b1;
      end
   end
end
endgenerate


endmodule
