#Requires -Version 5.1
<#
    logic-tests.ps1 -- regression tests for winshot2clip.ps1

    Covers both trigger paths and everything around them: eligibility,
    the settle check, dedupe, retry, give-up, the event queue, the
    reconciliation backstop, and the wiring that decides when a scan
    happens at all.

    What is NOT covered, and cannot be: the Windows clipboard call
    (System.Windows.Forms). That is what -SelfTest is for. Everything
    else runs for real here, including real FileSystemWatchers.

    How it works without Windows:
      The function definitions are lifted out of winshot2clip.ps1 with
      the PowerShell parser, so the script's top-level code (the
      Add-Type of System.Windows.Forms, the argument dispatch, the mutex)
      never runs. Set-ClipboardFile is then redefined by this file, so the
      state machine is exercised against a recording fake instead of the
      real clipboard.

    Run:
      pwsh   -File logic-tests.ps1
      powershell.exe -File logic-tests.ps1

    Exits 0 when everything passes, otherwise the number of failures.

    ASCII-only on purpose, same reason as the script under test.
#>

param(
    [string] $ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'winshot2clip.ps1')
)

$ErrorActionPreference = 'Stop'

# A run that dies part way through (an unexpected exception, an aborted run)
# must not leave its scratch directory behind. The happy path still cleans up
# in the result section; this covers everything else.
trap {
    if ($global:TestRoot) {
        Remove-Item -LiteralPath $global:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host ''
    Write-Host "ABORTED: $($_.Exception.Message)"
    exit 1
}

$global:Failures = 0
$global:Calls    = New-Object System.Collections.ArrayList
$global:FailFor  = $null

function Assert {
    param([string] $Name, [bool] $Condition, [string] $Detail = '')
    if ($Condition) {
        Write-Host "  PASS  $Name"
    }
    else {
        Write-Host "  FAIL  $Name"
        if ($Detail) { Write-Host "        $Detail" }
        $global:Failures++
    }
}

function Section {
    param([string] $Title)
    Write-Host ''
    Write-Host "-- $Title"
}

function New-TestDir {
    param([string] $Tag)
    $p = Join-Path $global:TestRoot $Tag
    Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
    $null = New-Item -ItemType Directory -Path $p -Force
    return $p
}

# A real, CRC-valid 1x1 RGBA PNG (68 bytes).
$ProbePng = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNgAAIAAAUAAen63NgAAAAASUVORK5CYII='

# --------------------------------------------------- load script under test --

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Host "cannot find $ScriptPath"
    exit 1
}

$parseErrors = $null
$tokens      = $null
$ast         = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref] $tokens, [ref] $parseErrors)

Section 'syntax'
Assert 'winshot2clip.ps1 parses without syntax errors' ($parseErrors.Count -eq 0) `
       (($parseErrors | Select-Object -First 3 | ForEach-Object { $_.Message }) -join ' / ')

if ($parseErrors.Count -ne 0) {
    Write-Host ''
    Write-Host "$($parseErrors.Count) parse error(s); aborting."
    exit $parseErrors.Count
}

$functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
               ForEach-Object { $_.Extent.Text })
Assert 'function definitions were found' ($functions.Count -gt 0) "found $($functions.Count)"

Section 'source hygiene (Windows PowerShell 5.1 safety)'

$rawBytes  = [IO.File]::ReadAllBytes($ScriptPath)
$highBytes = @($rawBytes | Where-Object { $_ -gt 127 })
Assert 'the script is pure ASCII, so PS 5.1 never mis-decodes it' ($highBytes.Count -eq 0) `
       "found $($highBytes.Count) byte(s) above 127"
Assert 'the script carries no UTF-8 BOM' (-not ($rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF))

$rawText = [IO.File]::ReadAllText($ScriptPath)
Assert 'no PowerShell 7 only operators (&&, ||, ??, ?.)' (-not ($rawText -match '\|\||&&|\?\?|\?\.')) `
       'these parse on pwsh 7 but are syntax errors on Windows PowerShell 5.1'
Assert 'no call to Set-Clipboard -Path (removed in PowerShell 7, 5.1 only)' (-not ($rawText -match 'Set-Clipboard\s'))

$global:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('winshot2clip-logictest-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $global:TestRoot -Force

# The harness must run with the SAME config values the program ships, or the
# suite can stay green while the real configuration is broken (and a change to
# production would leave the tests asserting yesterday's numbers). Read them
# out of the production source instead of restating them here.
function Get-ProductionScriptVar {
    param($ScriptAst, [string] $Name)
    $assignment = @($ScriptAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq "`$script:$Name"
    }, $true)) | Select-Object -First 1
    if ($null -eq $assignment) { return $null }
    return & ([scriptblock]::Create($assignment.Right.Extent.Text))
}

function Get-ProductionParamDefault {
    param($ScriptAst, [string] $Name)
    if ($null -eq $ScriptAst.ParamBlock) { return $null }
    $p = @($ScriptAst.ParamBlock.Parameters |
           Where-Object { $_.Name.VariablePath.UserPath -eq $Name }) | Select-Object -First 1
    if ($null -eq $p -or $null -eq $p.DefaultValue) { return $null }
    return & ([scriptblock]::Create($p.DefaultValue.Extent.Text))
}

$prodExtensions  = @(Get-ProductionScriptVar -ScriptAst $ast -Name 'Extensions')
$prodMaxAttempts = Get-ProductionScriptVar -ScriptAst $ast -Name 'MaxAttempts'
$prodEventSource = Get-ProductionScriptVar -ScriptAst $ast -Name 'EventSource'
$prodFilter      = @(Get-ProductionParamDefault -ScriptAst $ast -Name 'Filter')

Section 'harness configuration comes from production'
Assert 'production $script:Extensions was read from the source' ($prodExtensions.Count -gt 0) "got $($prodExtensions.Count)"
Assert 'production $script:MaxAttempts was read from the source' ($null -ne $prodMaxAttempts)
Assert 'production $script:EventSource was read from the source' (-not [string]::IsNullOrEmpty($prodEventSource))
Assert 'production -Filter default was read from the param block' ($prodFilter.Count -gt 0) "got $($prodFilter.Count)"

