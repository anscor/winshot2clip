<#
    winshot2clip.ps1

    Watches the Windows screenshot folder. Whenever a new screenshot file
    appears, it puts THAT FILE on the clipboard -- exactly what Explorer does
    when you click a file and press Ctrl+C. The paste path itself does not
    change at all; only the "somebody has to find the file and press Ctrl+C"
    step is automated. Your screenshot tool keeps doing the saving.

    How the copy is made (-ClipboardMode):
      Shell (default) -- Shell.Application runs in explorer.exe, so asking it
        for the file's "copy" verb makes Explorer perform the copy. Expect the
        same clipboard contents as a manual Ctrl+C, because it is the same code
        path. Shell IDList Array and Preferred DropEffect come along for free.
      FileDrop -- put the path on the clipboard directly with
        SetFileDropList, which offers only CF_HDROP.
      AsciiCopy -- copy to an ASCII-named file in %TEMP% first, to dodge an
        upstream xrdp bug with non-ASCII names (issue #1992).

    Why not put the bitmap on the clipboard instead:
      That is what a manual "copy image" does, and it works over RDP. But it
      is a different task: this tool automates the file copy you do by hand,
      which is what keeps the screenshot as a file with its real name.

    Why the clipboard content is still there after this script exits:
      The shell's copy is rendered onto the clipboard by the shell itself, and
      SetFileDropList() internally calls SetDataObject(dataObject, copy: true) --
      OleFlushClipboard -- so the data is not left behind as a pointer owned by
      our process. Either way Ctrl+V keeps working minutes later, from any app.

    How it watches (-Mode Watch, the default):
      FileSystemWatcher, but registered WITHOUT -Action. That distinction
      is the whole trick: with -Action the handler runs in a child scope
      where the main loop's state is not reachable, and it only fires when
      the pipeline happens to be idle. Without -Action the events just land
      in PowerShell's event queue and Wait-Event blocks on that queue on
      the main thread, so everything stays single-threaded and there is no
      polling and no idle I/O.

    The two ways a watcher can lose a screenshot, and why neither does:
      1. The kernel's change buffer overflows. .NET then raises an Error
         event; we react by running a full directory scan and picking up
         whatever was dropped.
      2. The event never arrives at all (a known ReadDirectoryChangesW
         edge case). Covered by a low-frequency reconciliation scan: if
         Wait-Event times out having seen nothing, one directory scan
         happens, so nothing can hide for longer than -ReconcileSeconds.
      Set -ReconcileSeconds 0 to keep only the Error-driven recovery.

    Requirements: Windows PowerShell 5.1 (built into Windows) and an STA
      apartment. powershell.exe already defaults to STA; -STA is passed
      explicitly anyway.

    Usage:
      powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File winshot2clip.ps1
      powershell.exe ... -File winshot2clip.ps1 -SelfTest
      powershell.exe ... -File winshot2clip.ps1 -Once "C:\...\Screenshot 2026-01-01 120000.png"
      powershell.exe ... -File winshot2clip.ps1 -Mode Poll

    In normal use it is launched with no visible window by start-hidden.vbs.

    NOTE: this file is deliberately ASCII-only. Windows PowerShell 5.1
    decodes .ps1 files with the system ANSI codepage unless the file has a
    UTF-8 BOM, so any non-ASCII character in here would become mojibake if
    the file is ever transferred without its BOM. Non-ASCII paths are still
    fine -- they arrive as arguments, which are always UTF-16.
#>
[CmdletBinding()]
param(
    # Folder the screenshot tool saves into.
    [string] $WatchDir = (Join-Path $env:USERPROFILE 'Pictures\Screenshots'),

    # One or more filename wildcards. An array, because Windows names
    # screenshots in the system language: an English install writes
    # "Screenshot 2026-01-01 120000.png" while a Chinese one writes the same
    # suffix behind a localised prefix. A single English-only pattern matches
    # nothing there, which is silent and looks like the tool being broken.
    #
    # The localised prefix is spelled as code points on purpose: this file has
    # to stay pure ASCII, or Windows PowerShell 5.1 decodes it with the system
    # ANSI code page and turns any literal into mojibake (see the header).
    # Four characters: the Chinese word for "screen shot".
    [string[]] $Filter = @(
        'Screenshot*',
        ((-join @([char]0x5C4F, [char]0x5E55, [char]0x622A, [char]0x56FE)) + '*')
    ),

    # Watch = event driven (recommended). Poll = scan the directory on a
    # timer, the escape hatch if FileSystemWatcher misbehaves on a machine.
    [ValidateSet('Watch', 'Poll')]
    [string] $Mode = 'Watch',

    # -Mode Poll: how often to scan.
    [int] $PollMs = 400,

    # -Mode Watch: if no event shows up for this long, run one directory
    # scan anyway. 0 disables the periodic backstop and leaves only the
    # Error-driven recovery.
    [int] $ReconcileSeconds = 60,

    # How long to wait for a file to stop growing before using it.
    [int] $SettleTimeoutMs = 5000,

    # -Mode Watch only; exposed so tests can shorten the wait. 0 means
    # "derive it from -ReconcileSeconds".
    [int] $EventTimeoutSeconds = 0,

    [string] $LogPath = (Join-Path $env:USERPROFILE 'winshot2clip.log'),

    # HOW to put the screenshot on the clipboard. All three put a FILE on the
    # clipboard; they differ in who does it.
    #
    #   Shell (default) -- ask the shell to run the "copy" verb on the file.
    #     Shell.Application is an out-of-process COM server living in
    #     explorer.exe, so the copy is performed by Explorer itself. This is the
    #     closest possible reproduction of selecting the file and pressing
    #     Ctrl+C by hand: same code path, same clipboard contents, including the
    #     Shell IDList Array that cannot reasonably be built by hand.
    #
    #   FileDrop -- put the path on the clipboard with SetFileDropList. Plain,
    #     but it offers only the CF_HDROP format, whereas Explorer also offers
    #     FileNameW, Shell IDList Array and Preferred DropEffect.
    #
    #   AsciiCopy -- copy the screenshot to an ASCII-named file in %TEMP% and
    #     put THAT path on the clipboard. A workaround for the upstream xrdp
    #     bug where a non-ASCII name makes the file-list parser read only the
    #     first entry (issue #1992).
    [ValidateSet('Shell', 'FileDrop', 'AsciiCopy')]
    [string] $ClipboardMode = 'Shell',

    # xrdp parses the clipboard file list with a length derived from wcstombs(),
    # which is wrong for names that are not plain ASCII. Upstream issue #1992:
    # only the first file descriptor is read correctly and the clipboard channel
    # ends up wedged -- the first paste works, everything after it is dead.
    # Windows names screenshots in the system language, so on a Chinese install
    # every screenshot has a non-ASCII name.
    #
    # So by default each screenshot is copied to an ASCII-named file under
    # %TEMP% and THAT path is what goes on the clipboard. Use this switch to
    # put the original path on the clipboard instead.
    #
    # Only relevant with -ClipboardMode File.
    [switch] $KeepOriginalName,

    # Diagnostic mode: exercises the whole detect -> clipboard -> read-back
    # cycle against a throwaway folder under %TEMP%, for both -Mode Watch
    # and -Mode Poll, without touching your own screenshots.
    [switch] $SelfTest,

    # One-shot mode: put this one file on the clipboard and exit.
    [string] $Once
)

Add-Type -AssemblyName System.Windows.Forms

$script:LogFile     = $LogPath
$script:Extensions  = @('.png', '.jpg', '.jpeg')
$script:MaxAttempts = 3
$script:EventSource = 'WinShot2Clip'
$script:KeepOriginalName = [bool] $KeepOriginalName
$script:ClipboardMode = $ClipboardMode
$script:ClipSerial = 0

# The path most recently handed to the clipboard. With the ASCII-copy workaround
# this is a %TEMP% copy, not the screenshot itself, so the self test has to ask
# for this rather than assume the probe path.
$script:LastClipboardPath = $null

# ---------------------------------------------------------------- logging ---

function Write-Log {
    <#
        Best effort in both directions. The console and the log file get
        separate try blocks so that a host which cannot display output still
        does not cost us the file log -- the host call used to sit outside
        the try, contradicting the "must never take the watcher down" comment.
    #>
    param([string] $Message)

    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message

    try {
        Write-Host $line
    }
    catch {
        # A host that cannot write (or no host at all) is not fatal.
    }

    try {
        # Keep the log from growing without bound.
        if (Test-Path -LiteralPath $script:LogFile) {
            if ((Get-Item -LiteralPath $script:LogFile).Length -gt 1MB) {
                $tail = @(Get-Content -LiteralPath $script:LogFile -Tail 200)
                Set-Content -LiteralPath $script:LogFile -Value $tail -Encoding UTF8
            }
        }
        # Explicit UTF8: Windows PowerShell 5.1 would otherwise use the system
        # code page, which mangles non-ASCII paths in the one place we look to
        # find out which file failed.
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
    catch {
        # Logging must never be able to take the watcher down.
    }
}

# ------------------------------------------------------------- eligibility --

function Test-NameMatchesPattern {
    <#
        True when the file name matches any of the configured wildcards.

        Matching lives here, not in Get-ChildItem -Filter, because -Filter
        takes a single wildcard and hands it to the filesystem provider -- one
        more place for a localised name to go wrong. -like works on .NET
        strings and handles as many patterns as we like.
    #>
    param([string] $Name, [string[]] $Pattern)

    if ([string]::IsNullOrEmpty($Name)) { return $false }

    foreach ($candidate in $Pattern) {
        if ([string]::IsNullOrEmpty($candidate)) { continue }
        if ($Name -like $candidate) { return $true }
    }
    return $false
}

function Test-ScreenshotPath {
    <#
        True when this path is something we should act on: a real file,
        whose name matches one of the wildcards, with a whitelisted
        extension.

        Test-Path -PathType Leaf matters because a Created event is also
        raised for new subdirectories.
    #>
    param([string] $Path, [string[]] $Pattern)

    if ([string]::IsNullOrEmpty($Path)) { return $false }

    $extension = [System.IO.Path]::GetExtension($Path)
    if ([string]::IsNullOrEmpty($extension)) { return $false }
    if (-not ($script:Extensions -contains $extension.ToLowerInvariant())) { return $false }

    if (-not (Test-NameMatchesPattern -Name ([System.IO.Path]::GetFileName($Path)) -Pattern $Pattern)) { return $false }

    return (Test-Path -LiteralPath $Path -PathType Leaf)
}

function Get-ScreenshotListing {
    param([string] $Dir, [string[]] $Pattern)

    try {
        return @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction Stop |
                 Where-Object {
                     $script:Extensions -contains $_.Extension.ToLowerInvariant() -and
                     (Test-NameMatchesPattern -Name $_.Name -Pattern $Pattern)
                 })
    }
    catch {
        Write-Log "scan failed: $($_.Exception.Message)"
        return @()
    }
}

function Get-FileSignature {
    <#
        A cheap identity for "this exact version of the file": length plus
        last-write time.

        $Seen stores these instead of $true so that a second screenshot
        written to the same path is recognised as new content instead of as
        something already handled. Only one place builds the string, so the
        two sides of every comparison cannot drift apart.

        Returns $null when the file cannot be read.
    #>
    param([string] $Path)

    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        return '{0}|{1}' -f $item.Length, $item.LastWriteTimeUtc.Ticks
    }
    catch {
        return $null
    }
}

