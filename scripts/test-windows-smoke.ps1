param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath,
    [ValidateSet("App", "Platform")]
    [string]$Mode = "App",
    [string]$OutputDirectory = ".build/windows-smoke",
    [ValidateRange(5, 120)]
    [int]$TimeoutSeconds = 45
)

$ErrorActionPreference = "Stop"
$executable = (Resolve-Path -LiteralPath $ExecutablePath).Path
$output = [System.IO.Path]::GetFullPath($OutputDirectory)
[System.IO.Directory]::CreateDirectory($output) | Out-Null
$reportPath = Join-Path $output "diagnostics.json"
Remove-Item -LiteralPath $reportPath -ErrorAction SilentlyContinue

function Save-FailureScreenshot {
    if (Test-Path -LiteralPath (Join-Path $output "failure.png")) { return }
    try {
        Add-Type -AssemblyName System.Drawing
        Add-Type -AssemblyName System.Windows.Forms
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $image = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($image)
        try {
            $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size)
            $image.Save((Join-Path $output "failure.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        } finally {
            $graphics.Dispose()
            $image.Dispose()
        }
    } catch {
        Write-Warning "Could not capture the runner desktop: $($_.Exception.Message)"
    }
}

$process = New-Object System.Diagnostics.Process
$process.StartInfo.FileName = $executable
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.WorkingDirectory = Split-Path -Parent $executable
$process.StartInfo.RedirectStandardOutput = $true
$process.StartInfo.RedirectStandardError = $true
$testFlag = if ($Mode -eq "Platform") { "--windows-platform-test" } else { "--smoke-test" }
$process.StartInfo.ArgumentList.Add($testFlag)
$process.StartInfo.ArgumentList.Add("--diagnostics-output")
$process.StartInfo.ArgumentList.Add($reportPath)
$started = $false

try {
    if (-not $process.Start()) { throw "The Windows app did not start." }
    $started = $true
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Save-FailureScreenshot
        $process.Kill($true)
        $process.WaitForExit()
        throw "The Windows app did not finish its smoke test within $TimeoutSeconds seconds."
    }
    if ($process.ExitCode -ne 0) {
        throw "The Windows app smoke test exited with code $($process.ExitCode)."
    }
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        throw "The Windows app did not write its diagnostics report."
    }
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    if ($Mode -eq "Platform") {
        if ($report.ocr -ne $true -or $report.freeformFilter -ne $true -or $report.selection -ne $true) {
            throw "A Windows OCR, freeform filter or selection check failed."
        }
        if ($report.screenCapture.width -le 0 -or $report.screenCapture.height -le 0 -or $report.screenCapture.bytes -le 0) {
            throw "The Windows screen capture check returned no pixels."
        }
        if (-not $report.ocrLanguages -or @($report.ocrLanguages).Count -eq 0 -or $report.networkRequests -ne 0) {
            throw "The Windows platform check needs an OCR language and must not make network requests."
        }
        foreach ($check in @("edit", "richEdit", "utf16AndParagraphOffsets", "passwordProtected", "clipboardUnchanged")) {
            if ($report.legacySelection.$check -ne $true) {
                throw "The Windows legacy selection check failed: $check."
            }
        }
    } elseif ($report.tauri -ne $true -or $report.frontend -ne $true -or $report.nativeBridge -ne $true) {
        throw "The Windows app reported an unavailable frontend or native bridge."
    }
    Write-Output ($report | ConvertTo-Json -Compress)
} catch {
    Save-FailureScreenshot
    [System.IO.File]::WriteAllText((Join-Path $output "failure.txt"), $_.Exception.Message)
    throw
} finally {
    if ($started) {
        if (-not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        [System.IO.File]::WriteAllText((Join-Path $output "stdout.log"), $stdout.GetAwaiter().GetResult())
        [System.IO.File]::WriteAllText((Join-Path $output "stderr.log"), $stderr.GetAwaiter().GetResult())
    }
    $process.Dispose()
}
