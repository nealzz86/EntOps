# 企业运维工具（EntOps）

面向单位信息部日常运维的 Windows 桌面工具：全中文界面、**完全离线可用**、免安装单文件分发。
基于 [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil)（MIT）二次开发，品牌与发行地址 [github.com/nealzz86](https://github.com/nealzz86)。

## 功能页

| 页面 | 内容 |
| --- | --- |
| 概览 | 设备信息、环境状态、常用入口、操作日志 |
| 软件安装 | 国产常用软件批量安装（微信/企微/钉钉/WPS/向日葵等），共享目录优先、官网兜底 |
| 系统优化 | 推荐预设与逐项调优开关 |
| 功能配置 | Windows 功能与组件开关 |
| 更新管理 | Windows 更新策略与离线更新 |
| Win10/11 镜像 | ISO 校验、注入应答文件、写出可启动 U 盘 |
| AppX 移除 | 按类别移除预装应用包 |
| 打印共享 | 打印机一键安装（6 步）、共享文件夹映射、小票打印机网口配置与搜索 |
| 安全清理 | 360/金山毒霸/腾讯电脑管家残留彻底清理、磁盘清理（扫描预览 + 勾选清理） |
| 磁盘分析 | 磁盘总览、目录树占用下钻、大文件定位 |
| 网络诊断 | Ping/追踪路由/端口扫描/DNS 测速/主机发现/摄像头盘点/pktmon 抓包分析，以及 14 个离线网络计算工具 |

界面在远程桌面（RDP）下使用，因此**不使用任何位图阴影或模糊效果**；远程会话会自动改用软件渲染。

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