$prodExtensionList = ($prodExtensions | ForEach-Object { "'$_'" }) -join ', '

# The preamble goes into the same scriptblock as the definitions, so whatever
# $script: resolves to, the functions and these values agree.
$preamble = @"
`$script:LogFile     = '$($global:TestRoot -replace '\\', '/')/run.log'
`$script:Extensions  = @($prodExtensionList)
`$script:MaxAttempts = $prodMaxAttempts
`$script:EventSource = '$prodEventSource'
"@

. ([scriptblock]::Create($preamble + "`n" + ($functions -join "`n`n")))

# Recording fake for the Windows-only clipboard call.
function Set-ClipboardFile {
    param([string] $Path)
    [void] $global:Calls.Add($Path)
    if ($null -ne $global:FailFor -and $Path -eq $global:FailFor) {
        throw 'simulated CLIPBRD_E_CANT_OPEN'
    }
    return 1
}

function New-Probe {
    param([string] $Dir, [string] $Name)
    $p = Join-Path $Dir $Name
    [IO.File]::WriteAllBytes($p, [Convert]::FromBase64String($ProbePng))
    return $p
}

function New-TextFile {
    param([string] $Dir, [string] $Name, [string] $Content)
    $p = Join-Path $Dir $Name
    Set-Content -LiteralPath $p -Value $Content -NoNewline
    return $p
}

# ------------------------------------------------------------- eligibility ---

Section 'eligibility'

$dirA  = New-TestDir 'eligibility'
$good  = New-Probe $dirA 'Screenshot good.png'
$upper = New-Probe $dirA 'Screenshot upper.PNG'
$other = New-Probe $dirA 'holiday.png'
$bmp   = New-TextFile $dirA 'Screenshot weird.bmp' 'x'
$noext = New-TextFile $dirA 'Screenshot noextension' 'x'
$sub   = Join-Path $dirA 'Screenshot subdir'
$null  = New-Item -ItemType Directory -Path $sub -Force

Assert 'a matching screenshot is eligible' (Test-ScreenshotPath -Path $good -Pattern 'Screenshot*')
Assert 'an uppercase extension is eligible' (Test-ScreenshotPath -Path $upper -Pattern 'Screenshot*')
Assert 'a non-matching name is rejected' (-not (Test-ScreenshotPath -Path $other -Pattern 'Screenshot*'))
Assert 'a non-whitelisted extension is rejected' (-not (Test-ScreenshotPath -Path $bmp -Pattern 'Screenshot*'))
Assert 'a missing extension is rejected' (-not (Test-ScreenshotPath -Path $noext -Pattern 'Screenshot*'))
Assert 'a directory is rejected (Created fires for those too)' (-not (Test-ScreenshotPath -Path $sub -Pattern 'Screenshot*'))
Assert 'a path that does not exist is rejected' (-not (Test-ScreenshotPath -Path (Join-Path $dirA 'Screenshot gone.png') -Pattern 'Screenshot*'))
Assert 'an empty path is rejected' (-not (Test-ScreenshotPath -Path '' -Pattern 'Screenshot*'))

# ----------------------------------------------------------- settle check ----

Section 'settle check'

$settled = New-Probe $dirA 'Screenshot settled.png'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$ok = Wait-FileSettled -Path $settled -TimeoutMs 5000
$sw.Stop()
Assert 'a complete file settles' $ok
Assert 'and it settles quickly' ($sw.ElapsedMilliseconds -lt 1000) "took $($sw.ElapsedMilliseconds)ms"

$empty = New-TextFile $dirA 'Screenshot empty.png' ''
Assert 'a file that is still 0 bytes never settles' (-not (Wait-FileSettled -Path $empty -TimeoutMs 400))
Assert 'a file that does not exist never settles' (-not (Wait-FileSettled -Path (Join-Path $dirA 'nope.png') -TimeoutMs 200))

# A writer that keeps appending must not be mistaken for a finished one.
# SetLength grows the file without writing data, so this stays a sparse
# file; the pause is 10ms against a 100ms sampling interval, so the size
# can never look unchanged across two samples while the writer runs.
$growing = New-TextFile $dirA 'Screenshot growing.png' ''
$job = Start-Job -ScriptBlock {
    param($path)
    $fs  = [System.IO.File]::Open($path, 'Open', 'Write', 'ReadWrite')
    try {
        $len = 0
        $sw  = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 1.2) {
            $len += 524288
            $fs.SetLength($len)
            $fs.Flush()
            Start-Sleep -Milliseconds 10
        }
    }
    finally { $fs.Close() }
} -ArgumentList $growing

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$ok = Wait-FileSettled -Path $growing -TimeoutMs 20000
$sw.Stop()
Assert 'a file being actively appended to settles only after the writer stops' `
       ($ok -and $sw.ElapsedMilliseconds -ge 1000) "ok=$ok elapsed=$($sw.ElapsedMilliseconds)ms"
Assert 'and it is non-empty when it does' ((Get-Item -LiteralPath $growing).Length -gt 0)
$null = Wait-Job -Job $job -Timeout 30
Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

# -------------------------------------------------------------- scan path ----

Section 'baseline and scan pass'

$dirB = New-TestDir 'scan'
$null = New-Probe $dirB 'Screenshot b1.png'
$null = New-Probe $dirB 'Screenshot b2.png'
$null = New-Probe $dirB 'ignored.png'

$seen = New-SeenSet -Dir $dirB -Pattern 'Screenshot*'
Assert 'New-SeenSet returns a hashtable' ($seen -is [hashtable]) "got $($seen.GetType().FullName)"
Assert 'baseline contains only the matching files' ($seen.Count -eq 2) "got $($seen.Count)"
Assert 'baseline does not contain the non-matching file' (-not $seen.ContainsKey((Join-Path $dirB 'ignored.png')))

$pending = @{}
$global:Calls.Clear()
$copied = Invoke-ScanPass -Dir $dirB -Pattern 'Screenshot*' -Seen $seen -Pending $pending -SettleTimeoutMs 5000
Assert 'a scan pass copies nothing when everything is already seen' ($copied -eq 0 -and $global:Calls.Count -eq 0)

$b3 = New-Probe $dirB 'Screenshot b3.png'
$copied = Invoke-ScanPass -Dir $dirB -Pattern 'Screenshot*' -Seen $seen -Pending $pending -SettleTimeoutMs 5000
Assert 'a scan pass copies a new file' ($copied -eq 1) "got $copied"
Assert 'and it is the new file that landed on the clipboard' ($global:Calls.Count -eq 1 -and $global:Calls[0] -eq $b3)
Assert 'and it is now marked seen' ($seen.ContainsKey($b3))

$copied = Invoke-ScanPass -Dir $dirB -Pattern 'Screenshot*' -Seen $seen -Pending $pending -SettleTimeoutMs 5000
Assert 'a second scan pass does not copy it again' ($copied -eq 0)
Assert 'the non-matching file was never copied' (-not ($global:Calls -contains (Join-Path $dirB 'ignored.png')))

# A6: the baseline remembers a version, not merely a path.
Set-Content -LiteralPath $b3 -Value 'b3 changed after the baseline was taken, so it is longer now'
$copied = Invoke-ScanPass -Dir $dirB -Pattern 'Screenshot*' -Seen $seen -Pending $pending -SettleTimeoutMs 5000
Assert 'a baseline file that changed afterwards is copied (A6)' ($copied -eq 1) "copied=$copied"
$copied = Invoke-ScanPass -Dir $dirB -Pattern 'Screenshot*' -Seen $seen -Pending $pending -SettleTimeoutMs 5000
Assert 'and then it settles back to being skipped' ($copied -eq 0)

Assert 'a scan pass against a missing directory returns 0' `
       ((Invoke-ScanPass -Dir (Join-Path $global:TestRoot 'nope') -Pattern 'Screenshot*' -Seen @{} -Pending @{} -SettleTimeoutMs 200) -eq 0)

