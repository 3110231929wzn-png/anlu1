`timescale 1ns/1ps
// Four-mode read adaptation on the hardware-verified ordered SDRAM/FIFO path.
// 128-word aligned physical blocks: source base never changes mid-burst.
// The boundary block is fetched new-first, old-second. transition_pixels
// selects which returns enter the single existing output FIFO, in raster order.
// One outstanding burst, exact return drain plus legacy ten-cycle tail guard.
module frame_wipe_read #(
    parameter ADDR_BITS=21,
    parameter FRAME_WIDTH=640,
    parameter FRAME_HEIGHT=480
)(
    input rst,mem_clk,Sdr_init_done,Sdr_init_ref_vld,Sdr_busy,App_wr_busy,
    input Sdr_rd_en,
    input [31:0] Sdr_rd_dout,
    output O_rd_busy,
    output O_rd_urgent,
    output App_rd_en,
    output [ADDR_BITS-1:0] App_rd_addr,
    input read_req,
    output reg read_req_ack,
    output read_finish,
    output reg read_commit_toggle,
    output reg [1:0] read_active_index,
    output [1:0] osd_transition_mode, // read-only observation of actual locked mode
    input [ADDR_BITS-1:0] read_addr_0,read_addr_1,read_addr_2,read_addr_3,
    input [1:0] read_addr_index,
    input [1:0] transition_mode,
    input [ADDR_BITS-1:0] read_len,
    output reg fifo_aclr,
    input [9:0] wrusedw,
    output fifo_we,
    output [31:0] fifo_data
);
    localparam IDLE=0,ACK=1,PREP=2,WAIT_SPACE=3,ISSUE=4,DRAIN=5,NEXT=6,DONE=7,PLAN=8;
    reg [3:0] state;
    reg [2:0] req_sync;
    reg [1:0] index_d0,index_d1;
    reg [ADDR_BITS-1:0] len_d0,len_d1,length;
    reg [ADDR_BITS-1:0] old_base,new_base,block_offset;
    reg [9:0] block_x;
    reg [8:0] block_y;
    reg [7:0] issued,returned;
    reg [3:0] tail;
    reg source_new,second_part;
    reg wipe_active;
    reg [1:0] target_index;
    reg [6:0] progress;
    reg [1:0] mode_d0,mode_d1,mode_reg;
    assign osd_transition_mode=mode_reg;
    reg [ADDR_BITS-1:0] row_offset,burst_base;
    reg [9:0] physical_x;
    reg [10:0] window_begin,window_end;
    wire [10:0] cut = ({4'd0,progress} << 3) + ({4'd0,progress} << 1);
    wire [10:0] split = 11'd640-cut;
    wire [15:0] pwide={9'd0,progress};
    wire [15:0] vertical_product=(pwide<<9)-(pwide<<5);
    wire [9:0] vertical_cut=vertical_product[15:6];
    wire fade_pair=(mode_reg==3 && progress!=0 && progress!=64);
    wire mixed = (mode_reg==0) ? (({1'b0,block_x}<cut) && (cut<({1'b0,block_x}+128))) :
                 (mode_reg==2) ? (({1'b0,block_x}<split) && (split<({1'b0,block_x}+128))) : fade_pair;
    wire old_needed,new_needed;
    wire [23:0] mixed_rgb;
    wire [10:0] source_x={1'b0,physical_x}+returned;
    wire [10:0] mapped_x=(mode_reg==2) ? (source_new ? source_x+split : source_x-cut) : source_x;
    wire response_valid=Sdr_rd_en && (state==ISSUE || state==DRAIN) && returned<128;
    wire within_window=source_x>=window_begin && source_x<window_end;
    wire [9:0] aligned_begin={window_begin[9:7],7'd0};

    // Only sliding changes spatial sample coordinates. Its bounded source
    // segment is covered by one or two aligned physical blocks; unwanted
    // prefix/tail returns are discarded, not left in another pixel FIFO.
    always @* begin
        window_begin={1'b0,block_x};window_end={1'b0,block_x}+128;
        if(mode_reg==2) begin
            if(source_new) begin
                window_begin=({1'b0,block_x}<split)?11'd0:({1'b0,block_x}-split);
                window_end={1'b0,block_x}+128-split;
            end else begin
                window_begin={1'b0,block_x}+cut;
                window_end=({1'b0,block_x}+128<split)?({1'b0,block_x}+128+cut):11'd640;
            end
        end
    end

    // One old block is retained solely for fade pairing. RAM and its output
    // register have no reset, allowing BRAM inference. Valid resets separately.
    reg [23:0] old_pixels[127:0];
    reg [23:0] old_q,new_q;
    reg [9:0] mix_x;
    reg [8:0] mix_y;
    reg mix_valid;
    always @(posedge mem_clk) begin
        if(response_valid && fade_pair && !source_new)
            old_pixels[returned[6:0]]<=Sdr_rd_dout[31:8];
        old_q<=old_pixels[returned[6:0]];
        new_q<=Sdr_rd_dout[31:8];mix_x<=mapped_x[9:0];mix_y<=block_y;
        if(rst)mix_valid<=0;
        else mix_valid<=response_valid && fade_pair && source_new;
    end

    function [ADDR_BITS-1:0] base;
        input [1:0] index;
        begin
            case(index)
                0:base=read_addr_0;1:base=read_addr_1;
                2:base=read_addr_2;3:base=read_addr_3;
            endcase
        end
    endfunction
    transition_pixels pixels(
        .I_mode(mode_reg),.I_progress(progress),.I_x(fade_pair?mix_x:mapped_x[9:0]),.I_y(fade_pair?mix_y:block_y),
        .I_old_rgb(fade_pair?old_q:Sdr_rd_dout[31:8]),.I_new_rgb(fade_pair?new_q:Sdr_rd_dout[31:8]),
        .O_rgb(mixed_rgb),.O_old_x(),.O_new_x(),.O_source_y(),
        .O_old_needed(old_needed),.O_new_needed(new_needed),.O_valid()
    );
    assign fifo_we = !rst && (fade_pair ? mix_valid :
                    (response_valid && within_window && (source_new ? new_needed : old_needed)));
    assign fifo_data = {mixed_rgb,8'd0}; // low byte is unused by the RGB path
    // A refresh may start on the edge between reservation and first request.
    // Recheck only the first beat. After acceptance, never break the burst.
    assign App_rd_en = (state==ISSUE) && ((issued!=0) ||
                       (!Sdr_busy && !Sdr_init_ref_vld && !App_wr_busy && Sdr_init_done));
    assign App_rd_addr = burst_base + issued;
    assign O_rd_busy = (state==ISSUE || state==DRAIN);
    // A video consumer cannot stall. Reserve refill bandwidth before allowing
    // another 256-word write burst (128 video clocks at the 2:1 clock ratio).
    // Only active frames request priority; IDLE/DONE/ACK must not block writes.
    assign O_rd_urgent = !rst && (state!=IDLE && state!=DONE && state!=ACK) &&
                         (!wrusedw[9] && (!wrusedw[8] || !(|wrusedw[7:0])));
    assign read_finish = (state==DONE);

    always @(posedge mem_clk or posedge rst) begin
        if(rst) begin
            req_sync<=0;index_d0<=0;index_d1<=0;len_d0<=0;len_d1<=0;mode_d0<=0;mode_d1<=0;
        end else begin
            req_sync<={req_sync[1:0],read_req};
            index_d0<=read_addr_index;index_d1<=index_d0;
            len_d0<=read_len;len_d1<=len_d0;
            mode_d0<=transition_mode;mode_d1<=mode_d0;
        end
    end
    always @(posedge mem_clk or posedge rst) begin
        if(rst) begin
            state<=IDLE;read_req_ack<=0;read_commit_toggle<=0;read_active_index<=0;
            fifo_aclr<=0;old_base<=0;new_base<=0;length<=0;block_offset<=0;
            block_x<=0;block_y<=0;issued<=0;returned<=0;tail<=0;
            source_new<=0;second_part<=0;wipe_active<=0;target_index<=0;progress<=0;
            mode_reg<=0;row_offset<=0;burst_base<=0;physical_x<=0;
        end else begin
            if(Sdr_rd_en && (state==ISSUE || state==DRAIN)) returned<=returned+1'b1;
            if(App_rd_en) tail<=0;
            else if(tail<10) tail<=tail+1'b1;
            case(state)
                IDLE: if(req_sync[2] && Sdr_init_done) state<=ACK;
                DONE: state<=IDLE;
                ACK: begin
                    read_req_ack<=1;fifo_aclr<=1;
                    // ACK level may last arbitrary cycles; accept once, only
                    // after requester withdraws its request through the CDC chain.
                    if(!req_sync[2]) begin
                        read_req_ack<=0;fifo_aclr<=0;
                        length<=len_d1;block_offset<=0;block_x<=0;block_y<=0;row_offset<=0;
                        read_commit_toggle<=~read_commit_toggle;
                        if(wipe_active) begin
                            progress<=progress+1'b1;
                            if(progress==63) begin
                                wipe_active<=0;
                                read_active_index<=target_index;
                            end
                        end else if(index_d1!=read_active_index) begin
                            old_base<=base(read_active_index);new_base<=base(index_d1);
                            target_index<=index_d1;wipe_active<=1;progress<=0;
                            mode_reg<=mode_d1; // once per complete transition, not per frame
                        end else begin
                            old_base<=base(index_d1);new_base<=base(index_d1);
                            progress<=0;
                        end
                        state<=PREP;
                    end
                end
                PREP: begin
                    case(mode_reg)
                        0:source_new<=({1'b0,block_x}<cut);
                        1:source_new<=({1'b0,block_y}<vertical_cut);
                        2:source_new<=({1'b0,block_x}>=split); // old prefix, new suffix
                        3:source_new<=(progress==64); // fade: old block then new block
                    endcase
                    second_part<=0;state<=PLAN;
                end
                PLAN: begin
                    physical_x<=aligned_begin;
                    burst_base<=(source_new?new_base:old_base)+row_offset+aligned_begin;
                    state<=WAIT_SPACE;
                end
                WAIT_SPACE: begin
                    if(req_sync[2]) state<=ACK;
                    else if(wrusedw<10'd384 && !App_wr_busy && !Sdr_busy &&
                            !Sdr_init_ref_vld && Sdr_init_done) begin
                        issued<=0;returned<=0;tail<=0;state<=ISSUE;
                    end
                end
                ISSUE: begin
                    if(App_rd_en) begin
                        issued<=issued+1'b1;
                        if(issued==127) state<=DRAIN;
                    end
                end
                DRAIN: if(returned==128 && tail==10) state<=NEXT;
                NEXT: begin
                    if(req_sync[2]) state<=ACK;
                    else if({1'b0,physical_x}+128<window_end) begin
                        physical_x<=physical_x+128;burst_base<=burst_base+128;state<=WAIT_SPACE;
                    end else if(mixed && !second_part) begin
                        source_new<=~source_new;second_part<=1;state<=PLAN;
                    end else if(block_offset+128>=length) state<=DONE;
                    else begin
                        block_offset<=block_offset+128;
                        if(block_x==FRAME_WIDTH-128) begin
                            block_x<=0;block_y<=block_y+1'b1;row_offset<=row_offset+FRAME_WIDTH;
                        end
                        else block_x<=block_x+128;
                        state<=PREP;
                    end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
