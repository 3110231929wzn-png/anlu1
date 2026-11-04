//=============================================================================
//  rgb_adjust.v : 独立 RGB 像素调节模块（亮度 / 对比度）
//
//  扩展功能之一：把「亮度、对比度」从画面上剥出来做成独立一级，
//  输入原始 RGB + 两个参数，输出调整后的 RGB，与 OSD、HDMI 发送核完全解耦。
//
//  运算模型（逐通道，R/G/B 各算一遍）：
//      d   = in - 128                     // 有符号差值，-128 ~ +127
//      gain = 1 + I_con / 32              // I_con = -16 ~ +16 → 增益 0.50 ~ 1.50
//      out = 128 + I_bri + d + (d * I_con) / 32
//          = 128 + I_bri + d * gain       // I_bri = -64 ~ +64
//  最后钳到 0 ~ 255。对比度围绕中灰 128 旋转，亮部升、暗部降，不会整体偏移；
//  亮度是纯粹的整体平移，两项串在一起就能覆盖「压暗 + 提对比」「提亮 + 降对比」这些组合。
//
//  资源：三路 9x6 有符号乘法（TD 会推 DSP 或 LE）+ 三路钳位，25 MHz 下打一拍收口。
//        无 BRAM、无行缓存，de/hs/vs 只做同拍延迟直通。
//
//  参数在 param_ctrl 里已经是 vs 沿锁存的帧级常量，所以本模块输出的整帧用同一组
//  参数，不会出现「上半帧旧值、下半帧新值」的水平撕裂。
//=============================================================================

module rgb_adjust (
    input  wire              I_clk,
    input  wire              I_rst,          // 高有效

    // 像素流（来自 video_delay，已与 de/hs/vs 对齐）
    input  wire              I_de,
    input  wire              I_hs,
    input  wire              I_vs,
    input  wire [23:0]       I_rgb,

    // 调节参数（已同步到本时钟域）
    input  wire signed [7:0] I_bri,          // 亮度偏移 -64 ~ +64，0 = 原图
    input  wire signed [5:0] I_con,          // 对比度 q，增益 = 1 + q/32，0 = 原图

    // 显示有效：首图提交前为 0，此时强制输出全黑。
    // 不加这一路的话，黑底 (0,0,0) 经 +亮度 会被抬成灰底，上电那几秒看着像"没信号"。
    input  wire              I_vld,

    // 调节后的像素流（比输入晚 1 个 video_clk，de/hs/vs 同步延迟）
    output reg               O_de,
    output reg               O_hs,
    output reg               O_vs,
    output reg  [23:0]       O_rgb
);

//-----------------------------------------------------------------------------
//  单通道运算：亮度平移 + 围绕中灰的对比度缩放，带上下钳位
//-----------------------------------------------------------------------------
function [7:0] adj_ch;
    input [7:0]       ch;
    input signed [7:0] bri;
    input signed [5:0] con;
    reg signed [8:0]  d;      // in - 128            -128 ~ +127
    reg signed [14:0] p;      // d * con             -2048 ~ +2048
    reg signed [8:0]  g;      // p / 32              -64 ~ +64
    reg signed [11:0] s;      // 128 + bri + d + g   -128 ~ +383
    begin
        d = $signed({1'b0, ch}) - 9'sd128;
        p = d * con;
        g = p >>> 5;                       // 算术右移，负数向下取整
        s = 12'sd128
          + $signed({{4{bri[7]}}, bri})
          + $signed({{3{d[8]}},   d})
          + $signed({{3{g[8]}},   g});
        if (s[11])
            adj_ch = 8'd0;                 // 下溢：全黑
        else if (s > 12'sd255)
            adj_ch = 8'd255;               // 上溢：全白
        else
            adj_ch = s[7:0];
    end
endfunction

//-----------------------------------------------------------------------------
//  三通道并行 + 一拍寄存（收口关键路径，同时把 de/hs/vs 一起对齐）
//-----------------------------------------------------------------------------
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        O_rgb <= 24'd0;
        O_de  <= 1'b0;
        O_hs  <= 1'b0;
        O_vs  <= 1'b0;
    end else begin
        if (I_vld)
            O_rgb <= { adj_ch(I_rgb[23:16], I_bri, I_con),
                       adj_ch(I_rgb[15:8 ], I_bri, I_con),
                       adj_ch(I_rgb[7:0  ], I_bri, I_con) };
        else
            O_rgb <= 24'd0;          // 首图未就绪：保持纯黑，不让亮度把黑底抬灰
        O_de  <= I_de;
        O_hs  <= I_hs;
        O_vs  <= I_vs;
    end
end

endmodule