# ------------------------------------------------------- retry and give up ---

Section 'retry and give up'

$dirC = New-TestDir 'retry'
$seenC    = @{}
$pendingC = @{}
$c1 = New-Probe $dirC 'Screenshot c1.png'

$global:Calls.Clear()
$global:FailFor = $c1
$handled = Copy-ScreenshotFile -Path $c1 -Pattern 'Screenshot*' -Seen $seenC -Pending $pendingC -SettleTimeoutMs 5000
Assert 'a failed copy is reported as not handled' (-not $handled)
Assert 'a failed copy is not marked seen' (-not $seenC.ContainsKey($c1))
Assert 'a failed copy is queued with one attempt' ($pendingC[$c1] -eq 1) "got $($pendingC[$c1])"

$global:FailFor = $null
$retried = Invoke-RetryPending -Pattern 'Screenshot*' -Seen $seenC -Pending $pendingC -SettleTimeoutMs 5000
Assert 'the retry path retries it' ($retried -eq 1)
Assert 'and it now succeeds' ($seenC.ContainsKey($c1))
Assert 'and it is no longer pending' (-not $pendingC.ContainsKey($c1))

$c2 = New-Probe $dirC 'Screenshot c2.png'
$global:Calls.Clear()
$global:FailFor = $c2
$null = Copy-ScreenshotFile -Path $c2 -Pattern 'Screenshot*' -Seen $seenC -Pending $pendingC -SettleTimeoutMs 5000
Assert 'scan path: a file queued for retry is skipped by the scan' `
       (-not (Copy-ScreenshotFile -Path $c2 -Pattern 'Screenshot*' -Seen $seenC -Pending $pendingC -SettleTimeoutMs 5000 -SkipPending))

$before = $pendingC[$c2]
$null = Copy-ScreenshotFile -Path $c2 -Pattern 'Screenshot*' -Seen $seenC -Pending $pendingC -SettleTimeoutMs 5000
Assert 'each attempt is counted' ($pendingC[$c2] -eq $before + 1) "was $before, now $($pendingC[$c2])"

$null = Copy-ScreenshotFile -Path $c2 -Pattern 'Screenshot*' -Seen $seenC -Pending $pendingC -SettleTimeoutMs 5000
Assert 'it gives up on the third attempt' ($seenC.ContainsKey($c2) -and -not $pendingC.ContainsKey($c2)) `
       "attempts=$($pendingC[$c2])"

$callsBefore = $global:Calls.Count
$null = Copy-ScreenshotFile -Path $c2 -Pattern 'Screenshot*' -Seen $seenC -Pending $pendingC -SettleTimeoutMs 5000
Assert 'a given-up file is never touched again' ($global:Calls.Count -eq $callsBefore)
$global:FailFor = $null

Section 'dedupe'

# $c1 was copied earlier in this file, so its signature is in $seenC and the
# file has not been touched since.
$global:Calls.Clear()
Assert 'a path whose content has not changed is skipped' `
       (-not (Copy-ScreenshotFile -Path $c1 -Pattern 'Screenshot*' -Seen $seenC -Pending $pendingC -SettleTimeoutMs 5000))
Assert 'and nothing was put on the clipboard' ($global:Calls.Count -eq 0)
Assert 'a non-matching file is skipped by Copy-ScreenshotFile' `
       (-not (Copy-ScreenshotFile -Path (New-Probe $dirC 'holiday.png') -Pattern 'Screenshot*' -Seen $seenC -Pending $pendingC -SettleTimeoutMs 5000))
Assert 'a directory is skipped by Copy-ScreenshotFile' `
       (-not (Copy-ScreenshotFile -Path $dirC -Pattern 'Screenshot*' -Seen $seenC -Pending $pendingC -SettleTimeoutMs 5000))

Section 'A6: the same path written again is new content, not a duplicate'

# Deliberately a different length, so this does not depend on mtime granularity.
Set-Content -LiteralPath $c1 -Value 'c1 rewritten by A6, deliberately a different length than before'
$global:Calls.Clear()
Assert 'a rewritten file at an already-seen path is copied again' `
       (Copy-ScreenshotFile -Path $c1 -Pattern 'Screenshot*' -Seen $seenC -Pending $pendingC -SettleTimeoutMs 5000)
