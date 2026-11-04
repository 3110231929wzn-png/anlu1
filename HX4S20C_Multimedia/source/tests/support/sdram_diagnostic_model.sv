`timescale 1ns/1ps
// Diagnostic SDR subset only. NOT a manufacturer-qualified device model.
// Supports sequential BL1/2/4/8 and CL2/3, active rows, precharge and DQM.
// Omits retention, analog timing checks, self-refresh and full-page bursts.
module EG_PHY_SDRAM_2M_32 #(parameter real READ_DELAY_NS=0.0)(
 input clk,ras_n,cas_n,we_n,input [10:0] addr,input [1:0] ba,
 inout [31:0] dq,input cs_n,dm0,dm1,dm2,dm3,cke);
 reg [31:0] memory[0:2097151];
 reg [10:0] row[0:3];
 reg [3:0] active=0;
 integer burst_len=1,cas_latency=3,tick=0;
 reg single_write=0;
 integer wr_left=0,wr_bank=0,wr_col=0,wr_base=0;
 reg [10:0] wr_row;
 reg [255:0] pending=0;
 integer pending_addr[0:255];
 reg [31:0] q=0;
 reg driving=0;
 integer slot,j,key,col;
 assign dq=driving?q:32'bz;
 function integer address_key(input [10:0] r,input [1:0] b,input integer c);
   address_key=(r*1024)+(b*256)+(c&255);
 endfunction
 task store(input integer index);
   begin
     if($test$plusargs("TRACE_MEMORY"))$display("DIAG_MEMORY WRITE t=%0t addr=%0d dq=%h",$time,index,dq);
     if(!dm0)memory[index][7:0]=dq[7:0];
     if(!dm1)memory[index][15:8]=dq[15:8];
     if(!dm2)memory[index][23:16]=dq[23:16];
     if(!dm3)memory[index][31:24]=dq[31:24];
   end
 endtask
 always @(posedge clk) if(cke)begin
   tick=tick+1;slot=tick%256;
   if(pending[slot])begin
     if($test$plusargs("TRACE_MEMORY"))$display("DIAG_MEMORY RETURN t=%0t addr=%0d data=%h",$time,pending_addr[slot],memory[pending_addr[slot]]);
     q<=#(READ_DELAY_NS)memory[pending_addr[slot]];
     driving<=#(READ_DELAY_NS)1'b1;pending[slot]=0;
   end else driving<=#(READ_DELAY_NS)1'b0;
   if(wr_left>0)begin
     store(address_key(wr_row,wr_bank,wr_col));wr_left=wr_left-1;
     wr_col=wr_base|((wr_col+1)&(burst_len-1));
   end
   if(!cs_n)case({ras_n,cas_n,we_n})
     3'b000:begin
       if(ba!==0 || addr[10]!==0)$fatal(1,"Diagnostic model: invalid MRS reserved bits");
       if(addr[3] || addr[8:7]!=0 || addr[2:0]>3 || (addr[6:4]!=2 && addr[6:4]!=3))
         $fatal(1,"Diagnostic model: unsupported MRS mode %h",addr);
       burst_len=1<<addr[2:0];cas_latency=addr[6:4];single_write=addr[9];
     end
     3'b011:begin row[ba]=addr;active[ba]=1;end
     3'b010:begin if(addr[10])active=0;else active[ba]=0;end
     3'b100:begin
       if(!active[ba])$fatal(1,"Diagnostic model: WRITE without active bank");
       store(address_key(row[ba],ba,addr[7:0]));
       wr_bank=ba;wr_row=row[ba];wr_base=addr[7:0]&~(burst_len-1);
       wr_col=wr_base|((addr[7:0]+1)&(burst_len-1));
       wr_left=single_write?0:burst_len-1;
     end
     3'b101:begin
       if($test$plusargs("TRACE_MEMORY"))$display("DIAG_MEMORY READ_CMD t=%0t row=%0d bank=%0d col=%0d CL=%0d",$time,row[ba],ba,addr[7:0],cas_latency);
       if(!active[ba])$fatal(1,"Diagnostic model: READ without active bank");
       for(j=0;j<burst_len;j=j+1)begin
         col=(addr[7:0]&~(burst_len-1))|((addr[7:0]+j)&(burst_len-1));
         key=(tick+cas_latency+j)%256;
         if(pending[key])$fatal(1,"Diagnostic model: overlapping read schedule");
         pending[key]=1;pending_addr[key]=address_key(row[ba],ba,col);
       end
     end
     3'b110:begin wr_left=0;pending=0;end
   endcase
 end
endmodule
