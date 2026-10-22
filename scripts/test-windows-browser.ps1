param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath,
    [string]$BaselineExecutablePath,
    [string]$OutputDirectory = ".build/windows-smoke/browser",
    [ValidateRange(30, 180)]
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = "Stop"
$executable = (Resolve-Path -LiteralPath $ExecutablePath).Path
$baseline = if ($BaselineExecutablePath) { (Resolve-Path -LiteralPath $BaselineExecutablePath).Path } else { $null }
$output = [System.IO.Path]::GetFullPath($OutputDirectory)
[System.IO.Directory]::CreateDirectory($output) | Out-Null
$checksPath = Join-Path $output "browser-checks.json"
$checks = [ordered]@{ realMouseInput = $true; browserAccessibilityFlags = $false; networkTranslationRequests = 0; browsers = @() }

# Only Win32 input/window APIs are used here. In particular, inspecting a browser's
# UI Automation tree before the first selection would hide a cold-renderer bug.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class TransposeBrowserInput {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int X, Y; }
    public sealed class WindowHit { public string hwnd, rootHwnd, rootOwnerHwnd, className; public uint pid; }
    public static WindowHit LastPopupClickHit { get; private set; }
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public UIntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public UIntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)]
    struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mouse;
        [FieldOffset(0)] public KEYBDINPUT keyboard;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public INPUTUNION data; }
    delegate bool EnumWindowProc(IntPtr hwnd, IntPtr parameter);
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowProc callback, IntPtr parameter);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder text, int length);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int length);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rectangle);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    public static void PhysicalCoordinates() {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); SetThreadDpiAwarenessContext(new IntPtr(-4)); }
        catch (EntryPointNotFoundException) { }
    }
    public static IntPtr FindWindow(string className, string title, uint processId, bool visibleOnly) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hwnd, parameter) => {
            uint actualPid;
            GetWindowThreadProcessId(hwnd, out actualPid);
            if (processId != 0 && processId != actualPid) return true;
            if (visibleOnly && !IsWindowVisible(hwnd)) return true;
            var actualClass = new StringBuilder(256);
            GetClassName(hwnd, actualClass, actualClass.Capacity);
            if (actualClass.ToString() != className) return true;
            var actualTitle = new StringBuilder(1024);
            GetWindowText(hwnd, actualTitle, actualTitle.Capacity);
            if (title != null && !actualTitle.ToString().Contains(title)) return true;
            found = hwnd;
            return false;
        }, IntPtr.Zero);
        return found;
    }
    static void Input(INPUT value) {
        if (SendInput(1, new [] { value }, Marshal.SizeOf<INPUT>()) != 1)
            throw new InvalidOperationException("SendInput failed: " + Marshal.GetLastWin32Error());
    }
    static void Mouse(uint flags) { Input(new INPUT { type = 0, data = new INPUTUNION { mouse = new MOUSEINPUT { dwFlags = flags } } }); }
    static void Key(ushort value, bool up) { Input(new INPUT { type = 1, data = new INPUTUNION { keyboard = new KEYBDINPUT { wVk = value, dwFlags = up ? 2u : 0u } } }); }
    public static void SelectAll() {
        Key(0x11, false);
        try { Key(0x41, false); Key(0x41, true); }
        finally { Key(0x11, true); }
    }
    public static void Click(int x, int y) {
        if (!SetCursorPos(x, y)) throw new InvalidOperationException("SetCursorPos failed.");
        Thread.Sleep(80); Mouse(0x0002);
        try { Thread.Sleep(70); } finally { Mouse(0x0004); }
    }
    public static void ClickPopup(int x, int y, IntPtr expected) {
        LastPopupClickHit = null;
        if (!SetCursorPos(x, y)) throw new InvalidOperationException("SetCursorPos failed.");
        Thread.Sleep(80); // Allow the browser's selection menu to react to hovering.
        var hit = WindowFromPoint(new POINT { X = x, Y = y });
        var root = GetAncestor(hit, 2);
        var owner = GetAncestor(hit, 3);
        var className = new StringBuilder(256);
        GetClassName(hit, className, className.Capacity);
        uint pid;
        GetWindowThreadProcessId(hit, out pid);
        LastPopupClickHit = new WindowHit { hwnd = hit.ToInt64().ToString(), rootHwnd = root.ToInt64().ToString(), rootOwnerHwnd = owner.ToInt64().ToString(), className = className.ToString(), pid = pid };
        var expectedClass = new StringBuilder(256);
        GetClassName(expected, expectedClass, expectedClass.Capacity);
        if (expectedClass.ToString() != "TransposeSelection" || (hit != expected && root != expected && owner != expected))
            throw new InvalidOperationException("The translation button is covered by another window: " + className + " (PID " + pid + ", HWND " + hit + ").");
        Mouse(0x0002);
        try { Thread.Sleep(70); } finally { Mouse(0x0004); }
    }
    public static void Drag(int fromX, int fromY, int toX, int toY) {
        if (!SetCursorPos(fromX, fromY)) throw new InvalidOperationException("SetCursorPos failed.");
        Thread.Sleep(80); Mouse(0x0002);
        try {
            Thread.Sleep(100);
            for (int i = 1; i <= 28; ++i) {
                if (!SetCursorPos(fromX + (toX - fromX) * i / 28, fromY + (toY - fromY) * i / 28))
                    throw new InvalidOperationException("SetCursorPos failed while dragging.");
                Thread.Sleep(18);
            }
            Thread.Sleep(80);
        } finally { Mouse(0x0004); }
    }
}
'@