Assert 'and the clipboard was updated' ($global:Calls.Count -eq 1 -and $global:Calls[0] -eq $c1)
Assert 'and the new version is the one now remembered' (Test-AlreadyCopied -Path $c1 -Seen $seenC)
Assert 'so a further pass with unchanged content is skipped again' `
       (-not (Copy-ScreenshotFile -Path $c1 -Pattern 'Screenshot*' -Seen $seenC -Pending $pendingC -SettleTimeoutMs 5000))

# A changed file that is sitting in the retry queue is not obsolete.
$c6 = New-Probe $dirC 'Screenshot c6.png'
$seen6 = @{}
$pending6 = @{}
$global:FailFor = $c6
$null = Copy-ScreenshotFile -Path $c6 -Pattern 'Screenshot*' -Seen $seen6 -Pending $pending6 -SettleTimeoutMs 5000
Assert 'a failed copy is queued' ($pending6.ContainsKey($c6))
$global:FailFor = $null
Set-Content -LiteralPath $c6 -Value 'c6 changed while it was waiting to be retried, different length'
Assert 'so the queued retry is NOT treated as obsolete' ((Invoke-RetryPending -Pattern 'Screenshot*' -Seen $seen6 -Pending $pending6 -SettleTimeoutMs 5000) -eq 1)
Assert 'and the new content reached the clipboard' ($seen6.ContainsKey($c6))

# ------------------------------------------------------------- event path ----

Section 'event path (real FileSystemWatcher)'

$dirE = New-TestDir 'events'
$seenE    = @{}
$pendingE = @{}
$srcE = 'LogicTestEvent'
$watcherE = New-ScreenshotWatcher -Dir $dirE -EventSource $srcE
try {
    Assert 'the watcher is armed' ($watcherE.EnableRaisingEvents)
    Assert 'the watcher uses the maximum kernel buffer' ($watcherE.InternalBufferSize -eq 65536)
    Assert 'only FileName changes are subscribed' `
           ($watcherE.NotifyFilter -eq [System.IO.NotifyFilters]::FileName)
    Assert 'the watcher takes every filename and leaves matching to Test-ScreenshotPath' `
           ($watcherE.Filter -eq '*') "got '$($watcherE.Filter)'"

    # A Created event on a file that matches the filter.
    $e1 = New-Probe $dirE 'Screenshot event1.png'
    $r = Invoke-EventCycle -Pattern 'Screenshot*' -Seen $seenE -Pending $pendingE `
                           -TimeoutSeconds 5 -EventSource $srcE -SettleTimeoutMs 5000
    Assert 'a created file produces an event' ($r.Handled -ge 1) "handled=$($r.Handled)"
    Assert 'and the event path copies it' ($r.Copied -eq 1) "copied=$($r.Copied)"
    Assert 'and the clipboard got exactly that path' ($global:Calls.Count -ge 1 -and $global:Calls[$global:Calls.Count - 1] -eq $e1)
    Assert 'and it is marked seen' ($seenE.ContainsKey($e1))
    Assert 'and no scan was needed' (-not $r.NeedScan)

    # FileSystemWatcher.Filter takes a single wildcard and the default filter
    # list has two, so the watcher now sees every file and the eligibility
    # check is what rejects it. What matters is that nothing reaches the
    # clipboard.
    $callsBefore = $global:Calls.Count
    $null = New-Probe $dirE 'holiday-event.png'
    $r = Invoke-EventCycle -Pattern 'Screenshot*' -Seen $seenE -Pending $pendingE `
                           -TimeoutSeconds 2 -EventSource $srcE -SettleTimeoutMs 2000
    Assert 'a non-matching file raises an event that is then rejected' `
           ($r.Handled -ge 1 -and $r.Copied -eq 0) "handled=$($r.Handled) copied=$($r.Copied)"
    Assert 'and nothing was copied' ($global:Calls.Count -eq $callsBefore)

    # A file that was renamed into the folder (the temp-file-then-rename
    # pattern a screenshot tool may use). Whether .NET reports this as
    # Renamed or as Created depends on whether it can pair the names, so
    # the assertion is on the outcome, not on the event name.
    $staging = Join-Path $global:TestRoot 'staging'
    $null = New-Item -ItemType Directory -Path $staging -Force
    $moved = Join-Path $dirE 'Screenshot moved.png'
    [IO.File]::WriteAllBytes((Join-Path $staging 'tmp.png'), [Convert]::FromBase64String($ProbePng))
    [System.IO.File]::Move((Join-Path $staging 'tmp.png'), $moved)

    $r = Invoke-EventCycle -Pattern 'Screenshot*' -Seen $seenE -Pending $pendingE `
                           -TimeoutSeconds 5 -EventSource $srcE -SettleTimeoutMs 5000
    Assert 'a file renamed into the folder is copied' ($r.Copied -eq 1) "copied=$($r.Copied) handled=$($r.Handled)"
    Assert 'and the path used is the final name, in the watched folder' ($seenE.ContainsKey($moved))

    # An overflow is reported through the Error subscription.
    $null = New-Event -SourceIdentifier ($srcE + '.Error')
    $r = Invoke-EventCycle -Pattern 'Screenshot*' -Seen $seenE -Pending $pendingE `
                           -TimeoutSeconds 5 -EventSource $srcE -SettleTimeoutMs 2000
    Assert 'an Error event sets NeedScan' ($r.NeedScan)
    Assert 'an Error event is not mistaken for a file' ($r.Copied -eq 0)

    # A directory must never be copied. With NotifyFilter = FileName the
    # kernel does not even report directory creation (FILE_NOTIFY_CHANGE_
    # FILE_NAME covers files; directories would need DirectoryName), so
    # this also proves the guard works if that ever changes: a synthetic
    # directory-shaped event is pushed into the queue by hand.
    $callsBefore = $global:Calls.Count
    $adir = Join-Path $dirE 'Screenshot adir'
    $null = New-Item -ItemType Directory -Path $adir -Force
    $dirEventArgs = New-Object System.IO.FileSystemEventArgs([System.IO.WatcherChangeTypes]::Created, $dirE, 'Screenshot adir')
    $null = New-Event -SourceIdentifier ($srcE + '.Created') -EventArguments @($dirEventArgs)
    $r = Invoke-EventCycle -Pattern 'Screenshot*' -Seen $seenE -Pending $pendingE `
                           -TimeoutSeconds 3 -EventSource $srcE -SettleTimeoutMs 2000
    Assert 'a directory-shaped event is consumed but never copied' `
           ($r.Handled -ge 1 -and $r.Copied -eq 0) "handled=$($r.Handled) copied=$($r.Copied)"
    Assert 'and the clipboard was left alone' ($global:Calls.Count -eq $callsBefore)
    Assert 'and the directory is not marked seen' (-not $seenE.ContainsKey($adir))
}
finally {
    Remove-ScreenshotWatcher -Watcher $watcherE -EventSource $srcE
}