function Copy-ForClipboard {
    <#
        Copies the screenshot to an ASCII-named file under %TEMP% and returns
        that path.

        xrdp parses the clipboard file list with a length derived from
        wcstombs(), which is wrong for names that are not plain ASCII: upstream
        issue #1992, where only the first file descriptor inside a
        CLIPRDR_FILELIST is read correctly and the channel ends up wedged.
        Windows names screenshots using the system language, so on a Chinese
        install every screenshot hits that parser with a non-ASCII name.

        The copy is byte-identical, so nothing downstream can tell the
        difference apart from the name.
    #>
    param([string] $Path)

    $directory = Join-Path ([System.IO.Path]::GetTempPath()) 'winshot2clip'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void] (New-Item -ItemType Directory -Path $directory -Force)
    }

    $script:ClipSerial++
    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $name = 'shot-{0}-{1:d3}{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $script:ClipSerial, $extension
    $target = Join-Path $directory $name

    Copy-Item -LiteralPath $Path -Destination $target -Force

    # Bound the directory. The copy just made is the newest entry, so an
    # announced path can never be pruned out from under a pending paste.
    $keep = 20
    $existing = @(Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending)
    if ($existing.Count -gt $keep) {
        $existing | Select-Object -Skip $keep | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    return $target
}

function Test-AlreadyCopied {
    <#
        True when this exact version of the path is already in $Seen.
    #>
    param([string] $Path, [hashtable] $Seen)

    if (-not $Seen.ContainsKey($Path)) { return $false }
    return ($Seen[$Path] -eq (Get-FileSignature -Path $Path))
}

