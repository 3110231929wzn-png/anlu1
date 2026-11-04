`timescale 1ns/1ps
// Unmodified reference RTL, ideal clocks. No HDMI core, PLL, or board model.
module tb_official_audio_chain;
  localparam signed [23:0] AMP=24'sd2000000;
  reg mclk=0,pixel_clk=0,rst=1;
  always #(1000.0/24.576) mclk=~mclk;
  initial begin #17;forever #20 pixel_clk=~pixel_clk;end
  wire bclk,lrck,dout,audio_valid,acr_valid;
  wire [23:0] left_pcm,right_pcm;
  wire [19:0] cts,n;
  hdmi_audio_tone_i2s_64fs tone(.I_mclk(mclk),.I_rst(rst),.O_i2s_BCLK(bclk),.O_i2s_LRCK(lrck),.O_i2s_DOUT(dout));
  I2S_receiver receiver(.I_clk(pixel_clk),.I_rst(rst),.I_i2s_BCLK(bclk),.I_i2s_LRCK(lrck),.I_i2s_DOUT(dout),
    .O_audio_valid(audio_valid),.O_audio_left_data(left_pcm),.O_audio_right_data(right_pcm));
  audio_arc_calculate #(.ACR_N(6144)) acr(.I_clk(pixel_clk),.I_rst(rst),.I_audio_valid(audio_valid),
    .O_acr_valid(acr_valid),.O_acr_cts(cts),.O_acr_n(n));

  // Independent pin-level I2S decoder: WS changes one bit before new data.
  reg [63:0] serial_shift=0;
  reg prev_ws=0;
  reg [23:0] serial_left=0;
  reg [23:0] expected_left[0:2047],expected_right[0:2047];
  integer queued=0,consumed=0,epoch_good=0,total_good=0;
  integer data_errors=0,tone_errors=0,cadence_errors=0,acr_errors=0,reset_errors=0;
  integer premature_valid=0,positive_samples=0,negative_samples=0;
  reg signed [23:0] tone_current=0,tone_next=AMP;
  reg [31:0] phase_model=0;
  reg [63:0] next_serial;
  realtime last_bclk=0,last_frame=0,delta;
  integer bclk_periods=0,frame_periods=0;
  always @(posedge bclk or posedge rst) begin
    if(rst) begin
      serial_shift=0;prev_ws=0;serial_left=0;queued=0;
      tone_current=0;tone_next=AMP;phase_model=0;last_bclk=0;last_frame=0;
    end else begin
      if(last_bclk!=0) begin
        delta=$realtime-last_bclk;bclk_periods=bclk_periods+1;
        if(delta<162.75 || delta>162.78)cadence_errors=cadence_errors+1;
      end
      last_bclk=$realtime;
      next_serial={serial_shift[62:0],dout};
      if(lrck!==prev_ws) begin
        if(prev_ws==0) serial_left=next_serial[63:40];
        else begin
          expected_left[queued]=serial_left;expected_right[queued]=next_serial[63:40];
          if(serial_left!==tone_current || next_serial[63:40]!==tone_current)begin
            tone_errors=tone_errors+1;
            if(tone_errors<5)$display("TONE_MISMATCH frame=%0d L=%h R=%h expected=%h",queued,serial_left,next_serial[63:40],tone_current);
          end
          if(last_frame!=0)begin
            delta=$realtime-last_frame;frame_periods=frame_periods+1;
            if(delta<20833.0 || delta>20833.6)cadence_errors=cadence_errors+1;
          end
          last_frame=$realtime;queued=queued+1;
          tone_current=tone_next;tone_next=phase_model[31]?AMP:-AMP;
          phase_model=phase_model+32'd23409862; // C4 phase step in default reference tone.
        end
        prev_ws=lrck;serial_shift=0;
      end else serial_shift=next_serial;
    end
  end

  integer pixel_cycle=0,last_valid_cycle=0;
  reg previous_valid=0;
  always @(posedge pixel_clk or posedge rst)begin
    if(rst)begin consumed=0;epoch_good=0;pixel_cycle=0;last_valid_cycle=0;previous_valid=0;end
    else begin
      pixel_cycle=pixel_cycle+1;
      #0.001;
      if(audio_valid===1'b1)begin
        if(previous_valid)cadence_errors=cadence_errors+1;
        if(consumed>=queued)begin
          premature_valid=premature_valid+1;
          $display("EARLY_PCM_AFTER_RESET t=%0t L=%h R=%h completed_serial_frames=%0d",$time,left_pcm,right_pcm,queued);
        end else begin
          if(left_pcm!==expected_left[consumed] || right_pcm!==expected_right[consumed])begin
            data_errors=data_errors+1;
            if(data_errors<5)$display("PCM_MISMATCH frame=%0d L=%h/%h R=%h/%h",consumed,left_pcm,expected_left[consumed],right_pcm,expected_right[consumed]);
          end
          if(last_valid_cycle && (pixel_cycle-last_valid_cycle<520 || pixel_cycle-last_valid_cycle>521))cadence_errors=cadence_errors+1;
          last_valid_cycle=pixel_cycle;consumed=consumed+1;epoch_good=epoch_good+1;total_good=total_good+1;
          if($signed(left_pcm)>0)positive_samples=positive_samples+1;
          if($signed(left_pcm)<0)negative_samples=negative_samples+1;
        end
      end
      previous_valid=audio_valid;
    end
  end

  // Count actual input valid events and video cycles independently of ACR internals.
  integer sample_counter=0,tick_counter=0,expected_cts=0,epoch_acr=0,total_acr=0;
  integer cts_min=1000000,cts_max=0;
  reg expect_acr=0;
  always @(posedge pixel_clk or posedge rst)begin
    if(rst)begin sample_counter=0;tick_counter=0;epoch_acr=0;end
    else begin
      tick_counter=tick_counter+1;expect_acr=0;
      if(audio_valid===1'b1)begin
        sample_counter=sample_counter+1;
        if(sample_counter==48)begin
          sample_counter=0;expect_acr=1;expected_cts=tick_counter;tick_counter=0;
        end
      end
      #0.001;
      if(acr_valid!==expect_acr)acr_errors=acr_errors+1;
      if(expect_acr)begin
        if(n!==6144 || cts!==expected_cts)acr_errors=acr_errors+1;
        if(epoch_acr>0)begin
          if(cts<24999 || cts>25001)acr_errors=acr_errors+1;
          if(cts<cts_min)cts_min=cts;if(cts>cts_max)cts_max=cts;
        end
        $display("ACR epoch_window=%0d CTS=%0d N=%0d expected_cts=%0d",epoch_acr,cts,n,expected_cts);
        epoch_acr=epoch_acr+1;total_acr=total_acr+1;
      end
    end
  end
  initial begin
    #1000;rst=0;
    wait(epoch_good>=256);
    // Reset halfway through a right-channel word, not just between samples.
    wait(lrck==1);repeat(17)@(posedge bclk);#7;rst=1;
    #200;
    if({bclk,lrck,dout}!==3'b000)reset_errors=reset_errors+1;
    #800;
    if(audio_valid!==0 || acr_valid!==0)reset_errors=reset_errors+1;
    #73;rst=0;
    wait(epoch_good>=256);#200;
    if(positive_samples==0 || negative_samples==0 || total_acr<8)reset_errors=reset_errors+1;
    $display("SUMMARY complete_PCM=%0d positive=%0d negative=%0d BCLK_periods=%0d sample_periods=%0d ACR_windows=%0d CTS_range=%0d..%0d",total_good,positive_samples,negative_samples,bclk_periods,frame_periods,total_acr,cts_min,cts_max);
    $display("CHECK data_errors=%0d tone_errors=%0d cadence_errors=%0d acr_errors=%0d reset_errors=%0d early_PCM=%0d",data_errors,tone_errors,cadence_errors,acr_errors,reset_errors,premature_valid);
    if(data_errors+tone_errors+cadence_errors+acr_errors+reset_errors+premature_valid)
      $fatal(1,"official audio chain has unresolved checks; inspect each category");
    $display("PASS tb_official_audio_chain: nominal clocks, tone/PCM/cadence/ACR and clean restart");$finish;
  end
  initial begin #20000000;$fatal(1,"audio test watchdog");end
endmodule