Section 'an idle cycle'

# Its own directory and watcher, so no stray event from the tests above can
# be sitting in the queue and make an idle cycle look busy.
$dirIdle     = New-TestDir 'idle'
$srcIdle     = 'LogicTestIdle'
$watcherIdle = New-ScreenshotWatcher -Dir $dirIdle -EventSource $srcIdle
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-EventCycle -Pattern 'Screenshot*' -Seen @{} -Pending @{} `
                           -TimeoutSeconds 1 -EventSource $srcIdle -SettleTimeoutMs 2000
    $sw.Stop()
    Assert 'an idle cycle reports Handled = 0' ($r.Handled -eq 0) "handled=$($r.Handled)"
    Assert 'and it blocks for the full timeout instead of spinning' `
           ($sw.ElapsedMilliseconds -ge 900) "took $($sw.ElapsedMilliseconds)ms"
    Assert 'and it copies nothing' ($r.Copied -eq 0)
}
finally {
    Remove-ScreenshotWatcher -Watcher $watcherIdle -EventSource $srcIdle
}

# ------------------------------------------------------- watch iteration -----

Section 'watch iteration wiring'

# 1. An event arrives: it must be copied and no scan should be needed.
$dirW = New-TestDir 'iteration'
$seenW    = @{}
$pendingW = @{}
$srcW = 'LogicTestIteration'
$watcherW = New-ScreenshotWatcher -Dir $dirW -EventSource $srcW
try {
    $null = New-Probe $dirW 'Screenshot w1.png'
    $it = Invoke-WatchIteration -Dir $dirW -Pattern 'Screenshot*' -Seen $seenW -Pending $pendingW `
                                -ReconcileSeconds 60 -EventTimeoutSeconds 5 -EventSource $srcW -SettleTimeoutMs 5000
    Assert 'iteration 1: the event was handled' ($it.Handled -ge 1)
    Assert 'iteration 1: the file was copied' ($it.Copied -eq 1)
    Assert 'iteration 1: no reconciliation scan was needed' (-not $it.Reconcile)
    Assert 'iteration 1: nothing was scanned' ($it.Scanned -eq 0)
}
finally {
    Remove-ScreenshotWatcher -Watcher $watcherW -EventSource $srcW
}

# 2. The backstop: a file the watcher never told us about (it existed
#    before the watcher was armed, and $seen was primed empty) must still
#    be picked up, but only by a scan.
$dirW2 = New-TestDir 'iteration-backstop'
$missed = New-Probe $dirW2 'Screenshot missed.png'
$seenW2    = @{}          # deliberately primed empty: we pretend we never saw it
$pendingW2 = @{}
$srcW2 = 'LogicTestBackstop'
$watcherW2 = New-ScreenshotWatcher -Dir $dirW2 -EventSource $srcW2
try {
    $global:Calls.Clear()
    $it = Invoke-WatchIteration -Dir $dirW2 -Pattern 'Screenshot*' -Seen $seenW2 -Pending $pendingW2 `
                                -ReconcileSeconds 60 -EventTimeoutSeconds 1 -EventSource $srcW2 -SettleTimeoutMs 5000
    Assert 'iteration 2: no event was delivered' ($it.Handled -eq 0) "handled=$($it.Handled)"
    Assert 'iteration 2: the empty wait triggered the backstop scan' ($it.Reconcile)
    Assert 'iteration 2: the backstop scan found the file the watcher missed' `
           ($it.Scanned -eq 1 -and $seenW2.ContainsKey($missed)) "scanned=$($it.Scanned)"
    Assert 'iteration 2: and it reached the clipboard' ($global:Calls.Count -eq 1)
}
finally {
    Remove-ScreenshotWatcher -Watcher $watcherW2 -EventSource $srcW2
}

# 3. With the backstop disabled, an empty wait must not scan.
$dirW3 = New-TestDir 'iteration-nobackstop'
$missed3 = New-Probe $dirW3 'Screenshot missed3.png'
$seenW3    = @{}
$pendingW3 = @{}
$srcW3 = 'LogicTestNoBackstop'
$watcherW3 = New-ScreenshotWatcher -Dir $dirW3 -EventSource $srcW3
try {
    $global:Calls.Clear()
    $it = Invoke-WatchIteration -Dir $dirW3 -Pattern 'Screenshot*' -Seen $seenW3 -Pending $pendingW3 `
                                -ReconcileSeconds 0 -EventTimeoutSeconds 1 -EventSource $srcW3 -SettleTimeoutMs 5000
    Assert 'iteration 3: with -ReconcileSeconds 0 an empty wait does not scan' (-not $it.Reconcile)
    Assert 'iteration 3: so the missed file stays unseen' (-not $seenW3.ContainsKey($missed3))
    Assert 'iteration 3: and nothing reached the clipboard' ($global:Calls.Count -eq 0)
}
finally {
    Remove-ScreenshotWatcher -Watcher $watcherW3 -EventSource $srcW3
}