function New-SeenSet {
    <#
        Startup baseline. Everything already on disk counts as seen, so
        launching the watcher never dumps a month-old screenshot over
        whatever you currently have on the clipboard.
    #>
    param([string] $Dir, [string[]] $Pattern)

    # A plain hashtable: PowerShell compares its string keys
    # case-insensitively, which is what Windows paths need.
    $seen = @{}
    foreach ($file in (Get-ScreenshotListing -Dir $Dir -Pattern $Pattern)) {
        $signature = Get-FileSignature -Path $file.FullName
        if ($null -ne $signature) { $seen[$file.FullName] = $signature }
    }
    return $seen
}

function Wait-FileSettled {
    <#
        Blocks until the file's size has stopped changing, i.e. the
        screenshot tool has closed it.

        This is what the old polling design had to infer from two identical
        directory scans; with an event we get the path immediately and can
        ask the question directly.

        False means it timed out or the file went away.
    #>
    param([string] $Path, [int] $TimeoutMs = 5000, [int] $StepMs = 100)

    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $lastSize = -1

    while ($true) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

        try { $size = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length }
        catch { return $false }

        # A file that is still 0 bytes is not finished being written.
        if ($size -gt 0 -and $size -eq $lastSize) { return $true }
        $lastSize = $size

        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Milliseconds $StepMs
    }
}

# -------------------------------------------------------------- clipboard ---

function Set-ClipboardFile {
    <#
        Puts a single existing file on the clipboard as a FileDropList.
        Returns the number of attempts it took. Throws if all attempts fail.

        Retrying matters: another process holding the clipboard open for a
        few milliseconds (CLIPBRD_E_CANT_OPEN) is normal on Windows, and
        without a retry the copy is simply lost.
    #>
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "file does not exist: $Path"
    }

    $list = New-Object System.Collections.Specialized.StringCollection
    [void] $list.Add($Path)

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            [System.Windows.Forms.Clipboard]::SetFileDropList($list)
            return $attempt
        }
        catch {
            if ($attempt -eq 5) { throw }
            Start-Sleep -Milliseconds 200
        }
    }
}

function Set-ClipboardFileByShellVerb {
    <#
        Ask the shell itself to copy the file, the way a manual Ctrl+C in
        Explorer does.

        Shell.Application is an out-of-process COM server running inside
        explorer.exe, so the clipboard ends up holding exactly what a manual
        copy produces, including the Shell IDList Array that a hand-built data
        object could not reasonably reproduce.
    #>
    param([Parameter(Mandatory = $true)][string] $Path)

    $directory = Split-Path -Parent $Path
    $leaf      = Split-Path -Leaf $Path

    $shell  = New-Object -ComObject Shell.Application
    $folder = $shell.Namespace($directory)
    if ($null -eq $folder) { throw "shell cannot open folder: $directory" }

    $item = $folder.ParseName($leaf)
    if ($null -eq $item) { throw "shell cannot find item: $leaf" }

    # The canonical verb name, not the localised menu text.
    $item.InvokeVerb('copy')
}

function Test-ClipboardHoldsFile {
    <#
        True when the file is already on the clipboard as a file drop.

        Polled rather than assumed: InvokeVerb posts to explorer's message loop
        and returns before the copy has happened.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [int] $TimeoutSeconds = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        foreach ($entry in @(Get-ClipboardFileList)) {
            if ($entry -eq $Path) { return $true }
        }
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Milliseconds 100
    }
}

function Set-ClipboardForScreenshot {
    <#
        The one place that decides how a screenshot reaches the clipboard.

        Returns the path that ended up on the clipboard plus the attempt count.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Mode,
        [switch] $KeepOriginalName
    )

    switch ($Mode) {
        'Shell' {
            Set-ClipboardFileByShellVerb -Path $Path
            if (-not (Test-ClipboardHoldsFile -Path $Path)) {
                throw "the shell did not put $Path on the clipboard"
            }
            return @{ Path = $Path; Attempts = 1 }
        }
        'AsciiCopy' {
            $payload = $Path
            if (-not $KeepOriginalName) { $payload = Copy-ForClipboard -Path $Path }
            return @{ Path = $payload; Attempts = (Set-ClipboardFile -Path $payload) }
        }
        default {
            return @{ Path = $Path; Attempts = (Set-ClipboardFile -Path $Path) }
        }
    }
}

function Get-ClipboardFileList {
    try {
        $list = [System.Windows.Forms.Clipboard]::GetFileDropList()
        if ($null -eq $list) { return @() }
        return @($list)
    }
    catch { return @() }
}

# ----------------------------------------------------------- the one copy ---

