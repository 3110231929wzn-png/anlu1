//=============================================================================
//  fft_tw_rom.v : 512 点 FFT 旋转因子表 —— 由 doc/python/gen_tables.py 生成，请勿手改
//
//  这里只存 0 ~ 128（0 ~ 90 度）这 129 个点，其余用对称性推：
//      k <= 128 : W^k = ( cos(j), -sin(j) )，j = k
//      k >  128 : W^k = (-cos(j), -sin(j) )，j = 256-k
//  生成脚本已经逐点校验过 256 个值与直接算 exp(-j*2*pi*k/512) 完全一致。
//
//  表用 case 写成组合 ROM（LUT 实现）。之所以不用 initial + 数组：
//  本工程的 TD 流程里 eram_init 是关的，initial 初值会被直接丢掉，
//  综合告警 "net mem does not have a driver"，上板就是一个全 X 的表。
//=============================================================================

module fft_tw_rom (
    input  wire        clk,
    input  wire [7:0]  addr,
    output reg  [31:0] data
);

wire [7:0] kk = addr[7] ? (8'd0 - addr) : addr;   // 256-k（addr>=128 时）

reg [15:0] q_cos, q_sin;

always @(*) begin
    case (kk)
        8'd0   : begin q_cos = 16'h7FFF; q_sin = 16'h0000; end
        8'd1   : begin q_cos = 16'h7FFD; q_sin = 16'h0192; end
        8'd2   : begin q_cos = 16'h7FF5; q_sin = 16'h0324; end
        8'd3   : begin q_cos = 16'h7FE9; q_sin = 16'h04B6; end
        8'd4   : begin q_cos = 16'h7FD8; q_sin = 16'h0648; end
        8'd5   : begin q_cos = 16'h7FC1; q_sin = 16'h07D9; end
        8'd6   : begin q_cos = 16'h7FA6; q_sin = 16'h096A; end
        8'd7   : begin q_cos = 16'h7F86; q_sin = 16'h0AFB; end
        8'd8   : begin q_cos = 16'h7F61; q_sin = 16'h0C8C; end
        8'd9   : begin q_cos = 16'h7F37; q_sin = 16'h0E1C; end
        8'd10  : begin q_cos = 16'h7F09; q_sin = 16'h0FAB; end
        8'd11  : begin q_cos = 16'h7ED5; q_sin = 16'h113A; end
        8'd12  : begin q_cos = 16'h7E9C; q_sin = 16'h12C8; end
        8'd13  : begin q_cos = 16'h7E5F; q_sin = 16'h1455; end
        8'd14  : begin q_cos = 16'h7E1D; q_sin = 16'h15E2; end
        8'd15  : begin q_cos = 16'h7DD5; q_sin = 16'h176E; end
        8'd16  : begin q_cos = 16'h7D89; q_sin = 16'h18F9; end
        8'd17  : begin q_cos = 16'h7D39; q_sin = 16'h1A82; end
        8'd18  : begin q_cos = 16'h7CE3; q_sin = 16'h1C0B; end
        8'd19  : begin q_cos = 16'h7C88; q_sin = 16'h1D93; end
        8'd20  : begin q_cos = 16'h7C29; q_sin = 16'h1F1A; end
        8'd21  : begin q_cos = 16'h7BC5; q_sin = 16'h209F; end
        8'd22  : begin q_cos = 16'h7B5C; q_sin = 16'h2223; end
        8'd23  : begin q_cos = 16'h7AEE; q_sin = 16'h23A6; end
        8'd24  : begin q_cos = 16'h7A7C; q_sin = 16'h2528; end
        8'd25  : begin q_cos = 16'h7A05; q_sin = 16'h26A8; end
        8'd26  : begin q_cos = 16'h7989; q_sin = 16'h2826; end
        8'd27  : begin q_cos = 16'h7909; q_sin = 16'h29A3; end
        8'd28  : begin q_cos = 16'h7884; q_sin = 16'h2B1F; end
        8'd29  : begin q_cos = 16'h77FA; q_sin = 16'h2C99; end
        8'd30  : begin q_cos = 16'h776B; q_sin = 16'h2E11; end
        8'd31  : begin q_cos = 16'h76D8; q_sin = 16'h2F87; end
        8'd32  : begin q_cos = 16'h7641; q_sin = 16'h30FB; end
        8'd33  : begin q_cos = 16'h75A5; q_sin = 16'h326E; end
        8'd34  : begin q_cos = 16'h7504; q_sin = 16'h33DF; end
        8'd35  : begin q_cos = 16'h745F; q_sin = 16'h354D; end
        8'd36  : begin q_cos = 16'h73B5; q_sin = 16'h36BA; end
        8'd37  : begin q_cos = 16'h7307; q_sin = 16'h3824; end
        8'd38  : begin q_cos = 16'h7254; q_sin = 16'h398C; end
        8'd39  : begin q_cos = 16'h719D; q_sin = 16'h3AF2; end
        8'd40  : begin q_cos = 16'h70E2; q_sin = 16'h3C56; end
        8'd41  : begin q_cos = 16'h7022; q_sin = 16'h3DB8; end
        8'd42  : begin q_cos = 16'h6F5E; q_sin = 16'h3F17; end
        8'd43  : begin q_cos = 16'h6E96; q_sin = 16'h4073; end
        8'd44  : begin q_cos = 16'h6DC9; q_sin = 16'h41CE; end
        8'd45  : begin q_cos = 16'h6CF8; q_sin = 16'h4325; end
        8'd46  : begin q_cos = 16'h6C23; q_sin = 16'h447A; end
        8'd47  : begin q_cos = 16'h6B4A; q_sin = 16'h45CD; end
        8'd48  : begin q_cos = 16'h6A6D; q_sin = 16'h471C; end
        8'd49  : begin q_cos = 16'h698B; q_sin = 16'h4869; end
        8'd50  : begin q_cos = 16'h68A6; q_sin = 16'h49B4; end
        8'd51  : begin q_cos = 16'h67BC; q_sin = 16'h4AFB; end
        8'd52  : begin q_cos = 16'h66CF; q_sin = 16'h4C3F; end
        8'd53  : begin q_cos = 16'h65DD; q_sin = 16'h4D81; end
        8'd54  : begin q_cos = 16'h64E8; q_sin = 16'h4EBF; end
        8'd55  : begin q_cos = 16'h63EE; q_sin = 16'h4FFB; end
        8'd56  : begin q_cos = 16'h62F1; q_sin = 16'h5133; end
        8'd57  : begin q_cos = 16'h61F0; q_sin = 16'h5268; end
        8'd58  : begin q_cos = 16'h60EB; q_sin = 16'h539B; end
        8'd59  : begin q_cos = 16'h5FE3; q_sin = 16'h54C9; end
        8'd60  : begin q_cos = 16'h5ED7; q_sin = 16'h55F5; end
        8'd61  : begin q_cos = 16'h5DC7; q_sin = 16'h571D; end
        8'd62  : begin q_cos = 16'h5CB3; q_sin = 16'h5842; end
        8'd63  : begin q_cos = 16'h5B9C; q_sin = 16'h5964; end
        8'd64  : begin q_cos = 16'h5A82; q_sin = 16'h5A82; end
        8'd65  : begin q_cos = 16'h5964; q_sin = 16'h5B9C; end
        8'd66  : begin q_cos = 16'h5842; q_sin = 16'h5CB3; end
        8'd67  : begin q_cos = 16'h571D; q_sin = 16'h5DC7; end
        8'd68  : begin q_cos = 16'h55F5; q_sin = 16'h5ED7; end
        8'd69  : begin q_cos = 16'h54C9; q_sin = 16'h5FE3; end
        8'd70  : begin q_cos = 16'h539B; q_sin = 16'h60EB; end
        8'd71  : begin q_cos = 16'h5268; q_sin = 16'h61F0; end
        8'd72  : begin q_cos = 16'h5133; q_sin = 16'h62F1; end
        8'd73  : begin q_cos = 16'h4FFB; q_sin = 16'h63EE; end
        8'd74  : begin q_cos = 16'h4EBF; q_sin = 16'h64E8; end
        8'd75  : begin q_cos = 16'h4D81; q_sin = 16'h65DD; end
        8'd76  : begin q_cos = 16'h4C3F; q_sin = 16'h66CF; end
        8'd77  : begin q_cos = 16'h4AFB; q_sin = 16'h67BC; end
        8'd78  : begin q_cos = 16'h49B4; q_sin = 16'h68A6; end
        8'd79  : begin q_cos = 16'h4869; q_sin = 16'h698B; end
        8'd80  : begin q_cos = 16'h471C; q_sin = 16'h6A6D; end
        8'd81  : begin q_cos = 16'h45CD; q_sin = 16'h6B4A; end
        8'd82  : begin q_cos = 16'h447A; q_sin = 16'h6C23; end
        8'd83  : begin q_cos = 16'h4325; q_sin = 16'h6CF8; end
        8'd84  : begin q_cos = 16'h41CE; q_sin = 16'h6DC9; end
        8'd85  : begin q_cos = 16'h4073; q_sin = 16'h6E96; end
        8'd86  : begin q_cos = 16'h3F17; q_sin = 16'h6F5E; end
        8'd87  : begin q_cos = 16'h3DB8; q_sin = 16'h7022; end
        8'd88  : begin q_cos = 16'h3C56; q_sin = 16'h70E2; end
        8'd89  : begin q_cos = 16'h3AF2; q_sin = 16'h719D; end
        8'd90  : begin q_cos = 16'h398C; q_sin = 16'h7254; end
        8'd91  : begin q_cos = 16'h3824; q_sin = 16'h7307; end
        8'd92  : begin q_cos = 16'h36BA; q_sin = 16'h73B5; end
        8'd93  : begin q_cos = 16'h354D; q_sin = 16'h745F; end
        8'd94  : begin q_cos = 16'h33DF; q_sin = 16'h7504; end
        8'd95  : begin q_cos = 16'h326E; q_sin = 16'h75A5; end
        8'd96  : begin q_cos = 16'h30FB; q_sin = 16'h7641; end
        8'd97  : begin q_cos = 16'h2F87; q_sin = 16'h76D8; end
        8'd98  : begin q_cos = 16'h2E11; q_sin = 16'h776B; end
        8'd99  : begin q_cos = 16'h2C99; q_sin = 16'h77FA; end
        8'd100 : begin q_cos = 16'h2B1F; q_sin = 16'h7884; end
        8'd101 : begin q_cos = 16'h29A3; q_sin = 16'h7909; end
        8'd102 : begin q_cos = 16'h2826; q_sin = 16'h7989; end
        8'd103 : begin q_cos = 16'h26A8; q_sin = 16'h7A05; end
        8'd104 : begin q_cos = 16'h2528; q_sin = 16'h7A7C; end
        8'd105 : begin q_cos = 16'h23A6; q_sin = 16'h7AEE; end
        8'd106 : begin q_cos = 16'h2223; q_sin = 16'h7B5C; end
        8'd107 : begin q_cos = 16'h209F; q_sin = 16'h7BC5; end
        8'd108 : begin q_cos = 16'h1F1A; q_sin = 16'h7C29; end
        8'd109 : begin q_cos = 16'h1D93; q_sin = 16'h7C88; end
        8'd110 : begin q_cos = 16'h1C0B; q_sin = 16'h7CE3; end
        8'd111 : begin q_cos = 16'h1A82; q_sin = 16'h7D39; end
        8'd112 : begin q_cos = 16'h18F9; q_sin = 16'h7D89; end
        8'd113 : begin q_cos = 16'h176E; q_sin = 16'h7DD5; end
        8'd114 : begin q_cos = 16'h15E2; q_sin = 16'h7E1D; end
        8'd115 : begin q_cos = 16'h1455; q_sin = 16'h7E5F; end
        8'd116 : begin q_cos = 16'h12C8; q_sin = 16'h7E9C; end
        8'd117 : begin q_cos = 16'h113A; q_sin = 16'h7ED5; end
        8'd118 : begin q_cos = 16'h0FAB; q_sin = 16'h7F09; end
        8'd119 : begin q_cos = 16'h0E1C; q_sin = 16'h7F37; end
        8'd120 : begin q_cos = 16'h0C8C; q_sin = 16'h7F61; end
        8'd121 : begin q_cos = 16'h0AFB; q_sin = 16'h7F86; end
        8'd122 : begin q_cos = 16'h096A; q_sin = 16'h7FA6; end
        8'd123 : begin q_cos = 16'h07D9; q_sin = 16'h7FC1; end
        8'd124 : begin q_cos = 16'h0648; q_sin = 16'h7FD8; end
        8'd125 : begin q_cos = 16'h04B6; q_sin = 16'h7FE9; end
        8'd126 : begin q_cos = 16'h0324; q_sin = 16'h7FF5; end
        8'd127 : begin q_cos = 16'h0192; q_sin = 16'h7FFD; end
        8'd128 : begin q_cos = 16'h0000; q_sin = 16'h7FFF; end
        default : begin q_cos = 16'h3FFF; q_sin = 16'h0000; end
    endcase
end

// 虚部恒为负；实部在 addr>=128 时取反
wire signed [15:0] cos_s = addr[7] ? (16'sd0 - q_cos[15:0]) : q_cos[15:0];
wire signed [15:0] sin_s = 16'sd0 - q_sin[15:0];

always @(posedge clk) begin
    data <= {cos_s, sin_s};
end

endmodule