[TransposeBrowserInput]::PhysicalCoordinates()
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

function Save-Checks {
    [System.IO.File]::WriteAllText($checksPath, ($checks | ConvertTo-Json -Depth 12))
}
function Save-Screenshot([string]$Directory, [string]$Name) {
    try {
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $image = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($image)
        try {
            $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size)
            $image.Save((Join-Path $Directory "$Name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $image.Dispose() }
    } catch { Write-Warning "Could not capture the runner desktop: $($_.Exception.Message)" }
}
function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
}
function Wait-For([scriptblock]$Condition, [string]$Description, [int]$Seconds = 5) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (& $Condition) { return }
        if ($script:appProcess -and $script:appProcess.HasExited) { throw "The app exited while waiting for $Description." }
        if ($script:caseDeadline -and [DateTime]::UtcNow -ge $script:caseDeadline) { throw "The browser case exceeded $TimeoutSeconds seconds." }
        Start-Sleep -Milliseconds 80
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Description."
}
function Window-Bounds([IntPtr]$Handle) {
    $rectangle = New-Object TransposeBrowserInput+RECT
    if (-not [TransposeBrowserInput]::GetWindowRect($Handle, [ref]$rectangle)) { throw "Cannot read native window bounds." }
    [pscustomobject]@{ left = $rectangle.Left; top = $rectangle.Top; right = $rectangle.Right; bottom = $rectangle.Bottom; width = $rectangle.Right - $rectangle.Left; height = $rectangle.Bottom - $rectangle.Top }
}
function Browser-Point([double]$X, [double]$Y) {
    $metrics = Read-Json $script:metricsPath
    if (-not $metrics) { throw "The browser fixture did not report its layout." }
    $bounds = Window-Bounds $script:browserHandle
    # Browser chrome is outside innerWidth/innerHeight. Passive page metrics give
    # CSS viewport dimensions; Win32 supplies physical bounds at the current DPI.
    $border = ($bounds.width - $metrics.innerWidth * $metrics.dpr) / 2
    [pscustomobject]@{
        X = [int][Math]::Round($bounds.left + $border + $X * $metrics.dpr)
        Y = [int][Math]::Round($bounds.bottom - $border - $metrics.innerHeight * $metrics.dpr + $Y * $metrics.dpr)
    }
}
function Assert-Clipboard([uint32]$Sequence) {
    if ([TransposeBrowserInput]::GetClipboardSequenceNumber() -ne $Sequence) { throw "The browser selection changed the clipboard." }
}
function Popup-Handle {
    [TransposeBrowserInput]::FindWindow("TransposeSelection", $null, [uint32]$script:appProcess.Id, $true)
}
function Activate-Browser {
    [TransposeBrowserInput]::ShowWindow($script:browserHandle, 9) | Out-Null
    [TransposeBrowserInput]::SetForegroundWindow($script:browserHandle) | Out-Null
    Wait-For { [TransposeBrowserInput]::GetForegroundWindow() -eq $script:browserHandle } "the browser to become foreground"
}
function Assert-FixtureActive([string]$Context) {
    Wait-For { $m = Read-Json $script:metricsPath; $m.visibilityState -eq 'visible' -and $m.hasFocus -eq $true } "the original fixture to be visible and focused $Context"
}
function Clear-Selection {
    Activate-Browser
    Wait-For { $m = Read-Json $script:metricsPath; $m.visibilityState -eq 'visible' } "the original fixture to remain visible before clearing the selection"
    $blank = Browser-Point 12 14
    [TransposeBrowserInput]::Click($blank.X, $blank.Y)
    Start-Sleep -Milliseconds 650
    Wait-For { (Popup-Handle) -eq [IntPtr]::Zero } "the previous selection button to hide"
    Assert-FixtureActive "after clearing the selection"
}
function Check-Selection([string]$Case, [string]$ExpectedText, [bool]$IsBaseline) {
    $before = Read-Json $script:diagnosticsPath
    $callbackCount = if ($before) { [int]$before.selectionCallbacks } else { 0 }
    $sequence = [TransposeBrowserInput]::GetClipboardSequenceNumber()
    Activate-Browser
    Assert-FixtureActive "before the $Case selection"
    $metrics = Read-Json $script:metricsPath
    $rectangle = $metrics.rectangles.$Case
    if (-not $rectangle -or $rectangle.width -le 0) { throw "The page omitted the $Case layout." }
    if ($Case -eq "editable") {
        $inside = Browser-Point ($rectangle.x + 20) ($rectangle.y + $rectangle.height / 2)
        [TransposeBrowserInput]::Click($inside.X, $inside.Y)
        Start-Sleep -Milliseconds 600
        [TransposeBrowserInput]::SelectAll()
        $selectionEnded = [System.Diagnostics.Stopwatch]::GetTimestamp()
        $endpoint = $inside
    } else {
        $from = Browser-Point ($rectangle.x + 1) ($rectangle.y + $rectangle.height / 2)
        # End on its containing group, beyond the text leaf, as users often do.
        $endpoint = Browser-Point ($rectangle.x + $rectangle.width + 28) ($rectangle.y + $rectangle.height / 2)
        [TransposeBrowserInput]::Drag($from.X, $from.Y, $endpoint.X, $endpoint.Y)
        $selectionEnded = [System.Diagnostics.Stopwatch]::GetTimestamp()
    }
    $selectionCheck = [ordered]@{ selectedByNativeInput = $true; endBeyondTextLeaf = $Case -ne 'editable'; popup = $false; clicked = $false }
    $script:caseChecks[$Case] = $selectionCheck
    Save-Checks
    $popup = [IntPtr]::Zero
    # This is a bounded functionality check. Record observed latency rather than
    # treating its five-second timeout as a responsiveness guarantee. Poll before
    # waiting for passive DOM reports so those reports do not inflate the latency.
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $popup = Popup-Handle
        if ($popup -ne [IntPtr]::Zero) {
            $selectionCheck.popupLatencyMs = [Math]::Round(([System.Diagnostics.Stopwatch]::GetTimestamp() - $selectionEnded) * 1000.0 / [System.Diagnostics.Stopwatch]::Frequency, 1)
            break
        }
        Start-Sleep -Milliseconds 80
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($Case -eq "editable") {
        Wait-For { $m = Read-Json $script:metricsPath; $m.activeControl -eq 'editable' -and $m.selectedText -eq $ExpectedText } "the editable input selection"
    } else {
        Wait-For { $m = Read-Json $script:metricsPath; $m.selectedText -and $m.selectedText.Trim() -eq $ExpectedText } "the $Case web text selection"
    }
    if ($popup -eq [IntPtr]::Zero) {
        $selectionCheck.diagnostics = Read-Json $script:diagnosticsPath
        Save-Screenshot $script:caseOutput "$Case-no-button"
        Assert-Clipboard $sequence
        if ($IsBaseline) { return }
        throw "The $Case $($script:browserName) selection did not show a translation button."
    }
    $popupBounds = Window-Bounds $popup
    $selectionCheck.popupBounds = $popupBounds
    $expectedSize = 30 * [TransposeBrowserInput]::GetDpiForWindow($script:browserHandle) / 96
    if ([Math]::Abs($popupBounds.width - $expectedSize) -gt 2 -or [Math]::Abs($popupBounds.height - $expectedSize) -gt 2) { throw "The browser selection popup has the wrong size." }
    $work = [System.Windows.Forms.Screen]::FromHandle($script:browserHandle).WorkingArea
    $buttonSize = [int][Math]::Floor($expectedSize)
    $rawLeft = if ($IsBaseline) { $endpoint.X + 12 } else { $endpoint.X - $buttonSize - 12 }
    $expectedLeft = [Math]::Clamp($rawLeft, $work.Left, $work.Right - $buttonSize)
    $expectedTop = [Math]::Clamp($endpoint.Y + 12, $work.Top, $work.Bottom - $buttonSize)
    $selectionCheck.expectedPopupPosition = @{ left = $expectedLeft; top = $expectedTop; clamped = $expectedLeft -ne $rawLeft -or $expectedTop -ne $endpoint.Y + 12 }
    if ([Math]::Abs($popupBounds.left - $expectedLeft) -gt 18 -or [Math]::Abs($popupBounds.top - $expectedTop) -gt 18) { throw "The browser selection popup is not in its expected position beside the selected text." }
    if ([TransposeBrowserInput]::GetForegroundWindow() -ne $script:browserHandle) { throw "The selection popup stole browser focus." }
    $selectionCheck.popup = $true
    $beforeClick = Read-Json $script:diagnosticsPath
    $fixtureBeforeClick = Read-Json $script:metricsPath
    $selectionCheck.fixtureBeforeClick = @{ visibilityState = $fixtureBeforeClick.visibilityState; hasFocus = $fixtureBeforeClick.hasFocus }
    Save-Screenshot $script:caseOutput "$Case-before-click"
    try {
        [TransposeBrowserInput]::ClickPopup([int]($popupBounds.left + $popupBounds.width / 2), [int]($popupBounds.top + $popupBounds.height / 2), $popup)
    } catch {
        $clickError = $_.Exception.GetBaseException().Message
        if ($IsBaseline -and $clickError.StartsWith("The translation button is covered by another window:")) {
            # The baseline is observational. Record its unsafe hit target without
            # clicking another browser action or preventing the fixed app's test.
            $selectionCheck.clickCovered = $true
            $selectionCheck.clickError = $clickError
            Assert-Clipboard $sequence
            return
        }
        throw
    } finally {
        $selectionCheck.clickHit = [TransposeBrowserInput]::LastPopupClickHit
        Save-Checks
        Save-Screenshot $script:caseOutput "$Case-after-click"
    }
    Wait-For { (Popup-Handle) -eq [IntPtr]::Zero } "the $Case button click"
    $selectionCheck.clicked = $true
    if (-not $IsBaseline) {
        Wait-For { $d = Read-Json $script:diagnosticsPath; $d.selectionCallbacks -eq $callbackCount + 1 -and $d.lastSelectionMatch -eq $true -and $d.lastSelectionCase -eq $Case -and $d.resultFixtureShown -eq $true } "the $Case selection to reach the local result fixture"
        $d = Read-Json $script:diagnosticsPath
        if ($d.networkRequests -ne 0 -or $d.unexpectedSelection -eq $true) { throw "The local browser fixture used an unexpected selection or network translation." }
        $selectionCheck.nativeButtonPress = @{
            downEvents = [int]$d.platform.buttonDowns - [int]$beforeClick.platform.buttonDowns
            upEvents = [int]$d.platform.buttonUps - [int]$beforeClick.platform.buttonUps
            pressedAtEnd = $d.platform.buttonPressed
        }
        if ($selectionCheck.nativeButtonPress.downEvents -lt 1 -or $selectionCheck.nativeButtonPress.upEvents -lt 1 -or $selectionCheck.nativeButtonPress.pressedAtEnd -ne $false) {
            throw "The translation button did not receive a complete native press and release."
        }
        $selectionCheck.textMatched = $true
        $selectionCheck.resultShown = $true
    }
    $afterClick = Read-Json $script:metricsPath
    $selectionCheck.fixtureAfterClick = @{ visibilityState = $afterClick.visibilityState; hasFocus = $afterClick.hasFocus }
    Assert-Clipboard $sequence
    Save-Checks
}