function Copy-ScreenshotFile {
    <#
        The single place that puts a screenshot on the clipboard. Both
        triggers (a watcher event, a directory scan) go through here, so
        the settle / dedupe / retry / give-up policy exists exactly once.

        Returns $true when this call handled the file (copied it, or gave
        up on it), $false when there was nothing to do.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string[]] $Pattern,
        [Parameter(Mandatory = $true)][hashtable] $Seen,
        [Parameter(Mandatory = $true)][hashtable] $Pending,
        [int] $SettleTimeoutMs = 5000,
        # Used by the scan path: a file already queued for retry must not
        # also be attempted here, or it would burn its attempt budget twice
        # as fast as the retry path intends.
        [switch] $SkipPending
    )

    if ($SkipPending -and $Pending.ContainsKey($Path)) { return $false }
    if (-not (Test-ScreenshotPath -Path $Path -Pattern $Pattern)) { return $false }

    # Already copied this exact version? Length plus mtime decides, so a tool
    # that overwrites a fixed filename still gets copied again. Checked before
    # the settle wait because it is the cheap path for duplicate events.
    if (Test-AlreadyCopied -Path $Path -Seen $Seen) { return $false }

    if (-not (Wait-FileSettled -Path $Path -TimeoutMs $SettleTimeoutMs)) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Write-Log "gone before we could use it: $Path"
            return $false
        }
        Write-Log "WARN: $Path never stopped growing within ${SettleTimeoutMs}ms; using it anyway"
    }

    # Computed after settling: this is the version actually handed to the
    # clipboard, and the one $Seen has to remember.
    $signature = Get-FileSignature -Path $Path

    # What actually goes on the clipboard, and how. The shell does the copy in
    # the default mode, so the announced path is normally the screenshot's own
    # path; only AsciiCopy substitutes a %TEMP% copy.
    try {
        $result = Set-ClipboardForScreenshot -Path $Path -Mode $script:ClipboardMode `
                                            -KeepOriginalName:$script:KeepOriginalName
        $script:LastClipboardPath = $result.Path
        $Seen[$Path] = $signature
        if ($Pending.ContainsKey($Path)) { $Pending.Remove($Path) }

        $suffix = ''
        if ($result.Attempts -gt 1) { $suffix = " ({0} attempts)" -f $result.Attempts }
        if ($result.Path -ne $Path) {
            Write-Log "clipboard set${suffix}: $($result.Path)  (copy of $Path)"
        }
        else {
            Write-Log "clipboard set${suffix} [$($script:ClipboardMode)]: $($result.Path)"
        }
        return $true
    }
    catch {
        $tries = 0
        if ($Pending.ContainsKey($Path)) { $tries = $Pending[$Path] }
        $tries++

        if ($tries -ge $script:MaxAttempts) {
            $Pending.Remove($Path)
            $Seen[$Path] = $signature    # stop trying this version
            Write-Log "GAVE UP after $tries attempts: $Path -- $($_.Exception.Message)"
        }
        else {
            $Pending[$Path] = $tries
            Write-Log "will retry ($tries/$($script:MaxAttempts)): $Path -- $($_.Exception.Message)"
        }
        return $false
    }
}

function Invoke-RetryPending {
    param(
        [Parameter(Mandatory = $true)][string[]] $Pattern,
        [Parameter(Mandatory = $true)][hashtable] $Seen,
        [Parameter(Mandatory = $true)][hashtable] $Pending,
        [int] $SettleTimeoutMs = 5000
    )

    $retried = 0
    foreach ($path in @($Pending.Keys)) {
        # Drop entries that can never succeed. Copy-ScreenshotFile returns
        # early for an ineligible path without touching $Pending, so without
        # this the entry is immortal -- and a non-empty $Pending pins
        # Invoke-WatchIteration at a 1 second wait, which turns the idle loop
        # into a full directory scan once per second, forever.
        if (-not (Test-ScreenshotPath -Path $path -Pattern $Pattern)) {
            $Pending.Remove($path)
            Write-Log "dropped from the retry queue (gone or no longer matching): $path"
            continue
        }

        # The retry is obsolete only if the file is byte-for-byte the version
        # already copied; if it changed, the new content still needs handling.
        if (Test-AlreadyCopied -Path $path -Seen $Seen) {
            $Pending.Remove($path)
            continue
        }

        $retried++
        [void] (Copy-ScreenshotFile -Path $path -Pattern $Pattern -Seen $Seen -Pending $Pending -SettleTimeoutMs $SettleTimeoutMs)
    }
    return $retried
}

function Invoke-ScanPass {
    <#
        One full directory scan: copies every matching file that is not in
        $Seen yet. Used as the reconciliation backstop, as -Mode Poll's
        whole implementation, and by -SelfTest.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Dir,
        [Parameter(Mandatory = $true)][string[]] $Pattern,
        [Parameter(Mandatory = $true)][hashtable] $Seen,
        [Parameter(Mandatory = $true)][hashtable] $Pending,
        [int] $SettleTimeoutMs = 5000,
        [switch] $SkipPending
    )

    $copied = 0
    foreach ($file in (Get-ScreenshotListing -Dir $Dir -Pattern $Pattern)) {
        if (Copy-ScreenshotFile -Path $file.FullName -Pattern $Pattern -Seen $Seen -Pending $Pending `
                                -SettleTimeoutMs $SettleTimeoutMs -SkipPending:$SkipPending) {
            $copied++
        }
    }
    return $copied
}

# ------------------------------------------------------------- event path ---

