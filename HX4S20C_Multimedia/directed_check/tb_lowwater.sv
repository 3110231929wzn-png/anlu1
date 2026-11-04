`timescale 1ns/1ps
module tb_lowwater;
reg rst; reg [3:0] state; reg [9:0] wrusedw;
localparam IDLE=0,ACK=1,PREP=2,WAIT_SPACE=3,ISSUE=4,DRAIN=5,NEXT=6,DONE=7,PLAN=8;
wire original_urgent = !rst && (state!=IDLE && state!=DONE && state!=ACK) &&
                         (wrusedw <= 10'd256);
wire candidate_urgent = !rst && (state!=IDLE && state!=DONE && state!=ACK) &&
                         (!wrusedw[9] && (!wrusedw[8] || !(|wrusedw[7:0])));
integer r,s,n,j,k,checks,diffs; reg [19:0] pattern;
initial begin
 checks=0;diffs=0;
 for(r=0;r<2;r=r+1) for(s=0;s<16;s=s+1) for(n=0;n<1024;n=n+1) begin
  rst=r;state=s;wrusedw=n;#1;
  if(original_urgent !== candidate_urgent) begin
   $display("FAIL binary rst=%0d state=%0d count=%0d old=%b new=%b",r,s,n,original_urgent,candidate_urgent);$fatal(1);
  end
  checks=checks+1;
 end
 $display("PASS BINARY_EQUIVALENCE checks=%0d counts=1024 reset_values=2 states=16",checks);
 // This diagnostic quantifies the already-disclosed four-state simulation boundary.
 rst=0;state=PREP;
 for(n=0;n<1048576;n=n+1) begin
  pattern=n;
  for(j=0;j<10;j=j+1) case(pattern[j*2+:2])
   0:wrusedw[j]=0;1:wrusedw[j]=1;2:wrusedw[j]=1'bx;3:wrusedw[j]=1'bz;
  endcase
  #1;
  if(original_urgent !== candidate_urgent) begin
   if(diffs<4)$display("XZ_DIFFERENCE count=%b old=%b new=%b",wrusedw,original_urgent,candidate_urgent);
   diffs=diffs+1;
  end
 end
 $display("XZ_DIAGNOSTIC patterns=1048576 differences=%0d",diffs);
 $display("DIRECTED_CHECK_COMPLETE");$finish;
end
endmodule