# 4. An Error event must force a scan even when the backstop is off.
$dirW4 = New-TestDir 'iteration-errorforce'
$missed4 = New-Probe $dirW4 'Screenshot missed4.png'
$seenW4    = @{}
$pendingW4 = @{}
$srcW4 = 'LogicTestErrorForce'
$watcherW4 = New-ScreenshotWatcher -Dir $dirW4 -EventSource $srcW4
try {
    $null = New-Event -SourceIdentifier ($srcW4 + '.Error')
    $global:Calls.Clear()
    $it = Invoke-WatchIteration -Dir $dirW4 -Pattern 'Screenshot*' -Seen $seenW4 -Pending $pendingW4 `
                                -ReconcileSeconds 0 -EventTimeoutSeconds 5 -EventSource $srcW4 -SettleTimeoutMs 5000
    Assert 'iteration 4: an Error event forces a reconciliation scan' ($it.Reconcile)
    Assert 'iteration 4: the forced scan recovered the file' ($seenW4.ContainsKey($missed4)) "scanned=$($it.Scanned)"
    Assert 'iteration 4: and it reached the clipboard' ($global:Calls.Count -eq 1)
}
finally {
    Remove-ScreenshotWatcher -Watcher $watcherW4 -EventSource $srcW4
}

# 5. Pending retries happen on their own turn of the loop. The file is
#    created BEFORE the watcher is armed, so no event can do the retry for
#    us -- the retry path must be what clears it.
$dirW5 = New-TestDir 'iteration-retry'
$w5 = New-Probe $dirW5 'Screenshot w5.png'
$seenW5    = @{}
$pendingW5 = @{}
$srcW5 = 'LogicTestRetryWire'
$watcherW5 = New-ScreenshotWatcher -Dir $dirW5 -EventSource $srcW5
try {
    $global:Calls.Clear()
    # Queue something as pending by hand, as a failed copy would.
    $pendingW5[$w5] = 1
    $it = Invoke-WatchIteration -Dir $dirW5 -Pattern 'Screenshot*' -Seen $seenW5 -Pending $pendingW5 `
                                -ReconcileSeconds 60 -EventTimeoutSeconds 2 -EventSource $srcW5 -SettleTimeoutMs 5000
    Assert 'iteration 5: the pending file was retried' ($it.Retried -eq 1) "retried=$($it.Retried)"
    Assert 'iteration 5: and it is no longer pending' (-not $pendingW5.ContainsKey($w5))
    Assert 'iteration 5: and it is marked seen' ($seenW5.ContainsKey($w5))
}
finally {
    Remove-ScreenshotWatcher -Watcher $watcherW5 -EventSource $srcW5
}

# ------------------------------------------- regressions from the audit ----

# Every test below locks a specific defect found by the audit. They exist
# because the original suite was green while all of these were broken: the
# untested surface is exactly where the bugs were.

$funcAst = @{}
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $funcAst[$f.Name] = $f
}

function Get-PassedParameters {
    param($FunctionName, [string] $CommandName)
    $calls = @($funcAst[$FunctionName].FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $CommandName
    }, $true))
    $names = @()
    if ($calls.Count -ge 1) {
        foreach ($element in $calls[0].CommandElements) {
            if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                $names += $element.ParameterName
            }
        }
    }
    return @{ Calls = $calls; Parameters = $names }
}

Section 'A1: the event source is passed, not duplicated'

foreach ($fn in @('Invoke-EventCycle', 'Invoke-WatchIteration')) {
    $esParam = @($funcAst[$fn].Body.ParamBlock.Parameters |
                 Where-Object { $_.Name.VariablePath.UserPath -eq 'EventSource' })
    Assert "$fn declares an -EventSource parameter" ($esParam.Count -eq 1) "found $($esParam.Count)"
    Assert "$fn gives it no default, so it cannot silently diverge" `
           ($esParam.Count -eq 1 -and $null -eq $esParam[0].DefaultValue)
}

$watchCall = Get-PassedParameters -FunctionName 'Start-WatchLoop' -CommandName 'Invoke-WatchIteration'
Assert 'Start-WatchLoop calls Invoke-WatchIteration exactly once' ($watchCall.Calls.Count -eq 1) `
       "got $($watchCall.Calls.Count)"
Assert 'and it passes -EventSource' ($watchCall.Parameters -contains 'EventSource') `
       "passed: $($watchCall.Parameters -join ', ')"

Section 'A1: the drain follows the -EventSource it is handed'

$dirSrc      = New-TestDir 'eventsource'
$srcExplicit = 'AuditFixExplicitSource'
$watcherSrc  = New-ScreenshotWatcher -Dir $dirSrc -EventSource $srcExplicit
try {
    $null = New-Probe $dirSrc 'Screenshot src.png'
    # $script:EventSource is $prodEventSource, so this only works if the drain
    # honours the parameter rather than falling back to a global.
    $it = Invoke-WatchIteration -Dir $dirSrc -Pattern 'Screenshot*' -Seen @{} -Pending @{} `
                                -ReconcileSeconds 0 -EventTimeoutSeconds 3 `
                                -EventSource $srcExplicit -SettleTimeoutMs 3000
    Assert 'the drain uses the source it was given, not $script:EventSource' ($it.Handled -ge 1) `
           "handled=$($it.Handled) (script source is '$prodEventSource')"
    Assert 'and the event path copied the file' ($it.Copied -eq 1) "copied=$($it.Copied)"

    # The old failure mode, stated as a test: draining a source nothing was
    # armed under yields nothing at all, silently.
    $dirSrc2 = New-TestDir 'eventsource-mismatch'
    $null = New-Probe $dirSrc2 'Screenshot src2.png'
    $srcOther = 'AuditFixOtherSource'
    $watcherSrc2 = New-ScreenshotWatcher -Dir $dirSrc2 -EventSource $srcOther
    try {
        $mismatch = Invoke-WatchIteration -Dir $dirSrc2 -Pattern 'Screenshot*' -Seen @{} -Pending @{} `
                                          -ReconcileSeconds 0 -EventTimeoutSeconds 1 `
                                          -EventSource 'SomeOtherSourceEntirely' -SettleTimeoutMs 500
        Assert 'a mismatched source drains nothing (which is why the parameter is mandatory)' `
               ($mismatch.Handled -eq 0 -and $mismatch.Copied -eq 0) `
               "handled=$($mismatch.Handled) copied=$($mismatch.Copied)"
    }
    finally { Remove-ScreenshotWatcher -Watcher $watcherSrc2 -EventSource $srcOther }
}
finally { Remove-ScreenshotWatcher -Watcher $watcherSrc -EventSource $srcExplicit }

Section 'A2 / A18: an impossible retry entry is dropped, not counted'

$dirP  = New-TestDir 'pending-leak'
$ghost = New-Probe $dirP 'Screenshot ghost.png'
$seenP = @{}
$pendingP = @{}
$pendingP[$ghost] = 1
Remove-Item -LiteralPath $ghost -Force

