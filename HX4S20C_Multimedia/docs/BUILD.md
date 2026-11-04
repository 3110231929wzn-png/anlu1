# 构建和仿真说明

本页记录打包版本 README 中的历史成功流程，本次上传未重新构建。

1. 设置 `STAGE1_BUILD_DIR` 为本机新的独立输出目录，在 TD Tcl 环境执行 `source/scripts/rgb_shiftadd_synth.tcl`。该脚本加载 `pin.adc`、`pin_e3.adc`、`timing.sdc` 和两份 FIFO 约束，生成 `gate.db`。
2. 在新的 TD 进程中使用相同 `STAGE1_BUILD_DIR` 执行 `rgb_shiftadd_physical.tcl`，导入 `gate.db`、布局布线、应用 `audio_reset_physical.sdc` 并审计复位边界，输出 `routed.db`。
3. 在新 TD 进程中设置 `STAGE1_ROUTED_DB` 指向步骤 2 生成的数据库，以 `audit_routed_timing.tcl` 做最终 STA。历史验收结果保存在 `evidence/sta_acceptance.json`。
4. STA 验收后设置 `STAGE1_ROUTED_DB` 和 `STAGE1_BIT_OUTPUT`（新的 .bit 输出路径），在新 TD 进程执行 `candidate_bitgen.tcl`。脚本拒绝覆盖已有固件。

大型历史 `td/routed.db` 未上传；步骤 2 会重新生成数据库。仓库内最终 BIT 是原确认版本的逐字节副本，不是本次重新生成的产物。

通用 `run_build.py` 默认调用的 `build.tcl` 未显式加载 `pin_e3.adc`，不能视为上述成功流程的等价入口。仿真脚本中 ModelSim 和 TD 库的默认路径也需按本机安装位置配置。

本次迁移只清理路径及发布信息；TD 重定位打开、重新综合、布局布线、STA、仿真和上板均未在此次上传工作中重跑。历史记录中的通过状态不等同于对所有工具版本或所有使用场景的保证。