function New-ScreenshotWatcher {
    param(
        [Parameter(Mandatory = $true)][string] $Dir,
        [Parameter(Mandatory = $true)][string] $EventSource
    )

    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $Dir
    # '*' and not the name patterns: FileSystemWatcher.Filter takes a single
    # wildcard, and name matching is Test-ScreenshotPath's job anyway. The
    # folder only holds screenshots, so the extra events cost nothing.
    $watcher.Filter = '*'
    # FileName is all we need -- creation, deletion and renames. Leaving
    # Size and LastWrite out keeps the kernel's change buffer from filling
    # up with writes we do not care about, which is what makes an overflow
    # unlikely in the first place.
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName
    $watcher.InternalBufferSize = 65536    # the maximum
    $watcher.IncludeSubdirectories = $false

    $null = Register-ObjectEvent -InputObject $watcher -EventName Created -SourceIdentifier ($EventSource + '.Created')
    $null = Register-ObjectEvent -InputObject $watcher -EventName Renamed -SourceIdentifier ($EventSource + '.Renamed')
    $null = Register-ObjectEvent -InputObject $watcher -EventName Error   -SourceIdentifier ($EventSource + '.Error')
    $watcher.EnableRaisingEvents = $true

    return $watcher
}

function Remove-ScreenshotWatcher {
    param($Watcher, [string] $EventSource)

    try { if ($null -ne $Watcher) { $Watcher.EnableRaisingEvents = $false } } catch { }
    foreach ($suffix in @('.Created', '.Renamed', '.Error')) {
        Unregister-Event -SourceIdentifier ($EventSource + $suffix) -ErrorAction SilentlyContinue
    }
    try { if ($null -ne $Watcher) { $Watcher.Dispose() } } catch { }
}

function Invoke-EventCycle {
    <#
        Waits up to $TimeoutSeconds for watcher events, then handles
        everything already queued. Returns:

          Handled  - events consumed. 0 means the wait timed out.
          Copied   - files put on the clipboard this cycle.
          NeedScan - an Error event arrived, i.e. the kernel buffer
                     overflowed and events may have been dropped, so the
                     caller must run a full scan.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]] $Pattern,
        [Parameter(Mandatory = $true)][hashtable] $Seen,
        [Parameter(Mandatory = $true)][hashtable] $Pending,
        [int] $TimeoutSeconds = 60,
        # Mandatory on purpose. This used to default to a literal that had to
        # stay equal to $script:EventSource by coincidence; a mismatch meant
        # events were registered under one name and drained under another,
        # with no error, no log line, and nothing copied.
        [Parameter(Mandatory = $true)][string] $EventSource,
        [int] $SettleTimeoutMs = 5000
    )

    $sourceFilter = $EventSource + '.*'
    $handled  = 0
    $copied   = 0
    $needScan = $false

    $null = Wait-Event -Timeout $TimeoutSeconds -SourceIdentifier $sourceFilter

    foreach ($evt in @(Get-Event -SourceIdentifier $sourceFilter -ErrorAction SilentlyContinue)) {
        Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue
        $handled++

        if ($evt.SourceIdentifier -eq ($EventSource + '.Error')) {
            $needScan = $true
            Write-Log 'watcher reported a buffer error; a full scan will pick up anything dropped'
            continue
        }

        # The payload is $evt.SourceEventArgs. Note that $evt.SourceArgs[0]
        # is the watcher object itself and its .Name property is $null --
        # reading the filename from there yields an empty string and the
        # file is silently never copied.
        $info = $evt.SourceEventArgs
        if ($null -eq $info) { continue }

        if (Copy-ScreenshotFile -Path $info.FullPath -Pattern $Pattern -Seen $Seen `
                                -Pending $Pending -SettleTimeoutMs $SettleTimeoutMs) {
            $copied++
        }
    }

    return @{ Handled = $handled; Copied = $copied; NeedScan = $needScan }
}

function Invoke-WatchIteration {
    <#
        One turn of the watch loop: drain events, retry anything pending,
        and scan the directory if something suggests events were missed.

        Split out of the loop so the wiring itself -- when a scan happens,
        when it must not, how retries interleave -- is testable without
        waiting on an endless loop.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Dir,
        [Parameter(Mandatory = $true)][string[]] $Pattern,
        [Parameter(Mandatory = $true)][hashtable] $Seen,
        [Parameter(Mandatory = $true)][hashtable] $Pending,
        [int] $ReconcileSeconds = 60,
        [int] $EventTimeoutSeconds = 0,
        # Mandatory for the same reason as in Invoke-EventCycle: the caller has
        # to state which subscription to drain instead of relying on a
        # duplicated literal default.
        [Parameter(Mandatory = $true)][string] $EventSource,
        [int] $SettleTimeoutMs = 5000
    )

    $timeout = $EventTimeoutSeconds
    if ($timeout -le 0) {
        if ($ReconcileSeconds -gt 0) { $timeout = $ReconcileSeconds }
        else { $timeout = 3600 }        # no backstop: just wait a long time
    }
    if ($Pending.Count -gt 0) { $timeout = 1 }   # a retry is due, wake up soon

    $events = Invoke-EventCycle -Pattern $Pattern -Seen $Seen -Pending $Pending `
                                -TimeoutSeconds $timeout -EventSource $EventSource `
                                -SettleTimeoutMs $SettleTimeoutMs

    $retried = 0
    if ($Pending.Count -gt 0) {
        $retried = Invoke-RetryPending -Pattern $Pattern -Seen $Seen -Pending $Pending -SettleTimeoutMs $SettleTimeoutMs
    }

    # Two reasons to do a full scan: the kernel buffer overflowed, or the
    # wait timed out because nothing at all arrived for a long time -- in
    # which case this is the periodic backstop that makes a silently
    # missed event impossible to hide for longer than ReconcileSeconds.
    $reconcile = $false
    if ($events.NeedScan) { $reconcile = $true }
    elseif ($events.Handled -eq 0 -and $ReconcileSeconds -gt 0) { $reconcile = $true }

    $scanned = 0
    if ($reconcile) {
        $scanned = Invoke-ScanPass -Dir $Dir -Pattern $Pattern -Seen $Seen -Pending $Pending `
                                   -SettleTimeoutMs $SettleTimeoutMs -SkipPending
        if ($scanned -gt 0) {
            Write-Log "reconciliation scan picked up $scanned file(s) the watcher never reported"
        }
    }

    return @{
        Handled   = $events.Handled
        Copied    = $events.Copied
        Retried   = $retried
        Scanned   = $scanned
        Reconcile = $reconcile
    }
}