# A loopback-only fixture records layout and native selection outcomes passively.
# It never invokes browser accessibility APIs, translates text, or sets a range.
$serverPath = Join-Path $output "fixture-server.cjs"
$serverReadyPath = Join-Path $output "server.json"
Remove-Item -LiteralPath $serverReadyPath -ErrorAction SilentlyContinue
[System.IO.File]::WriteAllText($serverPath, @'
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const output = process.argv[2];
const cold = 'Transposing words should feel effortless.';
const warm = 'Keep the original close while reading the translation.';
function groups(id, text) {
  let html = `<span id="${id}" class="sample">${text}</span>`;
  for (let i = 0; i < 20; i++) html = `<div role="group" aria-label="${id} group ${i}">${html}</div>`;
  return `<section>${html}</section>`;
}
function page(id) {
  return `<!doctype html><html lang="en"><meta charset="utf-8"><title>Transpose browser fixture ${id}</title>
<style>html{background:white;color:#202124}body{margin:0;padding:28px;font:20px system-ui}h1{font-size:24px;margin:0 0 24px}.sample,input{font:22px/40px Consolas,monospace}.sample{display:inline-block;white-space:nowrap}section{margin:0 0 34px}label{display:block;margin:18px 0 6px}input{display:block;width:600px;box-sizing:border-box;padding:0 10px;height:44px;border:1px solid #777}</style>
<h1>Browser text selection</h1>${groups('cold', cold)}${groups('warm', warm)}
<label for="editable">Editable text</label><input id="editable" value="Editable text can also be translated.">
<label for="password">Password must stay private</label><input id="password" type="password" value="synthetic-private-input">
<script>
function report() {
 const active = document.activeElement;
 const password = active && active.id === 'password';
 const input = active && active.id === 'editable';
 const rectangles = {};
 for (const id of ['cold','warm','editable','password']) { const r = document.getElementById(id).getBoundingClientRect(); rectangles[id] = {x:r.x,y:r.y,width:r.width,height:r.height}; }
 const selectedText = password ? null : input ? active.value.substring(active.selectionStart, active.selectionEnd) : String(window.getSelection());
 const metrics = {ready:true,visibilityState:document.visibilityState,hasFocus:document.hasFocus(),innerWidth,innerHeight,outerWidth,outerHeight,dpr:devicePixelRatio,rectangles,activeControl:active?.id || null,selectedText,selectedLength:password?active.selectionEnd-active.selectionStart:null};
 fetch('/event/${id}', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(metrics),keepalive:true}).catch(()=>{});
}
for (const event of ['selectionchange','mouseup','keyup','resize','focus','blur']) addEventListener(event, report);
document.addEventListener('visibilitychange', report);
setInterval(report,250); report();
</script></html>`;
}
const server = http.createServer((request, response) => {
 response.setHeader('Cache-Control', 'no-store');
 const match = /^\/(fixture|event)\/([a-zA-Z0-9-]+)$/.exec(request.url);
 if (!match) { response.writeHead(404).end(); return; }
 const [, route, id] = match;
 if (route === 'fixture' && request.method === 'GET') { response.setHeader('Content-Type','text/html; charset=utf-8'); response.end(page(id)); return; }
 if (route !== 'event' || request.method !== 'POST' || request.headers.origin !== `http://127.0.0.1:${server.address().port}`) { response.writeHead(403).end(); return; }
 let body = '';
 request.on('data', chunk => { body += chunk; if (body.length > 65536) request.destroy(); });
 request.on('end', () => {
  try { const metrics = JSON.parse(body); const file = path.join(output, 'metrics-' + id + '.json'); fs.writeFileSync(file + '.tmp', JSON.stringify(metrics)); fs.renameSync(file + '.tmp', file); response.writeHead(204).end(); }
  catch { response.writeHead(400).end(); }
 });
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(path.join(output,'server.json'),JSON.stringify({port:server.address().port,pid:process.pid,loopbackOnly:true})));
'@)

$browserDefinitions = @(
    @{ name = "Edge"; paths = @("${env:ProgramFiles(x86)}/Microsoft/Edge/Application/msedge.exe", "$env:ProgramFiles/Microsoft/Edge/Application/msedge.exe") },
    @{ name = "Chrome"; paths = @("$env:ProgramFiles/Google/Chrome/Application/chrome.exe", "${env:ProgramFiles(x86)}/Google/Chrome/Application/chrome.exe", "$env:LOCALAPPDATA/Google/Chrome/Application/chrome.exe") }
)
$server = New-Object System.Diagnostics.Process
$server.StartInfo.FileName = (Get-Command node -ErrorAction Stop).Source
$server.StartInfo.UseShellExecute = $false
$server.StartInfo.RedirectStandardOutput = $true
$server.StartInfo.RedirectStandardError = $true
$server.StartInfo.ArgumentList.Add($serverPath)
$server.StartInfo.ArgumentList.Add($output)
$serverStarted = $false
$script:appProcess = $null
$script:caseDeadline = $null

try {
    if (-not $server.Start()) { throw "The loopback browser fixture did not start." }
    $serverStarted = $true
    $serverOut = $server.StandardOutput.ReadToEndAsync()
    $serverError = $server.StandardError.ReadToEndAsync()
    Wait-For { $s = Read-Json $serverReadyPath; $s.loopbackOnly -eq $true } "the loopback fixture server"
    $serverReport = Read-Json $serverReadyPath
    foreach ($browserDefinition in $browserDefinitions) {
        $browserExecutable = $browserDefinition.paths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $browserExecutable) { throw "$($browserDefinition.name) is required for the Chromium browser regression test." }
        foreach ($phase in @('baseline', 'fixed')) {
            if ($phase -eq 'baseline' -and -not $baseline) { continue }
            $isBaseline = $phase -eq 'baseline'
            $script:browserName = $browserDefinition.name
            $runId = "$($script:browserName.ToLowerInvariant())-$phase-$([guid]::NewGuid().ToString('N'))"
            $script:caseOutput = Join-Path $output "$($script:browserName.ToLowerInvariant())-$phase"
            [System.IO.Directory]::CreateDirectory($script:caseOutput) | Out-Null
            $script:metricsPath = Join-Path $output "metrics-$runId.json"
            $script:diagnosticsPath = Join-Path $script:caseOutput 'diagnostics.json'
            Remove-Item -LiteralPath $script:diagnosticsPath -ErrorAction SilentlyContinue
            $profile = Join-Path ([System.IO.Path]::GetTempPath()) "transpose-browser-$runId"
            $caseResult = [ordered]@{ browser = $script:browserName; phase = $phase; isolatedProfile = $true; cases = [ordered]@{} }
            $script:caseChecks = $caseResult.cases
            $checks.browsers += $caseResult
            Save-Checks
            $script:caseDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
            $script:browserHandle = [IntPtr]::Zero
            $browserPid = [uint32]0
            $browserProcess = $null
            $appStarted = $false
            $browserStarted = $false
            $script:appProcess = New-Object System.Diagnostics.Process
            $script:appProcess.StartInfo.FileName = if ($isBaseline) { $baseline } else { $executable }
            $script:appProcess.StartInfo.UseShellExecute = $false
            $script:appProcess.StartInfo.RedirectStandardOutput = $true
            $script:appProcess.StartInfo.RedirectStandardError = $true
            $script:appProcess.StartInfo.ArgumentList.Add('--background')
            $script:appProcess.StartInfo.ArgumentList.Add($(if ($isBaseline) { '--windows-result-test' } else { '--windows-browser-test' }))
            $script:appProcess.StartInfo.ArgumentList.Add('--diagnostics-output')
            $script:appProcess.StartInfo.ArgumentList.Add($script:diagnosticsPath)
            try {
                if (-not $script:appProcess.Start()) { throw "The browser test app did not start." }
                $appStarted = $true
                $appOut = $script:appProcess.StandardOutput.ReadToEndAsync()
                $appError = $script:appProcess.StandardError.ReadToEndAsync()
                Wait-For { $d = Read-Json $script:diagnosticsPath; $d.ready -eq $true -and $d.window.hwnd } "the browser test app" 30
                $d = Read-Json $script:diagnosticsPath
                if ($d.networkRequests -ne 0) { throw "The browser test app enabled network translation." }
                if ($isBaseline) { [TransposeBrowserInput]::ShowWindow([IntPtr]::new([long]::Parse([string]$d.window.hwnd)), 0) | Out-Null }
                $browserProcess = New-Object System.Diagnostics.Process
                $browserProcess.StartInfo.FileName = $browserExecutable
                $browserProcess.StartInfo.UseShellExecute = $false
                foreach ($argument in @("--user-data-dir=$profile", '--no-first-run', '--no-default-browser-check', '--disable-background-networking', '--disable-component-update', '--disable-sync', '--disable-extensions', '--new-window', "http://127.0.0.1:$($serverReport.port)/fixture/$runId")) { $browserProcess.StartInfo.ArgumentList.Add($argument) }
                if (-not $browserProcess.Start()) { throw "The isolated browser did not start." }
                $browserStarted = $true
                Wait-For { $script:browserHandle = [TransposeBrowserInput]::FindWindow('Chrome_WidgetWin_1', "Transpose browser fixture $runId", 0, $true); $script:browserHandle -ne [IntPtr]::Zero } "the normal browser fixture window" 30
                [TransposeBrowserInput]::GetWindowThreadProcessId($script:browserHandle, [ref]$browserPid) | Out-Null
                $work = [System.Windows.Forms.Screen]::FromHandle($script:browserHandle).WorkingArea
                [TransposeBrowserInput]::ShowWindow($script:browserHandle, 9) | Out-Null
                [TransposeBrowserInput]::SetWindowPos($script:browserHandle, [IntPtr]::Zero, ($work.Left + 24), ($work.Top + 24), [Math]::Min(1180, $work.Width - 48), [Math]::Min(800, $work.Height - 48), 0) | Out-Null
                Activate-Browser
                Wait-For { $m = Read-Json $script:metricsPath; $m.ready -eq $true -and $m.rectangles.password.height -gt 0 } "the passive browser layout metrics"
                Start-Sleep -Milliseconds 650
                $caseResult.browserVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($browserExecutable).ProductVersion
                $caseResult.dpi = [TransposeBrowserInput]::GetDpiForWindow($script:browserHandle)
                $caseResult.browserBounds = Window-Bounds $script:browserHandle
                $caseResult.fixtureDepth = 20
                Save-Screenshot $script:caseOutput '01-ready'
                Check-Selection 'cold' 'Transposing words should feel effortless.' $isBaseline
                Clear-Selection
                Check-Selection 'warm' 'Keep the original close while reading the translation.' $isBaseline
                Clear-Selection
                Check-Selection 'editable' 'Editable text can also be translated.' $isBaseline
                Clear-Selection
                $sequence = [TransposeBrowserInput]::GetClipboardSequenceNumber()
                $beforePassword = Read-Json $script:diagnosticsPath
                $password = (Read-Json $script:metricsPath).rectangles.password
                $point = Browser-Point ($password.x + 20) ($password.y + $password.height / 2)
                [TransposeBrowserInput]::Click($point.X, $point.Y)
                Start-Sleep -Milliseconds 600
                [TransposeBrowserInput]::SelectAll()
                Wait-For { $m = Read-Json $script:metricsPath; $m.activeControl -eq 'password' -and $m.selectedLength -eq 23 } "the synthetic password selection"
                $passwordDeadline = [DateTime]::UtcNow.AddSeconds(2)
                do {
                    if ((Popup-Handle) -ne [IntPtr]::Zero) { throw "Selecting a password exposed a translation button." }
                    Start-Sleep -Milliseconds 100
                } while ([DateTime]::UtcNow -lt $passwordDeadline)
                if (-not $isBaseline -and (Read-Json $script:diagnosticsPath).selectionCallbacks -ne $beforePassword.selectionCallbacks) { throw "A password selection reached the translation callback." }
                Assert-Clipboard $sequence
                $script:caseChecks.password = @{ noButton = $true; noTranslation = $true; clipboardUnchanged = $true }
                $caseResult.passed = $true
                Save-Checks
            } catch {
                $caseResult.passed = $false
                $caseResult.error = $_.Exception.Message
                Save-Checks
                Save-Screenshot $script:caseOutput 'failure'
                [System.IO.File]::WriteAllText((Join-Path $script:caseOutput 'failure.txt'), $_.Exception.Message)
                throw
            } finally {
                if ($browserPid -ne 0) {
                    $actualBrowser = Get-Process -Id $browserPid -ErrorAction SilentlyContinue
                    if ($actualBrowser) { $actualBrowser.Kill($true); $actualBrowser.WaitForExit(5000) | Out-Null; $actualBrowser.Dispose() }
                }
                if ($browserStarted -and -not $browserProcess.HasExited) { $browserProcess.Kill($true); $browserProcess.WaitForExit(5000) | Out-Null }
                # Chromium's first launcher process may exit before its window is
                # created. Limit orphan cleanup to this exact temporary profile.
                Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('chrome.exe', 'msedge.exe') -and $_.CommandLine -and $_.CommandLine.Contains("--user-data-dir=$profile") } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                if ($browserProcess) { $browserProcess.Dispose() }
                if ($appStarted) {
                    if (-not $script:appProcess.HasExited) { $script:appProcess.Kill($true); $script:appProcess.WaitForExit(5000) | Out-Null }
                    [System.IO.File]::WriteAllText((Join-Path $script:caseOutput 'stdout.log'), $appOut.GetAwaiter().GetResult())
                    [System.IO.File]::WriteAllText((Join-Path $script:caseOutput 'stderr.log'), $appError.GetAwaiter().GetResult())
                }
                $script:appProcess.Dispose()
                $script:appProcess = $null
                $script:caseDeadline = $null
                Remove-Item -LiteralPath $profile -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    $checks.passed = $true
    Save-Checks
    Write-Output ($checks | ConvertTo-Json -Depth 12 -Compress)
} catch {
    $checks.passed = $false
    $checks.error = $_.Exception.Message
    Save-Checks
    throw
} finally {
    if ($serverStarted) {
        if (-not $server.HasExited) { $server.Kill($true); $server.WaitForExit(5000) | Out-Null }
        [System.IO.File]::WriteAllText((Join-Path $output 'server-stdout.log'), $serverOut.GetAwaiter().GetResult())
        [System.IO.File]::WriteAllText((Join-Path $output 'server-stderr.log'), $serverError.GetAwaiter().GetResult())
    }
    $server.Dispose()
}