$retried = Invoke-RetryPending -Pattern 'Screenshot*' -Seen $seenP -Pending $pendingP -SettleTimeoutMs 500
Assert 'a pending entry whose file is gone is dropped' (-not $pendingP.ContainsKey($ghost))
Assert 'and it is not counted as retried' ($retried -eq 0) "retried=$retried"

# The consequence that made this worth fixing: an immortal entry pins the wait
# at 1 second, and an idle iteration then scans the whole directory every time.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$idle = Invoke-WatchIteration -Dir $dirP -Pattern 'Screenshot*' -Seen $seenP -Pending $pendingP `
                              -ReconcileSeconds 2 -EventTimeoutSeconds 0 `
                              -EventSource 'AuditFixIdleSource' -SettleTimeoutMs 500
$sw.Stop()
Assert 'with nothing pending the loop waits the configured backstop, not 1 second' `
       ($sw.ElapsedMilliseconds -ge 1700) "waited $($sw.ElapsedMilliseconds)ms"
Assert 'and that wait is what triggers the periodic scan' ($idle.Reconcile)

# And the counter still reports real work.
$alive = New-Probe $dirP 'Screenshot alive.png'
$seenQ = @{}
$pendingQ = @{}
$pendingQ[$alive] = 1
$retriedQ = Invoke-RetryPending -Pattern 'Screenshot*' -Seen $seenQ -Pending $pendingQ -SettleTimeoutMs 3000
Assert 'a pending entry that can still succeed is retried and counted' ($retriedQ -eq 1 -and $seenQ.ContainsKey($alive))

Section 'A3: logging survives a host that throws'

$logProbe = Join-Path $global:TestRoot 'writelog-probe.log'
$script:LogFile = $logProbe
Remove-Item -LiteralPath $logProbe -Force -ErrorAction SilentlyContinue

$realWriteHost = Get-Command Write-Host
function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)] $Rest) throw 'this host cannot write' }
$threw = $false
try { Write-Log 'survived a broken host' } catch { $threw = $true }
$logged = (Test-Path -LiteralPath $logProbe) -and
          (@(Get-Content -LiteralPath $logProbe) -match 'survived a broken host').Count -gt 0
# Removing the function definition makes the real cmdlet visible again; Assert
# and Section write through it.
Remove-Item function:Write-Host -Force

Assert 'the real Write-Host is back for the rest of the run' ($null -ne (Get-Command Write-Host -CommandType Cmdlet))

Assert 'Write-Log does not throw when the host throws' (-not $threw)
Assert 'and the line still reaches the log file' $logged

Section 'A4: the diagnostic separates a name problem from a format problem'

$dirDiagExt = New-TestDir 'diag-extension'
$null = New-TextFile $dirDiagExt 'Screenshot x.bmp' 'x'
$diagExt = @(Get-WatchDirDiagnostic -Dir $dirDiagExt -Pattern 'Screenshot*')
Assert 'names matching but no supported format is reported as a format problem' `
       (@($diagExt | Where-Object { $_ -like '*none has a supported extension*' }).Count -eq 1) ($diagExt -join ' / ')
Assert 'and it does NOT tell the user to change -Filter' `
       (@($diagExt | Where-Object { $_ -like '*use -Filter*' }).Count -eq 0) ($diagExt -join ' / ')
Assert 'and it states the accepted extensions' `
       (@($diagExt | Where-Object { $_ -like '*extensions accepted*' }).Count -eq 1)
Assert 'and it lists the extensions actually present' `
       (@($diagExt | Where-Object { $_ -like '*extensions present*' }).Count -eq 1)

$dirDiagName = New-TestDir 'diag-name'
$null = New-TextFile $dirDiagName 'holiday.png' 'x'
$diagName = @(Get-WatchDirDiagnostic -Dir $dirDiagName -Pattern 'Screenshot*')
Assert 'no name match is reported as a naming problem' `
       (@($diagName | Where-Object { $_ -like '*no file in the watch directory matches*' }).Count -eq 1)
Assert 'and it does suggest -Filter' `
       (@($diagName | Where-Object { $_ -like '*use -Filter*' }).Count -eq 1)

$dirDiagOk = New-TestDir 'diag-ok'
$null = New-Probe $dirDiagOk 'Screenshot ok.png'
$diagOk = @(Get-WatchDirDiagnostic -Dir $dirDiagOk -Pattern 'Screenshot*')
Assert 'a good directory reports two OK lines' (@($diagOk | Where-Object { $_ -like 'OK:*' }).Count -eq 2) ($diagOk -join ' / ')
Assert 'a missing directory reports FAIL' `
       (@(Get-WatchDirDiagnostic -Dir (Join-Path $global:TestRoot 'no-such-dir') -Pattern 'Screenshot*') |
        Where-Object { $_ -like 'FAIL:*' }).Count -eq 1

Section 'A15: self-test probe names satisfy the configured filter'

$probeStamp = '20260922-221412'
foreach ($pattern in @('Screenshot*', 'Screenshot *.png', 'Snip*', '*.png', '*Screenshot*', 'Shot*2026*.png')) {
    $name = Get-ProbeName -Pattern $pattern -Stamp $probeStamp -Kind 'scan'
    Assert "the probe for -Filter '$pattern' satisfies it" `
           ($null -ne $name -and $name -like $pattern) "got '$name'"
}
Assert 'scan and event probes are distinct filenames' `
       ((Get-ProbeName -Pattern 'Screenshot*' -Stamp $probeStamp -Kind 'scan') -ne
        (Get-ProbeName -Pattern 'Screenshot*' -Stamp $probeStamp -Kind 'event'))
Assert 'a filter with no wildcard yields $null (two probes could not both match)' `
       ($null -eq (Get-ProbeName -Pattern 'exact.png' -Stamp $probeStamp -Kind 'scan'))
Assert 'a filter the heuristic cannot satisfy yields $null instead of a wrong probe' `
       ($null -eq (Get-ProbeName -Pattern '[Ss]hot*' -Stamp $probeStamp -Kind 'scan'))
Assert 'no probe name ever starts with a dot (Get-ChildItem would not list it)' `
       (@(@('Screenshot*', '*.png', '*Screenshot*', 'Snip*') |
          ForEach-Object { Get-ProbeName -Pattern $_ -Stamp $probeStamp -Kind 'scan' } |
          Where-Object { $null -ne $_ -and $_.StartsWith('.') }).Count -eq 0)

