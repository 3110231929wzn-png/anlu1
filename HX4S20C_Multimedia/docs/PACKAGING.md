# 发布整理说明

来源为已确认最终压缩包的解压目录。整理前已按原包 `FILES_SHA256.json` 核验全部被列出的文件，原包和原工程均只读保留。

完整保留 `source/`、`directed_check/` 与最终 `bit/` 文件，未删除安路 IP 依赖。只做下列上传副本调整：

- `source/scripts/candidate_bitgen.tcl`：移除旧电脑路径；数据库和新固件输出由环境变量指定，拒绝覆盖已有固件。
- `source/src/td_project/lab_ex5_i2s_v1.0.al`：工程根目录属性改为相对路径 .；其余配置不变。
- `source/src/user_source/ip_source/pll.v`：仅删除生成器注释中的个人电脑路径。
- `source/src/user_source/ip_source/pll.vhd`：仅删除生成器注释中的个人电脑路径。
- `source/src/user_source/hdl_source/IP/PLL_HDMI_AUDIO.v`：仅删除生成器注释中的个人电脑路径。
- `source/src/user_source/hdl_source/IP/PLL_HDMI_AUDIO.vhd`：仅删除生成器注释中的个人电脑路径。
- `source/src/td_project/al_ip/PLL.v`：仅删除生成器注释中的个人电脑路径。
- `source/src/td_project/al_ip/PLL.vhd`：仅删除生成器注释中的个人电脑路径。

功能 HDL 经去除注释和空白后的逐文件比较，与最终包一致；所有未列为调整的源码、测试、配置和最终 BIT 均保留原字节。版权声明保留。

排除项：8.32 MB 历史 `td/routed.db`、含本机绝对路径的历史全量清单/冻结输入/阶段日志，以及无关缓存、minidump 和重复构建产物。保留无个人路径的精选历史验收记录，另生成仅含相对路径的发布清单。

图片来自项目已有技术文档配图：系统架构、开发板与 HDMI 显示、转场及频谱演示。照片以无损方式移除 EXIF/XMP 等元数据，压缩像素数据不变。本次未上传含作者和联系人资料的整份 Word 文档。

新工程全部放在 `HX4S20C_Multimedia/` 下；仓库原初始化 README 保持不变。