# --------------------------------------------------------------- the loops --

function Start-WatchLoop {
    param(
        [string] $Dir, [string[]] $Pattern, [hashtable] $Seen, [hashtable] $Pending,
        [int] $ReconcileSeconds = 60, [int] $EventTimeoutSeconds = 0, [int] $SettleTimeoutMs = 5000
    )

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        Write-Log "ERROR: watch directory not found: $Dir"
        return 2
    }
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
        Write-Log 'WARNING: not running in an STA apartment; clipboard calls may fail. Start with -STA.'
    }

    $watcher = New-ScreenshotWatcher -Dir $Dir -EventSource $script:EventSource

    $backstop = 'off'
    if ($ReconcileSeconds -gt 0) { $backstop = "${ReconcileSeconds}s" }
    Write-Log ("watching '$Dir' for '$Pattern' (event driven, kernel buffer $($watcher.InternalBufferSize) bytes, backstop $backstop)")

    try {
        # Prime the baseline only AFTER the watcher is armed. The other order
        # leaves a window in which a new screenshot is in neither the baseline
        # nor the event stream: it would arrive up to ReconcileSeconds late, or
        # never at all with -ReconcileSeconds 0. This way such a file is either
        # already in the baseline (marked seen, harmless) or announced.
        $baseline = New-SeenSet -Dir $Dir -Pattern $Pattern
        foreach ($path in $baseline.Keys) { $Seen[$path] = $baseline[$path] }
        Write-Log ("baseline: {0} existing file(s) treated as already handled" -f $Seen.Count)

        while ($true) {
            try {
                $null = Invoke-WatchIteration -Dir $Dir -Pattern $Pattern -Seen $Seen -Pending $Pending `
                                              -ReconcileSeconds $ReconcileSeconds `
                                              -EventTimeoutSeconds $EventTimeoutSeconds `
                                              -EventSource $script:EventSource `
                                              -SettleTimeoutMs $SettleTimeoutMs
            }
            catch {
                # A single bad turn must never kill the watcher.
                Write-Log "watch iteration failed: $($_.Exception.Message)"
                Start-Sleep -Milliseconds 500
            }
        }
    }
    finally {
        Remove-ScreenshotWatcher -Watcher $watcher -EventSource $script:EventSource
    }
}

