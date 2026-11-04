`timescale 1ns/1ps
//=============================================================================
//  tb_param_ctrl.v : param_ctrl 的行为级测试台
//
//  时间常数全部按比例缩小（CLK_FREQ=1000，即 1ms = 1 个时钟），便于快速跑完。
//  逐项检查：点动 +1、长按滑动、松手停住、按住期间拨 SW1 不会改到另一个参数、
//  参数只在 vs 上升沿更新。
//
//  ModelSim 用法（在 adjust 目录下）：
//      vlib work
//      vlog tb_param_ctrl.v param_ctrl.v
//      vsim -c tb_param_ctrl -do "run -all; quit -f"
//
//  iverilog 用法：
//      iverilog -o tb.vvp tb_param_ctrl.v param_ctrl.v && vvp tb.vvp
//=============================================================================
module tb_param_ctrl;

localparam integer TCLK = 10;          // 100MHz 仿真时钟（与 CLK_FREQ 无关，只影响绝对时间）

reg clk = 1'b0;
reg rst = 1'b1;
reg vs  = 1'b0;
reg sw  = 1'b0;                        // 0 = 调亮度
reg key = 1'b1;                        // 按下为低

wire signed [7:0] bri;
wire signed [5:0] con;
wire sel;

integer errors = 0;

param_ctrl #(
    .CLK_FREQ      (1000),             // 1ms = 1 拍
    .DEB_MS        (2),                // 消抖 2 拍
    .SW_DEB_MS     (2),
    .HOLD_MS       (10),               // 10 拍后进长按
    .TICK_MS       (3),
    .FAST_MS       (2),
    .FAST_AFTER_MS (40)
) dut (
    .clk (clk), .rst (rst),
    .I_vs (vs), .I_sw_sel (sw), .I_key (key),
    .O_bri (bri), .O_con (con), .O_sel (sel)
);

always #(TCLK/2) clk = ~clk;

// 场同步：每 40 拍来一个 vs 脉冲，模拟 640x480@60 的刷新（缩小版）
initial begin
    forever begin
        #(TCLK*10) vs = 1'b1;
        #(TCLK)    vs = 1'b0;
        #(TCLK*29);
    end
end

task check(input signed [7:0] exp_bri, input signed [5:0] exp_con, input [127:0] tag);
    begin
        // 等两帧，保证参数已经从工作值搬到输出
        repeat (2) @(posedge vs);
        @(negedge clk);
        if (bri !== exp_bri || con !== exp_con) begin
            $display("[FAIL] %0s : bri=%0d(期望 %0d)  con=%0d(期望 %0d)",
                     tag, bri, exp_bri, con, exp_con);
            errors = errors + 1;
        end else begin
            $display("[ OK ] %0s : bri=%0d con=%0d sel=%0d", tag, bri, con, sel);
        end
    end
endtask

initial begin
    repeat (5) @(posedge clk);
    rst = 1'b0;
    repeat (5) @(posedge clk);

    // 1) 点动一次：按下 5 拍后松开 → 亮度 +1
    key = 1'b0;
    repeat (5) @(posedge clk);
    key = 1'b1;
    check(8'sd1, 6'sd0, "点动 +1");

    // 2) 点动三次 → 亮度 +4
    repeat (3) begin
        key = 1'b0; repeat (5) @(posedge clk);
        key = 1'b1; repeat (5) @(posedge clk);
    end
    check(8'sd4, 6'sd0, "再点动三次");

    // 3) 按住 30 拍：进长按后每 3 拍一步，应远大于 1
    key = 1'b0;
    repeat (30) @(posedge clk);
    key = 1'b1;
    if (bri <= 8'sd10) begin
        $display("[FAIL] 长按滑动没走起来：bri=%0d", bri);
        errors = errors + 1;
    end else begin
        $display("[ OK ] 长按滑动：bri 已滑到 %0d", bri);
    end
    repeat (2) @(posedge vs);
    if (con !== 6'sd0) begin
        $display("[FAIL] 调亮度时段对比度被改动：con=%0d", con);
        errors = errors + 1;
    end

    // 4) 按住期间拨 SW1，不应改到另一个参数（目标在按下时已经锁定）
    sw = 1'b0;                       // 先确保 SW1 稳定在"亮度"
    repeat (6) @(posedge clk);
    key = 1'b0;
    repeat (12) @(posedge clk);      // 过消抖与长按门限，已经在滑动
    sw = 1'b1;                       // 滑动途中拨到"对比度"
    repeat (20) @(posedge clk);      // 继续按住滑动
    key = 1'b1;
    repeat (2) @(posedge vs);
    if (con !== 6'sd0) begin
        $display("[FAIL] 按住期间拨 SW1 改到了对比度：con=%0d", con);
        errors = errors + 1;
    end else begin
        $display("[ OK ] 按住期间拨 SW1 未误改对比度");
    end

    // 5) 松开后 SW1 已拨到对比度，此时点动：con 加，bri 不动
    begin : t5
        reg signed [7:0] bri_before;
        repeat (6) @(posedge clk);
        bri_before = bri;
        key = 1'b0; repeat (5) @(posedge clk);
        key = 1'b1; repeat (5) @(posedge clk);
        repeat (2) @(posedge vs);
        if (con < 6'sd1) begin
            $display("[FAIL] 切到对比度后点动无效：con=%0d", con);
            errors = errors + 1;
        end else if (bri !== bri_before) begin
            $display("[FAIL] 调对比度时亮度被改动：bri=%0d -> %0d", bri_before, bri);
            errors = errors + 1;
        end else begin
            $display("[ OK ] 切到对比度后点动：con=%0d bri=%0d", con, bri);
        end
    end

    if (errors == 0) $display("==== TB_PARAM_CTRL PASS ====");
    else             $display("==== TB_PARAM_CTRL FAIL : %0d 项 ====", errors);
    $finish;
end

endmodule
