// Read-only latest-state mailbox. Data is registered BEFORE the 3-stage request
// reaches the destination, and held until its ACK has crossed back (2 stages).
// Source changes during flight are coalesced, never sampled as a torn tuple.
// Both resets assert from the same V3 global reset; release is local synchronous.
// Existing generated-clock timing relationships remain checked; no exceptions.
module osd_snapshot_cdc #(parameter WIDTH=6)(
 input src_clk,src_rst,input [WIDTH-1:0] src_data,
 input dst_clk,dst_rst,output reg [WIDTH-1:0] dst_data
);
 reg [WIDTH-1:0] held_data;
 reg req,ack;
 (* async_reg="true" *) reg [1:0] ack_sync;
 (* async_reg="true" *) reg [2:0] req_sync;
 always @(posedge src_clk or posedge src_rst) begin
   if(src_rst)begin held_data<=0;req<=0;ack_sync<=0;end
   else begin
     ack_sync<={ack_sync[0],ack};
     if(req==ack_sync[1] && src_data!=held_data)begin
       held_data<=src_data;
       req<=~req;
     end
   end
 end
 always @(posedge dst_clk or posedge dst_rst) begin
   if(dst_rst)begin req_sync<=0;ack<=0;dst_data<=0;end
   else begin
     req_sync<={req_sync[1:0],req};
     if(req_sync[2]!=ack)begin dst_data<=held_data;ack<=req_sync[2];end
   end
 end
endmodule