# The end-to-end form of the same thing: a probe on disk must be eligible and
# must actually be picked up by a scan pass, for every filter.
$dirProbe = New-TestDir 'probe-eligibility'
foreach ($pattern in @('Screenshot*', 'Snip*', '*.png', '*Screenshot*')) {
    $probePath = Join-Path $dirProbe (Get-ProbeName -Pattern $pattern -Stamp $probeStamp -Kind 'scan')
    [IO.File]::WriteAllBytes($probePath, [Convert]::FromBase64String($ProbePng))
    Assert "a real probe file for '$pattern' is eligible" (Test-ScreenshotPath -Path $probePath -Pattern $pattern)
    $seenProbe = @{}
    $pendingProbe = @{}
    Assert "and a scan pass for '$pattern' copies it (this is what -SelfTest asserts)" `
           ((Invoke-ScanPass -Dir $dirProbe -Pattern $pattern -Seen $seenProbe -Pending $pendingProbe -SettleTimeoutMs 3000) -eq 1)
    Remove-Item -LiteralPath $probePath -Force
}

Section 'localised screenshot names (a Chinese Windows writes these)'

# Spelled with code points because this file is ASCII-only for the same reason
# the script is: 0x5C4F 0x5E55 0x622A 0x56FE is the Chinese for "screen shot".
$localisedPrefix = -join @([char]0x5C4F, [char]0x5E55, [char]0x622A, [char]0x56FE)
$localisedName   = '{0} 2026-09-22 224547.png' -f $localisedPrefix

Assert 'the default filter is not English-only' `
       (Test-NameMatchesPattern -Name $localisedName -Pattern $prodFilter) `
       "filter is: $($prodFilter -join ' | ')"
Assert 'and it still covers the English naming' `
       (Test-NameMatchesPattern -Name 'Screenshot 2026-09-22 224547.png' -Pattern $prodFilter)

# Pin the exact characters instead of trusting the code-point expression above.
$localisedPattern = @($prodFilter | Where-Object { $_ -like "$localisedPrefix*" })[0]
Assert 'the default filter contains the localised prefix pattern' ($null -ne $localisedPattern) `
       "filter is: $($prodFilter -join ' | ')"
Assert 'and that pattern is exactly those four code points plus a wildcard' `
       ($localisedPattern.Length -eq 5 -and
        [int][char]($localisedPattern[0]) -eq 0x5C4F -and
        [int][char]($localisedPattern[1]) -eq 0x5E55 -and
        [int][char]($localisedPattern[2]) -eq 0x622A -and
        [int][char]($localisedPattern[3]) -eq 0x56FE -and
        $localisedPattern[4] -eq '*') "got '$localisedPattern'"

# End to end under the production default filter, with the exact name shape
# reported from a Chinese Windows installation.
$dirLocale = New-TestDir 'localised'
$localisedPath = Join-Path $dirLocale $localisedName
[IO.File]::WriteAllBytes($localisedPath, [Convert]::FromBase64String($ProbePng))

Assert 'such a file is eligible' (Test-ScreenshotPath -Path $localisedPath -Pattern $prodFilter)
Assert 'it is listed by a scan' (@(Get-ScreenshotListing -Dir $dirLocale -Pattern $prodFilter).Count -eq 1)

$global:Calls.Clear()
$seenLoc = @{}
$pendingLoc = @{}
Assert 'a scan pass copies it' `
       ((Invoke-ScanPass -Dir $dirLocale -Pattern $prodFilter -Seen $seenLoc -Pending $pendingLoc -SettleTimeoutMs 3000) -eq 1)
Assert 'and the clipboard got exactly that path' ($global:Calls.Count -eq 1 -and $global:Calls[0] -eq $localisedPath)
Assert 'the directory diagnostic reports it as a match' `
       (@(Get-WatchDirDiagnostic -Dir $dirLocale -Pattern $prodFilter) |
        Where-Object { $_ -like 'OK:*match*' }).Count -eq 1
Assert 'and -SelfTest can build both probes for the default filter' `
       ($null -ne (Get-ProbeName -Pattern $prodFilter -Stamp '20260922-224547' -Kind 'scan') -and
        $null -ne (Get-ProbeName -Pattern $prodFilter -Stamp '20260922-224547' -Kind 'event'))

Section 'A16: the watcher is armed before the baseline is primed'

$armCall   = @($funcAst['Start-WatchLoop'].FindAll({
    param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-ScreenshotWatcher'
}, $true))
$primeCall = @($funcAst['Start-WatchLoop'].FindAll({
    param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-SeenSet'
}, $true))
Assert 'Start-WatchLoop arms a watcher' ($armCall.Count -eq 1) "got $($armCall.Count)"
Assert 'Start-WatchLoop primes the baseline itself (so main does not do it first)' ($primeCall.Count -eq 1) "got $($primeCall.Count)"
if ($armCall.Count -eq 1 -and $primeCall.Count -eq 1) {
    Assert 'and it arms before priming, closing the startup gap' `
           ($armCall[0].Extent.StartLineNumber -lt $primeCall[0].Extent.StartLineNumber) `
           "arm@$($armCall[0].Extent.StartLineNumber) prime@$($primeCall[0].Extent.StartLineNumber)"
}

# ------------------------------------------------------------- event leaks ---

Section 'event subscriptions'

$leftovers = @(Get-EventSubscriber | Where-Object { $_.SourceIdentifier -like 'LogicTest*' })
Assert 'every test watcher was unregistered' ($leftovers.Count -eq 0) `
       "left: $(@($leftovers | ForEach-Object { $_.SourceIdentifier }) -join ', ')"

# ------------------------------------------------------------------ report ---

Section 'result'

Remove-Item -LiteralPath $global:TestRoot -Recurse -Force -ErrorAction SilentlyContinue

if ($global:Failures -eq 0) {
    Write-Host '  ALL TESTS PASSED'
    exit 0
}
Write-Host "  $($global:Failures) TEST(S) FAILED"
exit $global:Failures
