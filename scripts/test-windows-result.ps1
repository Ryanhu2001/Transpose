param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath,
    [string]$OutputDirectory = ".build/windows-smoke/result",
    [ValidateRange(5, 120)]
    [int]$TimeoutSeconds = 45
)

$ErrorActionPreference = "Stop"
$executable = (Resolve-Path -LiteralPath $ExecutablePath).Path
$output = [System.IO.Path]::GetFullPath($OutputDirectory)
[System.IO.Directory]::CreateDirectory($output) | Out-Null
$diagnosticsPath = Join-Path $output "diagnostics.json"
$checksPath = Join-Path $output "interaction-checks.json"
Remove-Item -LiteralPath $diagnosticsPath, $checksPath -ErrorAction SilentlyContinue

# Exercise the same WebView2 surface, window hit testing and global mouse hooks
# that receive physical user input. No frontend commands are injected by this test.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class TransposeResultInput {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT {
        public int dx, dy;
        public uint mouseData, dwFlags, time;
        public UIntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT {
        public ushort wVk, wScan;
        public uint dwFlags, time;
        public UIntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Explicit)]
    struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mouse;
        [FieldOffset(0)] public KEYBDINPUT keyboard;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public INPUTUNION data; }

    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hwnd, ref POINT point);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")]
    static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")]
    static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")]
    static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll")]
    static extern bool CloseClipboard();
    [DllImport("user32.dll")]
    static extern IntPtr GetClipboardData(uint format);
    [DllImport("kernel32.dll")]
    static extern IntPtr GlobalLock(IntPtr memory);
    [DllImport("kernel32.dll")]
    static extern bool GlobalUnlock(IntPtr memory);

    public static void PhysicalCoordinates() {
        try {
            SetProcessDpiAwarenessContext(new IntPtr(-4));
            SetThreadDpiAwarenessContext(new IntPtr(-4));
        }
        catch (EntryPointNotFoundException) { }
    }
    static void Input(INPUT value) {
        if (SendInput(1, new [] { value }, Marshal.SizeOf<INPUT>()) != 1)
            throw new InvalidOperationException("SendInput failed: " + Marshal.GetLastWin32Error());
    }
    static void Mouse(uint flags) {
        Input(new INPUT { type = 0, data = new INPUTUNION {
            mouse = new MOUSEINPUT { dwFlags = flags }
        }});
    }
    static void Key(ushort value, bool up) {
        Input(new INPUT { type = 1, data = new INPUTUNION {
            keyboard = new KEYBDINPUT { wVk = value, dwFlags = up ? 2u : 0u }
        }});
    }
    public static void CopySelection() {
        Key(0x11, false);
        Key(0x43, false);
        Key(0x43, true);
        Key(0x11, true);
    }
    public static void Click(int x, int y) {
        if (!SetCursorPos(x, y)) throw new InvalidOperationException("SetCursorPos failed.");
        Thread.Sleep(80);
        Mouse(0x0002);
        Thread.Sleep(70);
        Mouse(0x0004);
    }
    public static void Drag(int fromX, int fromY, int toX, int toY) {
        if (!SetCursorPos(fromX, fromY)) throw new InvalidOperationException("SetCursorPos failed.");
        Thread.Sleep(80);
        Mouse(0x0002);
        try {
            Thread.Sleep(100);
            for (int i = 1; i <= 24; ++i) {
                SetCursorPos(fromX + (toX - fromX) * i / 24, fromY + (toY - fromY) * i / 24);
                Thread.Sleep(18);
            }
            Thread.Sleep(80);
        } finally { Mouse(0x0004); }
    }
    public static string ClipboardText() {
        for (int attempt = 0; attempt < 20; ++attempt) {
            if (!OpenClipboard(IntPtr.Zero)) { Thread.Sleep(25); continue; }
            try {
                IntPtr memory = GetClipboardData(13);
                if (memory == IntPtr.Zero) return null;
                IntPtr pointer = GlobalLock(memory);
                if (pointer == IntPtr.Zero) return null;
                try { return Marshal.PtrToStringUni(pointer); }
                finally { GlobalUnlock(memory); }
            } finally { CloseClipboard(); }
        }
        throw new InvalidOperationException("The clipboard could not be opened.");
    }
}
'@

[TransposeResultInput]::PhysicalCoordinates()
$checks = [ordered]@{ realMouseInput = $true }

function Save-Checks {
    [System.IO.File]::WriteAllText($checksPath, ($checks | ConvertTo-Json -Depth 8))
}

