function Add-WinUtilEntNatives {

    <#

    .SYNOPSIS
        Compiles (once per session) the winspool / LZ / shell native helpers used by the
        enterprise printer & share tab

    .DESCRIPTION
        Ported from the C# PrinterInstaller tool (Win32Spool / Win32Lz classes). The P/Invoke
        structs, DEVMODE field offsets and the three-tier driver install behaviour are copied
        verbatim so the PowerShell port keeps the exact behaviour that was field-validated.

    #>

    if ('EntSpool' -as [type]) { return }

    $source = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32;

public static class EntNative
{
    // The timeout-guarded calls below run on worker threads, so the log can be written while the
    // install thread reads it; a plain List would be corrupted by that.
    private static readonly object Sync = new object();
    private static readonly List<string> Log = new List<string>();

    public static void Say(string s) { lock (Sync) { Log.Add(s); } }
    public static string[] Drain()
    {
        lock (Sync)
        {
            string[] copy = Log.ToArray();
            Log.Clear();
            return copy;
        }
    }
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
internal struct EntPrinterDefaults
{
    public string pDataType;
    public IntPtr pDevMode;
    public int DesiredAccess;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
internal struct EntDriverInfo3
{
    public int cVersion;
    public string pName;
    public string pEnvironment;
    public string pDriverPath;
    public string pDataFile;
    public string pConfigFile;
    public string pHelpFile;
    public string pDependentFiles;
    public string pMonitorName;
    public string pDefaultDataType;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
internal struct EntPrinterInfo2
{
    public string pServerName;
    public string pPrinterName;
    public string pShareName;
    public string pPortName;
    public string pDriverName;
    public string pComment;
    public string pLocation;
    public IntPtr pDevMode;
    public string pSepFile;
    public string pPrintProcessor;
    public string pDatatype;
    public string pParameters;
    public IntPtr pSecurityDescriptor;
    public int Attributes;
    public int Priority;
    public int DefaultPriority;
    public int StartTime;
    public int UntilTime;
    public int Status;
    public int cJobs;
    public int AveragePPM;
}

[StructLayout(LayoutKind.Sequential)]
internal struct EntSizel { public int cx; public int cy; }

[StructLayout(LayoutKind.Sequential)]
internal struct EntRectl { public int left; public int top; public int right; public int bottom; }

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
internal struct EntFormInfo1
{
    public uint Flags;
    public string pName;
    public EntSizel Size;
    public EntRectl ImageableArea;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
internal struct EntOfstruct
{
    public byte cBytes;
    public byte fFixedDisk;
    public ushort nErrCode;
    public ushort reserved1;
    public ushort reserved2;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
    public string szPathName;
}

public static class EntSpool
{
    private const int PRINTER_ALL_ACCESS = 0x0F000C;
    private const int PRINTER_ACCESS_ADMINISTER = 0x00000004;
    private const int PRINTER_ACCESS_USE = 0x00000008;
    private const int APD_COPY_ALL_FILES = 0x00000004;

    private const int DM_IN_BUFFER = 1;
    private const int DM_OUT_BUFFER = 2;
    private const int DMPAPER_USER = 0;

    private const int DM_PAPERSIZE   = 0x00000002;
    private const int DM_PAPERLENGTH = 0x00000004;
    private const int DM_PAPERWIDTH  = 0x00000008;
    private const int DM_FORMNAME    = 0x00010000;
    private const int DM_COLOR       = 0x00000800;

    private const short DMCOLOR_COLOR      = 2;
    private const short DMCOLOR_MONOCHROME = 1;

    // DEVMODE (Unicode) fixed-part field offsets, same layout as Wingdi.h
    private const int DM_OFFSET_FIELDS      = 72;
    private const int DM_OFFSET_PAPERSIZE   = 78;
    private const int DM_OFFSET_PAPERLENGTH = 80;
    private const int DM_OFFSET_PAPERWIDTH  = 82;
    private const int DM_OFFSET_FORMNAME    = 102;
    private const int DM_OFFSET_COLOR       = 92;

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetDefaultPrinter(string pPrinterName);

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool OpenPrinter(string pPrinterName, out IntPtr hPrinter, ref EntPrinterDefaults pDefault);

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ClosePrinter(IntPtr hPrinter);

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool DeletePrinter(IntPtr hPrinter);

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool AddPrinterDriverEx(int Level, ref EntDriverInfo3 DriverInfo, int dwFileCopyFlags);

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr AddPrinter(string pName, int Level, ref EntPrinterInfo2 pPrinter);

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool AddForm(IntPtr hPrinter, uint Level, IntPtr pForm);

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int DocumentProperties(IntPtr hwnd, IntPtr hPrinter, string pDeviceName,
        IntPtr pDevModeOutput, IntPtr pDevModeInput, int fMode);

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetPrinter(IntPtr hPrinter, int Level, IntPtr pPrinter, int Command);

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetPrinter(IntPtr hPrinter, int Level, IntPtr pPrinter, int cbBuf, ref int pcbNeeded);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool EnumPrinters(int Flags, string Name, int Level, IntPtr pPrinterEnum,
        int cbBuf, ref int pcbNeeded, ref int pcReturned);

    private static EntPrinterDefaults Defaults(int access)
    {
        EntPrinterDefaults pd = new EntPrinterDefaults();
        pd.DesiredAccess = access;
        return pd;
    }

    public static bool PrinterExists(string name)
    {
        IntPtr h;
        EntPrinterDefaults pd = Defaults(0);
        if (OpenPrinter(name, out h, ref pd))
        {
            ClosePrinter(h);
            return true;
        }
        return false;
    }

    public static bool SetDefault(string name)
    {
        bool ok = SetDefaultPrinter(name);
        if (ok) EntNative.Say("已设为默认打印机: " + name);
        else EntNative.Say("[警告] 设为默认打印机失败(错误码 " + Marshal.GetLastWin32Error() + ")");
        return ok;
    }

    public static bool InstallDriver(string driverName, string driverPath, string dataPath,
        string configPath, string helpPath, string[] dependentFiles)
    {
        StringBuilder sb = new StringBuilder();
        foreach (string f in dependentFiles)
        {
            sb.Append(f);
            sb.Append('\0');
        }
        sb.Append('\0');

        EntDriverInfo3 di = new EntDriverInfo3();
        di.cVersion = 3;
        di.pName = driverName;
        di.pEnvironment = IntPtr.Size == 8 ? "Windows x64" : "Windows NT x86";
        di.pDriverPath = driverPath;
        di.pDataFile = dataPath;
        di.pConfigFile = configPath;
        di.pHelpFile = helpPath;
        di.pDependentFiles = sb.ToString();
        di.pMonitorName = null;
        di.pDefaultDataType = null;

        if (AddPrinterDriverEx(3, ref di, APD_COPY_ALL_FILES)) return true;
        int err = Marshal.GetLastWin32Error();
        EntNative.Say("AddPrinterDriverEx 错误码=" + err + " (" + new System.ComponentModel.Win32Exception(err).Message + ")");
        return false;
    }

    /// <summary>上一次 AddPrinter 是否因为超时而放弃等待（区别于普通失败）。</summary>
    public static bool AddPrinterTimedOut = false;

    /// <summary>探测 Print Spooler 是否还会回应。false 表示它已经被挡住，此时任何添加打印机的
    /// 调用只会跟着一起卡住，所以要在动手之前问一次。</summary>
    public static bool SpoolerResponsive(int timeoutSeconds)
    {
        bool answered = false;
        ManualResetEvent finished = new ManualResetEvent(false);
        // Not disposed on purpose: when this times out the worker is still parked in winspool and
        // signals the event later; disposing it would throw on that abandoned thread.
        ThreadPool.QueueUserWorkItem(delegate
        {
            try
            {
                int needed = 0, returned = 0;
                // A zero-length buffer is the point: ERROR_INSUFFICIENT_BUFFER plus a size means the
                // spooler received the RPC and replied, which is all a probe can ask for. OpenPrinter
                // on the server name is not usable here — Win10/11 answers 1801 名称无效 either way.
                EnumPrinters(6, null, 5, IntPtr.Zero, 0, ref needed, ref returned);
                int err = Marshal.GetLastWin32Error();
                answered = (needed > 0) || (err == 0) || (err == 122);
                if (!answered)
                {
                    EntNative.Say("探测 Print Spooler 失败，错误码=" + err + " ("
                        + new System.ComponentModel.Win32Exception(err).Message + ")");
                }
            }
            catch (Exception ex) { EntNative.Say("[提示] 探测 Print Spooler 异常：" + ex.Message); }
            finally { try { finished.Set(); } catch (Exception) { } }
        });
        if (!finished.WaitOne(timeoutSeconds * 1000, false))
        {
            EntNative.Say("探测 Print Spooler 超时（" + timeoutSeconds + " 秒）。");
            return false;
        }
        return answered;
    }

    /// <summary>带超时的 AddPrinter；超时与失败的提示语不同，靠 AddPrinterTimedOut 区分。</summary>
    public static bool AddPrinter(string name, string portName, string driverName, int timeoutSeconds)
    {
        AddPrinterTimedOut = false;
        bool[] outcome = new bool[1];
        ManualResetEvent finished = new ManualResetEvent(false);
        ThreadPool.QueueUserWorkItem(delegate(object state)
        {
            object[] args = (object[])state;
            try
            {
                outcome[0] = AddPrinterCore((string)args[0], (string)args[1], (string)args[2]);
            }
            catch (Exception ex)
            {
                outcome[0] = false;
                EntNative.Say("[错误] AddPrinter 异常：" + ex.Message);
            }
            finally { try { ((ManualResetEvent)args[3]).Set(); } catch (Exception) { } }
        },
        new object[] { name, portName, driverName, finished });

        if (!finished.WaitOne(timeoutSeconds * 1000, false))
        {
            AddPrinterTimedOut = true;
            EntNative.Say("AddPrinter 等待 " + timeoutSeconds + " 秒仍未返回：Print Spooler 被一个看不见的确认框"
                + "（多为驱动签名或 Point and Print 策略）或卡住的打印队列挡住了。");
            return false;
        }
        return outcome[0];
    }

    /// <summary>AddPrinter（PRINTER_INFO_2）。同名旧打印机先删除。</summary>
    private static bool AddPrinterCore(string name, string portName, string driverName)
    {
        try
        {
            IntPtr hOld;
            EntPrinterDefaults pdAll = Defaults(PRINTER_ALL_ACCESS);
            if (OpenPrinter(name, out hOld, ref pdAll))
            {
                DeletePrinter(hOld);
                ClosePrinter(hOld);
                EntNative.Say("已删除旧的同名打印机。");
            }
        }
        catch (Exception ex) { EntNative.Say("[提示] 删除旧的同名打印机失败：" + ex.Message); }

        EntPrinterInfo2 pi = new EntPrinterInfo2();
        pi.pPrinterName = name;
        pi.pPortName = portName;
        pi.pDriverName = driverName;
        pi.pPrintProcessor = "winprint";
        pi.pDatatype = "RAW";
        pi.Attributes = 0;

        IntPtr hPrinter = AddPrinter(null, 2, ref pi);
        if (hPrinter != IntPtr.Zero)
        {
            ClosePrinter(hPrinter);
            return true;
        }
        int err = Marshal.GetLastWin32Error();
        EntNative.Say("AddPrinter 错误码=" + err + " (" + new System.ComponentModel.Win32Exception(err).Message + ")");
        return false;
    }

    /// <summary>通过 DocumentProperties + SetPrinter 设置默认颜色模式。</summary>
    public static void SetColorMode(string printerName, bool color)
    {
        IntPtr hPrinter = IntPtr.Zero;
        IntPtr pDevMode = IntPtr.Zero;
        try
        {
            EntPrinterDefaults pd = Defaults(PRINTER_ACCESS_ADMINISTER | PRINTER_ACCESS_USE);
            if (!OpenPrinter(printerName, out hPrinter, ref pd))
            {
                EntNative.Say("[警告] 打开打印机失败，无法设置颜色模式。");
                return;
            }

            int needSize = DocumentProperties(IntPtr.Zero, hPrinter, printerName, IntPtr.Zero, IntPtr.Zero, 0);
            if (needSize <= 0) { EntNative.Say("[警告] DocumentProperties(查询大小) 失败，跳过颜色设置。"); return; }

            pDevMode = Marshal.AllocHGlobal(needSize);
            if (DocumentProperties(IntPtr.Zero, hPrinter, printerName, pDevMode, IntPtr.Zero, DM_OUT_BUFFER) <= 0)
            {
                EntNative.Say("[警告] DocumentProperties(DM_OUT_BUFFER) 失败，跳过颜色设置。");
                return;
            }

            int dmFields = Marshal.ReadInt32(pDevMode, DM_OFFSET_FIELDS);
            dmFields |= DM_COLOR;
            Marshal.WriteInt32(pDevMode, DM_OFFSET_FIELDS, dmFields);
            Marshal.WriteInt16(pDevMode, DM_OFFSET_COLOR, color ? DMCOLOR_COLOR : DMCOLOR_MONOCHROME);

            // IN+OUT 合并让驱动接受修改
            if (DocumentProperties(IntPtr.Zero, hPrinter, printerName, pDevMode, pDevMode, DM_IN_BUFFER | DM_OUT_BUFFER) <= 0)
            {
                EntNative.Say("[警告] DocumentProperties(合并颜色) 失败，错误码=" + Marshal.GetLastWin32Error());
                return;
            }

            int cbNeeded = 0;
            GetPrinter(hPrinter, 2, IntPtr.Zero, 0, ref cbNeeded);
            IntPtr pPrinterInfo = Marshal.AllocHGlobal(cbNeeded);
            try
            {
                if (!GetPrinter(hPrinter, 2, pPrinterInfo, cbNeeded, ref cbNeeded))
                {
                    EntNative.Say("[警告] GetPrinter 失败，跳过颜色设置。");
                    return;
                }
                // PRINTER_INFO_2 前 7 个指针字段之后是 pDevMode（第 8 个字段，offset 56）
                Marshal.WriteIntPtr(pPrinterInfo, 8 * 7, pDevMode);
                if (!SetPrinter(hPrinter, 2, pPrinterInfo, 0))
                {
                    EntNative.Say("[警告] SetPrinter 设置颜色失败，错误码=" + Marshal.GetLastWin32Error());
                    return;
                }
                EntNative.Say("默认颜色模式已设为：" + (color ? "彩色" : "黑白"));
            }
            finally { Marshal.FreeHGlobal(pPrinterInfo); }
        }
        catch (Exception ex) { EntNative.Say("[警告] 设置颜色模式异常：" + ex.Message); }
        finally
        {
            if (pDevMode != IntPtr.Zero) Marshal.FreeHGlobal(pDevMode);
            if (hPrinter != IntPtr.Zero) ClosePrinter(hPrinter);
        }
    }

    /// <summary>注册自定义纸张并直写注册表 Default DevMode（RICOH 驱动读取默认设置的权威位置）。
    /// 对应原工具「易快报打印模式」步骤，绕过驱动 DocumentProperties 合并拒绝逻辑。</summary>
    public static bool RegisterPaperForm(string printerName, string formName, int widthTenthMm, int heightTenthMm)
    {
        IntPtr hPrinter = IntPtr.Zero;
        IntPtr pDevMode = IntPtr.Zero;
        try
        {
            EntPrinterDefaults pd = Defaults(PRINTER_ALL_ACCESS);
            if (!OpenPrinter(printerName, out hPrinter, ref pd))
            {
                EntNative.Say("[错误] OpenPrinter 失败");
                return false;
            }

            // Step A: AddForm 注册到打印服务器
            int widthUm = widthTenthMm * 100;
            int heightUm = heightTenthMm * 100;
            EntFormInfo1 fi = new EntFormInfo1();
            fi.Flags = 0;
            fi.pName = formName;
            fi.Size.cx = widthUm;
            fi.Size.cy = heightUm;
            fi.ImageableArea.left = 0;
            fi.ImageableArea.top = 0;
            fi.ImageableArea.right = widthUm;
            fi.ImageableArea.bottom = heightUm;

            IntPtr pForm = Marshal.AllocHGlobal(Marshal.SizeOf(fi));
            try
            {
                Marshal.StructureToPtr(fi, pForm, false);
                if (!AddForm(hPrinter, 1, pForm))
                {
                    int err = Marshal.GetLastWin32Error();
                    if (err == 183 || err == 80) EntNative.Say("纸张规格已存在于打印服务器。");
                    else EntNative.Say("[警告] AddForm 失败，错误码=" + err + "，继续尝试写 DEVMODE...");
                }
                else
                {
                    EntNative.Say("纸张规格已注册到打印服务器：" + formName + " (" + (widthUm / 1000.0) + "×" + (heightUm / 1000.0) + " mm)");
                }
            }
            finally { Marshal.FreeHGlobal(pForm); }

            // Step B: 取当前 DEVMODE，修改纸张相关字段
            int needSize = DocumentProperties(IntPtr.Zero, hPrinter, printerName, IntPtr.Zero, IntPtr.Zero, 0);
            if (needSize <= 0) { EntNative.Say("[警告] DocumentProperties(查询大小) 失败"); return false; }
            pDevMode = Marshal.AllocHGlobal(needSize);
            if (DocumentProperties(IntPtr.Zero, hPrinter, printerName, pDevMode, IntPtr.Zero, DM_OUT_BUFFER) <= 0)
            {
                EntNative.Say("[警告] DocumentProperties(DM_OUT_BUFFER) 失败");
                return false;
            }

            int dmFields = Marshal.ReadInt32(pDevMode, DM_OFFSET_FIELDS);
            dmFields |= DM_PAPERSIZE | DM_PAPERLENGTH | DM_PAPERWIDTH | DM_FORMNAME;
            Marshal.WriteInt32(pDevMode, DM_OFFSET_FIELDS, dmFields);
            Marshal.WriteInt16(pDevMode, DM_OFFSET_PAPERSIZE, (short)DMPAPER_USER);
            Marshal.WriteInt16(pDevMode, DM_OFFSET_PAPERLENGTH, (short)heightTenthMm);
            Marshal.WriteInt16(pDevMode, DM_OFFSET_PAPERWIDTH, (short)widthTenthMm);
            char[] chars = formName.ToCharArray();
            for (int i = 0; i < 32; i++)
            {
                short val = (i < chars.Length) ? (short)chars[i] : (short)0;
                Marshal.WriteInt16(pDevMode, DM_OFFSET_FORMNAME + i * 2, val);
            }

            // Step C: 直接写入注册表 "Default DevMode"
            string regPath = @"SYSTEM\CurrentControlSet\Control\Print\Printers\" + printerName;
            byte[] devModeBytes = new byte[needSize];
            Marshal.Copy(pDevMode, devModeBytes, 0, needSize);
            try
            {
                using (RegistryKey key = Registry.LocalMachine.CreateSubKey(regPath))
                {
                    if (key != null)
                    {
                        key.SetValue("Default DevMode", devModeBytes, RegistryValueKind.Binary);
                        EntNative.Say("已将 DEVMODE 写入注册表 Default DevMode（" + devModeBytes.Length + " 字节）");
                    }
                    else EntNative.Say("[警告] 无法打开注册表项：" + regPath);
                }
            }
            catch (Exception ex) { EntNative.Say("[警告] 写注册表失败：" + ex.Message); }

            EntNative.Say("纸张模式配置完成（" + (widthTenthMm / 10.0) + "×" + (heightTenthMm / 10.0) + " mm）");
            return true;
        }
        catch (Exception ex) { EntNative.Say("[异常] " + ex.Message); return false; }
        finally
        {
            if (pDevMode != IntPtr.Zero) Marshal.FreeHGlobal(pDevMode);
            if (hPrinter != IntPtr.Zero) ClosePrinter(hPrinter);
        }
    }

    /// <summary>WM_SETTINGCHANGE 广播，让资源管理器立即显示新映射的驱动器。</summary>
    public static void BroadcastEnvironmentChange()
    {
        try
        {
            IntPtr result;
            SendMessageTimeout((IntPtr)0xffff, 0x001A, IntPtr.Zero, "Environment", 0x0002, 5000, out result);
            EntNative.Say("已发送刷新通知，资源管理器将显示新映射的驱动器。");
        }
        catch (Exception ex)
        {
            EntNative.Say("[提示] 刷新资源管理器失败：" + ex.Message + "；如看不到映射驱动器请重新打开【此电脑】。");
        }
    }
}

public static class EntLz
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    private static extern IntPtr LZOpenFile(string lpszFile, ref EntOfstruct lpOpenBuff, uint wStyle);

    [DllImport("kernel32.dll")]
    private static extern int LZCopy(IntPtr hfSource, IntPtr hfDest);

    [DllImport("kernel32.dll")]
    private static extern void LZClose(IntPtr hfHandle);

    public static void Decompress(string source, string target)
    {
        EntOfstruct ofSrc = new EntOfstruct();
        ofSrc.cBytes = (byte)Marshal.SizeOf(typeof(EntOfstruct));
        IntPtr hSrc = LZOpenFile(source, ref ofSrc, 0x0000); // OF_READ
        if (hSrc == (IntPtr)(-1))
            throw new Exception("LZOpenFile(源) 失败 错误码=" + Marshal.GetLastWin32Error());

        EntOfstruct ofDst = new EntOfstruct();
        ofDst.cBytes = (byte)Marshal.SizeOf(typeof(EntOfstruct));
        IntPtr hDst = LZOpenFile(target, ref ofDst, 0x1001); // OF_CREATE | OF_WRITE
        if (hDst == (IntPtr)(-1))
        {
            int err = Marshal.GetLastWin32Error();
            LZClose(hSrc);
            throw new Exception("LZOpenFile(目标) 失败 错误码=" + err);
        }
        try
        {
            int ret = LZCopy(hSrc, hDst);
            if (ret < 0) throw new Exception("LZCopy 失败 ret=" + ret);
        }
        finally
        {
            LZClose(hSrc);
            LZClose(hDst);
        }
    }
}
'@

    # Win32Exception lives in System.dll, Registry in mscorlib - both are Add-Type defaults
    Add-Type -TypeDefinition $source
}

function Write-WinUtilEntNativeLog {
    <#
    .SYNOPSIS
        Drains the native helper's pending log lines into the WinUtil log
    #>
    [EntNative]::Drain() | ForEach-Object {
        Write-WinUtilLog -Level "INFO" -Component "Printers" -Message $_
        Write-Host "  $_"
    }
}