function Start-PollLoop {
    param(
        [string] $Dir, [string[]] $Pattern, [hashtable] $Seen, [hashtable] $Pending,
        [int] $PollMs = 400, [int] $SettleTimeoutMs = 5000
    )

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        Write-Log "ERROR: watch directory not found: $Dir"
        return 2
    }
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
        Write-Log 'WARNING: not running in an STA apartment; clipboard calls may fail. Start with -STA.'
    }

    Write-Log "watching '$Dir' for '$Pattern' (polling every ${PollMs}ms)"

    while ($true) {
        Start-Sleep -Milliseconds $PollMs
        try {
            $null = Invoke-ScanPass -Dir $Dir -Pattern $Pattern -Seen $Seen -Pending $Pending `
                                    -SettleTimeoutMs $SettleTimeoutMs -SkipPending
            if ($Pending.Count -gt 0) {
                $null = Invoke-RetryPending -Pattern $Pattern -Seen $Seen -Pending $Pending -SettleTimeoutMs $SettleTimeoutMs
            }
        }
        catch {
            Write-Log "scan failed: $($_.Exception.Message)"
        }
    }
}

# -------------------------------------------------------------- self test ---

function Get-ProbeName {
    <#
        Builds a filename that satisfies the configured -Filter.

        The self test has to hand both the watcher and the scan something the
        user's own filter accepts; a hardcoded name only works for one filter,
        which made every other filter reject its own probe and report FAIL for
        a perfectly good configuration.

        Returns $null when no synthesised name can satisfy any of the patterns.
        The caller reports that as INCONCLUSIVE, not as a failure.
    #>
    param([string[]] $Pattern, [string] $Stamp, [string] $Kind)

    if ($null -eq $Pattern -or $Pattern.Count -eq 0) { return $null }

    # Any one of the configured patterns will do: the probe only has to be
    # eligible. The first pattern that yields a usable name wins, which for the
    # default list keeps the probe pure ASCII.
    foreach ($single in $Pattern) {
        $name = Get-ProbeNameForPattern -Pattern $single -Stamp $Stamp -Kind $Kind
        if ($null -ne $name) { return $name }
    }
    return $null
}

function Get-ProbeNameForPattern {
    <#
        One pattern, one name. Returns $null when this particular pattern
        cannot be satisfied by anything we are able to synthesise.
    #>
    param([string] $Pattern, [string] $Stamp, [string] $Kind)

    if ([string]::IsNullOrEmpty($Pattern)) { return $null }

    if ($Pattern.IndexOfAny([char[]] '*?[') -lt 0) {
        # A filter with no wildcard names exactly one file, so two distinct
        # probes can never both satisfy it. Say so instead of pretending.
        return $null
    }

    # Try candidates built from the literal runs of the pattern and return the
    # first one that actually matches. Appending the literal runs is tried
    # first because prefixing them can produce a leading dot (for '*.png' that
    # yields '.png selftest ...', which Get-ChildItem does not even list).
    $literal = @($Pattern -split '[\*\?\[]' | Where-Object { $_ -ne '' }) -join ''
    $stem = 'winshot2clip selftest {0} {1}' -f $Kind, $Stamp
    $candidates = @(
        ('{0} {1}.png' -f $stem, $literal),
        ('{0}{1}.png' -f $literal, $stem),
        ('{0}.png' -f $stem)
    )

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ($candidate.StartsWith('.')) { continue }
        if ($candidate -notlike $Pattern) { continue }
        $extension = [System.IO.Path]::GetExtension($candidate)
        if (-not ($script:Extensions -contains $extension.ToLowerInvariant())) { continue }
        return $candidate
    }

    return $null
}

function Get-WatchDirDiagnostic {
    <#
        Returns the diagnostic lines for the watch directory.

        Split out of Invoke-SelfTest so it can be tested (and so the self test
        reports data rather than making assertions inline).

        Name matching and the extension whitelist are reported separately on
        purpose: they need different fixes, and conflating them told users to
        change -Filter when the real problem was the file format.
    #>
    param([string] $Dir, [string[]] $Pattern)

    $lines = New-Object System.Collections.ArrayList

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        [void] $lines.Add("FAIL: watch directory not found: $Dir")
        return @($lines)
    }
    [void] $lines.Add("OK: watch directory exists: $Dir")

    $byName = @()
    try {
        $byName = @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction Stop |
                    Where-Object { Test-NameMatchesPattern -Name $_.Name -Pattern $Pattern })
    }
    catch {
        [void] $lines.Add("WARN: cannot list the watch directory: $($_.Exception.Message)")
        return @($lines)
    }

    $usable = @($byName | Where-Object { $script:Extensions -contains $_.Extension.ToLowerInvariant() })

    if ($usable.Count -gt 0) {
        $message = "OK: {0} file(s) match '{1}'" -f $usable.Count, $Pattern
        [void] $lines.Add($message)
        return @($lines)
    }

    if ($byName.Count -gt 0) {
        # The names are right, the format is not.
        $present = @($byName | ForEach-Object { $_.Extension.ToLowerInvariant() } | Sort-Object -Unique)
        $message = "WARN: {0} file(s) match '{1}', but none has a supported extension." -f $byName.Count, $Pattern
        [void] $lines.Add($message)
        $message = 'WARN:   extensions present : {0}' -f ($present -join ' ')
        [void] $lines.Add($message)
        $message = 'WARN:   extensions accepted: {0}' -f ($script:Extensions -join ' ')
        [void] $lines.Add($message)
        [void] $lines.Add('WARN: if your screenshot tool writes another format, tell me and I will add it.')
        return @($lines)
    }

    # Nothing matches the name pattern at all.
    $sample = @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
                Select-Object -First 5 -ExpandProperty Name)
    if ($sample.Count -gt 0) {
        [void] $lines.Add("WARN: no file in the watch directory matches '$Pattern'.")
        $message = 'WARN: files that are there: {0}' -f ($sample -join ' | ')
        [void] $lines.Add($message)
        [void] $lines.Add('WARN: use -Filter to match the real naming, if it differs.')
    }
    else {
        [void] $lines.Add('WARN: the directory is empty. Take one screenshot first.')
    }
    return @($lines)
}

function Invoke-SelfTest {
    param(
        [string] $Dir, [string[]] $Pattern, [int] $SettleTimeoutMs = 5000, [int] $EventTimeoutSeconds = 5
    )

    Write-Log '=== SelfTest start ==='
    $pass = $true

    # 1. Environment checks.
    $diagnostic = @(Get-WatchDirDiagnostic -Dir $Dir -Pattern $Pattern)
    foreach ($line in $diagnostic) { Write-Log $line }
    if (@($diagnostic | Where-Object { $_ -like 'FAIL:*' }).Count -gt 0) { $pass = $false }

    $apt = [System.Threading.Thread]::CurrentThread.GetApartmentState()
    if ($apt -ne [System.Threading.ApartmentState]::STA) {
        Write-Log "FAIL: apartment state is $apt, expected STA (start with -STA)"
        $pass = $false
    }
    else {
        Write-Log 'OK: STA apartment'
    }

    if (-not $pass) {
        Write-Log '=== SelfTest result: FAIL ==='
        return 1
    }

    # 2. Exercise the real detect -> clipboard -> read-back cycle in a
    #    throwaway folder, so the user's own screenshots are never touched.
    $probeDir = Join-Path ([System.IO.Path]::GetTempPath()) 'winshot2clip-selftest'
    Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
    $null = New-Item -ItemType Directory -Path $probeDir -Force

    # A real, CRC-valid 1x1 RGBA PNG (68 bytes).
    $probePng = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNgAAIAAAUAAen63NgAAAAASUVORK5CYII='

    $seen    = @{}
    $pending = @{}
    $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'

    $probeScanName  = Get-ProbeName -Pattern $Pattern -Stamp $stamp -Kind 'scan'
    $probeEventName = Get-ProbeName -Pattern $Pattern -Stamp $stamp -Kind 'event'
    if ((-not (Test-NameMatchesPattern -Name $probeScanName -Pattern $Pattern)) -or
        (-not (Test-NameMatchesPattern -Name $probeEventName -Pattern $Pattern))) {
        Write-Log ("WARN: cannot synthesise a filename that matches '{0}'; skipping the copy probes." -f ($Pattern -join "', '"))
        Write-Log 'WARN: the directory and apartment checks above are still valid, but the clipboard round trip was NOT exercised.'
        Write-Log '=== SelfTest result: INCONCLUSIVE ==='
        Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
        return 3
    }

    try {
        # --- 2a. the scan path (this is what -Mode Poll does, and what the
        #         reconciliation backstop does) ---
        $probeScan = Join-Path $probeDir $probeScanName
        [IO.File]::WriteAllBytes($probeScan, [Convert]::FromBase64String($probePng))
        Write-Log "probe (scan) created: $probeScan"

        $copied = Invoke-ScanPass -Dir $probeDir -Pattern $Pattern -Seen $seen -Pending $pending -SettleTimeoutMs $SettleTimeoutMs
        if ($copied -eq 1) {
            Write-Log 'OK: scan pass detected and copied the probe'
        }
        else {
            Write-Log "FAIL: scan pass copied $copied file(s), expected 1"
            $pass = $false
        }

        # The clipboard holds whatever Copy-ScreenshotFile decided to send: with
        # the ASCII-copy workaround that is a %TEMP% copy, not the probe path.
        $back = Get-ClipboardFileList
        if ($null -ne $script:LastClipboardPath -and $back -contains $script:LastClipboardPath) {
            Write-Log "OK: clipboard read-back confirms the FileDropList holds $($script:LastClipboardPath)"
            if (Test-Path -LiteralPath $script:LastClipboardPath -PathType Leaf) {
                Write-Log 'OK: and that path exists as a file'
            }
            else {
                Write-Log 'FAIL: the path on the clipboard does not exist'
                $pass = $false
            }
        }
        else {
            Write-Log "FAIL: clipboard read-back did not hold the expected path (expected '$($script:LastClipboardPath)', got: $($back -join '; '))"
            $pass = $false
        }

        $again = Invoke-ScanPass -Dir $probeDir -Pattern $Pattern -Seen $seen -Pending $pending -SettleTimeoutMs $SettleTimeoutMs
        if ($again -eq 0) {
            Write-Log 'OK: a second scan pass does not copy it again'
        }
        else {
            Write-Log "FAIL: the same file was copied again ($again time(s))"
            $pass = $false
        }

        # --- 2b. the event path: arm a real watcher, create a file, and let
        #         the event queue drive it. This is the part that cannot be
        #         tested anywhere except on the target machine. ---
        $probeEventSource = 'WinShot2ClipSelfTest'
        $watcher = New-ScreenshotWatcher -Dir $probeDir -EventSource $probeEventSource
        Write-Log 'OK: FileSystemWatcher armed (Created / Renamed / Error)'

        try {
            $probeEvent = Join-Path $probeDir $probeEventName
            [IO.File]::WriteAllBytes($probeEvent, [Convert]::FromBase64String($probePng))
            Write-Log "probe (event) created: $probeEvent"

            $events = Invoke-EventCycle -Pattern $Pattern -Seen $seen -Pending $pending `
                                        -TimeoutSeconds $EventTimeoutSeconds `
                                        -EventSource $probeEventSource -SettleTimeoutMs $SettleTimeoutMs

            if ($events.Handled -gt 0) {
                Write-Log "OK: watcher delivered $($events.Handled) event(s)"
            }
            else {
                Write-Log "FAIL: no watcher event arrived within ${EventTimeoutSeconds}s"
                $pass = $false
            }

            if ($events.Copied -eq 1) {
                Write-Log 'OK: the event path copied the probe'
            }
            else {
                Write-Log "FAIL: the event path copied $($events.Copied) file(s), expected 1"
                $pass = $false
            }

            $back = Get-ClipboardFileList
            if ($null -ne $script:LastClipboardPath -and $back -contains $script:LastClipboardPath) {
                Write-Log "OK: clipboard read-back confirms the event path set the FileDropList to $($script:LastClipboardPath)"
            }
            else {
                Write-Log "FAIL: clipboard read-back did not hold the expected path (expected '$($script:LastClipboardPath)', got: $($back -join '; '))"
                $pass = $false
            }

            if (-not $events.NeedScan) {
                Write-Log 'OK: no buffer-overflow error reported'
            }
            else {
                Write-Log 'WARN: the watcher reported a buffer error during the test'
            }
        }
        finally {
            Remove-ScreenshotWatcher -Watcher $watcher -EventSource $probeEventSource
        }
    }
    catch {
        Write-Log "FAIL: unexpected error: $($_.Exception.Message)"
        $pass = $false
    }
    finally {
        Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log 'probe cleaned up (the clipboard still references a deleted probe file;'
        Write-Log 'the next real screenshot overwrites it)'
    }

    if ($pass) { Write-Log '=== SelfTest result: PASS ==='; return 0 }
    Write-Log '=== SelfTest result: FAIL ==='
    return 1
}

# ------------------------------------------------------------------- main ---

if ($SelfTest) {
    exit (Invoke-SelfTest -Dir $WatchDir -Pattern $Filter -SettleTimeoutMs $SettleTimeoutMs)
}

if ($Once) {
    try {
        $full = (Resolve-Path -LiteralPath $Once -ErrorAction Stop).Path
        $attempts = Set-ClipboardFile -Path $full
        Write-Log "clipboard set ($attempts attempts): $full"
        exit 0
    }
    catch {
        Write-Log "ERROR: $($_.Exception.Message)"
        exit 1
    }
}

if (-not (Test-Path -LiteralPath $WatchDir -PathType Container)) {
    Write-Log "ERROR: watch directory not found: $WatchDir"
    exit 2
}

# Single instance per logon session, so a double launch cannot fight itself.
# $mutex must stay referenced for the lifetime of the process: if it were
# allowed to be collected, the named mutex would be released and a second
# instance would start alongside this one and fight over the clipboard. Do not
# "clean up" this apparently unused variable.
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'WinShot2Clip', [ref] $createdNew)
if (-not $createdNew) {
    Write-Log 'another instance is already running, exiting'
    exit 0
}

$pending = @{}

if ($Mode -eq 'Watch') {
    # Start-WatchLoop arms the watcher and only then primes the baseline, so it
    # is handed an empty seen-set on purpose (see the comment in there).
    exit (Start-WatchLoop -Dir $WatchDir -Pattern $Filter -Seen @{} -Pending $pending `
                          -ReconcileSeconds $ReconcileSeconds -EventTimeoutSeconds $EventTimeoutSeconds `
                          -SettleTimeoutMs $SettleTimeoutMs)
}

$seen = New-SeenSet -Dir $WatchDir -Pattern $Filter
Write-Log ("baseline: {0} existing file(s) treated as already handled" -f $seen.Count)

exit (Start-PollLoop -Dir $WatchDir -Pattern $Filter -Seen $seen -Pending $pending `
                     -PollMs $PollMs -SettleTimeoutMs $SettleTimeoutMs)