function Save-Screenshot([string]$Name) {
    try {
        Add-Type -AssemblyName System.Drawing
        Add-Type -AssemblyName System.Windows.Forms
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $image = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($image)
        try {
            $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size)
            $image.Save((Join-Path $output "$Name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $image.Dispose() }
    } catch { Write-Warning "Could not capture the runner desktop: $($_.Exception.Message)" }
}

function Read-Diagnostics {
    if (-not (Test-Path -LiteralPath $diagnosticsPath -PathType Leaf)) { return $null }
    try { Get-Content -LiteralPath $diagnosticsPath -Raw | ConvertFrom-Json }
    catch { return $null } # A report update may overlap this read.
}

function Wait-For([scriptblock]$Condition, [string]$Description, [int]$Seconds = 5) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (& $Condition) { return }
        if ($process.HasExited) { throw "The app exited while waiting for $Description." }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Description."
}

function Window-Bounds {
    $rectangle = New-Object TransposeResultInput+RECT
    if (-not [TransposeResultInput]::GetWindowRect($script:resultHandle, [ref]$rectangle)) {
        throw "Could not read the translation window bounds."
    }
    [pscustomobject]@{
        left = $rectangle.Left; top = $rectangle.Top
        right = $rectangle.Right; bottom = $rectangle.Bottom
        width = $rectangle.Right - $rectangle.Left
        height = $rectangle.Bottom - $rectangle.Top
    }
}

function Client-Point([double]$X, [double]$Y) {
    $point = New-Object TransposeResultInput+POINT
    $point.X = [int][Math]::Round($X * $script:scale)
    $point.Y = [int][Math]::Round($Y * $script:scale)
    if (-not [TransposeResultInput]::ClientToScreen($script:resultHandle, [ref]$point)) {
        throw "Could not locate the translation window client area."
    }
    $point
}

function Client-Size {
    $rectangle = New-Object TransposeResultInput+RECT
    if (-not [TransposeResultInput]::GetClientRect($script:resultHandle, [ref]$rectangle)) {
        throw "Could not read the translation window client size."
    }
    [pscustomobject]@{
        width = ($rectangle.Right - $rectangle.Left) / $script:scale
        height = ($rectangle.Bottom - $rectangle.Top) / $script:scale
    }
}

function Assert-Visible([string]$Context) {
    if (-not [TransposeResultInput]::IsWindowVisible($script:resultHandle)) {
        throw "The translation window disappeared $Context."
    }
}

$process = New-Object System.Diagnostics.Process
$process.StartInfo.FileName = $executable
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.WorkingDirectory = Split-Path -Parent $executable
$process.StartInfo.RedirectStandardOutput = $true
$process.StartInfo.RedirectStandardError = $true
$process.StartInfo.ArgumentList.Add("--windows-result-test")
$process.StartInfo.ArgumentList.Add("--diagnostics-output")
$process.StartInfo.ArgumentList.Add($diagnosticsPath)
$started = $false

try {
    if (-not $process.Start()) { throw "The Windows result fixture did not start." }
    $started = $true
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    Wait-For { $report = Read-Diagnostics; $report -and $report.ready -eq $true } "the result fixture" $TimeoutSeconds
    $report = Read-Diagnostics
    if (-not $report.fixtureText -or -not $report.window.hwnd) {
        throw "The fixture report omitted its expected text or window handle."
    }
    if ($report.networkRequests -ne 0) { throw "The result fixture must not make network requests." }
    $checks.networkRequests = $report.networkRequests
    $script:resultHandle = [IntPtr]::new([long]::Parse([string]$report.window.hwnd))
    $script:scale = [TransposeResultInput]::GetDpiForWindow($script:resultHandle) / 96.0
    if ($script:scale -le 0) { throw "The translation window has no usable DPI." }
    [TransposeResultInput]::ShowWindow($script:resultHandle, 9) | Out-Null
    [TransposeResultInput]::SetForegroundWindow($script:resultHandle) | Out-Null
    Start-Sleep -Milliseconds 500
    Assert-Visible "before interaction"
    $before = Window-Bounds
    $checks.initialBounds = $before
    $checks.dpi = 96 * $script:scale
    Save-Screenshot "01-ready"

    $from = Client-Point 180 22
    $deltaX = [int][Math]::Round(150 * $script:scale)
    $deltaY = [int][Math]::Round(90 * $script:scale)
    [TransposeResultInput]::Drag($from.X, $from.Y, $from.X + $deltaX, $from.Y + $deltaY)
    Start-Sleep -Milliseconds 800
    $after = Window-Bounds
    if ([Math]::Abs(($after.left - $before.left) - $deltaX) -gt 12 -or
        [Math]::Abs(($after.top - $before.top) - $deltaY) -gt 12) {
        throw "Dragging the header did not move the window by the mouse displacement."
    }
    Assert-Visible "after dragging its header"
    $checks.headerDrag = $true
    $checks.draggedBounds = $after
    Save-Checks
    Save-Screenshot "02-dragged"

    # The real selection hook must classify WebView2 child HWNDs as our own UI.
    $from = Client-Point 22 73
    $to = Client-Point 280 73
    [TransposeResultInput]::Drag($from.X, $from.Y, $to.X, $to.Y)
    Start-Sleep -Milliseconds 1200
    Assert-Visible "after selecting its own translation"
    $selectedBounds = Window-Bounds
    if ([Math]::Abs($selectedBounds.left - $after.left) -gt 3 -or
        [Math]::Abs($selectedBounds.top - $after.top) -gt 3) {
        throw "Selecting translation text moved the window."
    }
    [TransposeResultInput]::CopySelection()
    Start-Sleep -Milliseconds 250
    $selection = [TransposeResultInput]::ClipboardText()
    if (-not $selection -or $selection.Length -lt 8 -or
        $selection.Length -ge $report.fixtureText.Length -or -not $report.fixtureText.Contains($selection)) {
        throw "Dragging over the translation did not produce selectable text."
    }
    $checks.bodySelection = $true
    $checks.bodySelectionKeepsPosition = $true
    Save-Checks

    $size = Client-Size
    $pin = Client-Point ($size.width - 56) 22
    [TransposeResultInput]::Click($pin.X, $pin.Y)
    Wait-For { $state = Read-Diagnostics; $state.result.isPinned -eq $true } "the pin button to update the result"
    [TransposeResultInput]::Click(20, 20)
    Start-Sleep -Milliseconds 800
    Assert-Visible "after pinning it and clicking the desktop"
    $checks.pinClick = $true
    $checks.pinnedSurvivesOutsideClick = $true
    Save-Checks

    $copy = Client-Point ($size.width - 49) ($size.height - 19)
    [TransposeResultInput]::Click($copy.X, $copy.Y)
    Wait-For { [TransposeResultInput]::ClipboardText() -eq $report.fixtureText } "the Copy button to copy the fixture text"
    Assert-Visible "after clicking Copy"
    $checks.copyClick = $true
    Save-Checks

    $resize = Client-Point ($size.width - 7) ($size.height - 7)
    $tooSmall = Client-Point 90 80
    [TransposeResultInput]::Drag($resize.X, $resize.Y, $tooSmall.X, $tooSmall.Y)
    Start-Sleep -Milliseconds 500
    $minimumSize = Client-Size
    $minimumWidth = if ($report.window.minWidth) { [double]$report.window.minWidth } else { 360 }
    $minimumHeight = if ($report.window.minHeight) { [double]$report.window.minHeight } else { 180 }
    if ($minimumSize.width -lt $minimumWidth - 2 -or $minimumSize.height -lt $minimumHeight - 2) {
        throw "The resize handle allowed the result window below its minimum size."
    }
    if ($minimumSize.width -ge $size.width - 10 -or $minimumSize.height -ge $size.height - 10) {
        throw "The resize handle did not resize the translation window."
    }
    Assert-Visible "after resizing"
    $checks.minimumResize = $true
    $checks.minimumClientSize = $minimumSize
    Save-Checks
    Save-Screenshot "03-minimum"

    $close = Client-Point ($minimumSize.width - 25) 22
    [TransposeResultInput]::Click($close.X, $close.Y)
    Wait-For { -not [TransposeResultInput]::IsWindowVisible($script:resultHandle) } "the Close button to hide the translation window"
    $checks.closeClick = $true
    $checks.passed = $true
    Save-Checks
    Write-Output ($checks | ConvertTo-Json -Depth 8 -Compress)
} catch {
    $checks.passed = $false
    $checks.error = $_.Exception.Message
    Save-Checks
    Save-Screenshot "failure"
    [System.IO.File]::WriteAllText((Join-Path $output "failure.txt"), $_.Exception.Message)
    throw
} finally {
    if ($started) {
        if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        [System.IO.File]::WriteAllText((Join-Path $output "stdout.log"), $stdout.GetAwaiter().GetResult())
        [System.IO.File]::WriteAllText((Join-Path $output "stderr.log"), $stderr.GetAwaiter().GetResult())
    }
    $process.Dispose()
}
