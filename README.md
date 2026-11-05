# 企业运维工具（EntOps）

面向单位信息部日常运维的 Windows 桌面工具：全中文界面、**完全离线可用**、免安装单文件分发。
基于 [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil)（MIT）二次开发，品牌与发行地址 [github.com/nealzz86](https://github.com/nealzz86)。

装机、批量装软件、接网络打印机、映射共享盘、装机体检、清理与网络排障集中在一个窗口里做完：双击即用，
不需要安装；驱动与工具打包在可执行文件尾部，首次运行时自动解开，内网机器不联公网也能干活——只有从官网
兜底下载软件时才需要出网。左侧导航分页，`Ctrl+K` 命令面板能搜到全部功能并直接跳转。

## 下载

最新发布见 [Releases](https://github.com/nealzz86/EntOps/releases)：单文件免安装包约 58 MB，右键「以管理员身份运行」。

公开那份不含任何单位内网信息——打印机地址是模板值，共享账号与口令留空，到了具体机器在「打印与共享设置」页
填一次即可（配置只写本机）。给单位内部机器用的那份由内网共享目录分发，编译时合入了现场配置，不进公开渠道。

## 功能页

按左侧导航从上到下：

| 页面 | 内容 |
| --- | --- |
| 概览 | 设备信息、环境状态、常用入口、操作日志 |
| 软件安装 | 国产常用软件批量安装（微信/企微/钉钉/WPS/向日葵等），共享目录优先、官网兜底；预装包移除入口在本页 |
| 系统优化 | 推荐预设与逐项调优开关 |
| 功能配置 | Windows 功能与组件开关 |
| 更新管理 | Windows 更新策略与离线更新 |
| Win10/11 镜像 | ISO 校验、注入应答文件、写出可启动 U 盘 |
| 打印共享 | 打印机一键安装（6 步）、共享文件夹映射、小票打印机网口配置与搜索 |
| 打印与共享设置 | 本机打印机与共享文件夹的增删改与校验，保存后只影响这台电脑 |
| 安全清理 | 360/金山毒霸/腾讯电脑管家残留彻底清理、磁盘清理（扫描预览 + 勾选清理） |
| 磁盘分析 | 磁盘总览、目录树占用下钻、大文件定位 |
| 网络诊断 | Ping/追踪路由/端口扫描/DNS 测速/主机发现/摄像头盘点/pktmon 抓包分析，以及 14 个离线网络计算工具 |
| 装机体检 | 按基线清单逐项检查（基础信息、系统配置、安全基线、远程运维、软件交付、网络共享、存储、运行环境），不合格项给出处置入口 |

## 快速开始

```powershell
# 编译并直接运行（开发）
powershell -NoProfile -ExecutionPolicy Bypass -File .\Compile.ps1 -Run

# 一条命令产出免安装单文件 exe（编译 → 发布 → ps2exe 打包 → 追加内置资源）
powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-Exe.ps1
```

`Build-Exe.ps1` 默认输出到 `D:\打印\企业运维工具`（`EntOps.ps1`、`启动.bat`、`企业运维工具.exe`），换机器时用
`-ReleaseDir` 指定；`-IconFile` 默认取 `assets\entops-icon.ico`。exe 尾部追加的是普通 zip 载荷，首次运行解包到
`%LOCALAPPDATA%\winutil\payload`，所以 drivers 与 tools 不需要随目录一起拷贝。

## 配置与现场信息

功能数据都在 `config\` 下的 JSON 里（`tweaks.json`、`applications.json`、`entprinters.json` 等），编译时内嵌进产物。

其中 **`config\entprinters.json` 仓库里是占位模板**，不含真实地址与账号。现场信息写在同目录的
`config\entprinters.local.json`（已被 `.gitignore` 排除）：

```json
{
    "colorUserCode": "部门用户代码",
    "printers": [ { "Name": "前台打印机", "Ip": "10.0.0.20", "Location": "前台", "SupportColor": true } ],
    "shares":   [ { "Name": "共享文件夹一", "Paths": ["\\\\10.0.0.30\\share1"], "User": "账号", "Pass": "口令", "Drive": "S:" } ]
}
```

合并规则写在 `Compile.ps1`：同名键覆盖，**数组整体替换**，所以覆盖文件里要写完整的那一段。打印共享页的机器名、
IP、位置、共享盘符与账号全部来自配置，界面代码里不保留任何现场信息。

现场改配置优先用界面：左侧「打印与共享设置」页能直接增删改打印机与共享文件夹（数量不限），保存后「打印共享」页
的列表同步刷新；配置写入 `%LOCALAPPDATA%\winutil\entprinters.user.json`——只有这一台电脑生效、不进版本库、程序升级也不会被覆盖，
「恢复内置配置」删掉该文件即可回到编译时内嵌的那份。保存前会校验（IP、UNC 路径、盘符、纸张尺寸、纸名长度），
不通过就不落盘。启动时 `Update-WinUtilEntPrinterConfig` 读这个文件，读不懂就退回内置配置，不会把打印带走。
凭据仍是明文存在本机，公用电脑不要在里面存密码。

**要发给单位以外的机器时用公开构建**：`Build-Exe.ps1 -NoSiteOverlay -ReleaseDir <暂存目录>` 会跳过
`*.local.json` 合并，产物里打印机与共享都是模板值，账号口令留空——现场同事在「打印与共享设置」页填一次即可。
这条路自带证据：编译完会用 `lint\SecretScan.ps1 -ArtifactPath` 拿覆盖配置里的每一个现场值去比对产物文本，
命中就报错停止；读不到任何现场值同样报错，免得覆盖配置被改名后检查变成空转。

打印机驱动包（`driver.zip`、`driver2.zip`，约 60 MB）属于厂商分发物，不入库；需要离线安装时把它们放进
`drivers\`（或 `driver\`）目录，与 `EntOps.ps1`/exe 同级即可被识别。

## 目录结构

```
Compile.ps1        拼装机身：scripts + functions + config + xaml → winutil.ps1
Build-Exe.ps1      装机身 → ps2exe 单文件 exe → 追加 drivers/tools 载荷
scripts/           启动与主循环（start.ps1 建同步表，main.ps1 管 UI 线程与工作线程池）
functions/private/ 系统操作与界面无关的实现
functions/public/  Invoke-WPF* 按钮处理器（按钮路由在 Invoke-WPFButton.ps1 的 switch 分支）
xaml/inputXML.xaml 唯一窗口布局
config/            内嵌数据与现场配置
docs/              上游 winutil 的文档站（Astro），尚未按本项目改写
```

## 约定

- 长任务一律走 `Start-WinUtilJob`，界面线程只做界面；步骤进度用 `Step-WinUtilJob`。
- `winspool.drv`、`net use`、任务栏接口这类外部调用都可能不返回，调用前要有探测与超时，卡住时日志必须说清当时在做哪一步。
- 日志在 `%LOCALAPPDATA%\winutil\logs\winutil_*.log`，界面线程卡顿与渲染停帧由看门狗写入同一份日志。
- 网络扫描、资产盘点类功能仅用于本单位授权网段。含明文口令的配置文件不要提交，也不要写进界面文案。

## 许可与出处

沿用上游 [winutil](https://github.com/ChrisTitusTech/winutil) 的 MIT 许可，见 `LICENSE`。上游的 issue 模板、贡献指南与文档站仍在仓库里，尚未逐页本地化。
