#Requires -Version 5.1
<#
    clipboard-variants.ps1 -- diagnostic for "the file is on the clipboard but
    Ctrl+V in the RDP session does not paste it".

    Background: Explorer's Ctrl+C on a file puts SIX formats on the clipboard
    (FileDrop, FileName, FileNameW, Shell IDList Array, Preferred DropEffect,
    Shell Object Offsets). Clipboard::SetFileDropList() puts ONE (FileDrop).
    mstsc may refuse to forward a file list that does not look like a shell
    copy, so this script tries several content shapes and lets you find out
    which one actually reaches the remote session.

    It is a diagnostic, not part of the tool. ASCII-only on purpose, like the
    rest of the scripts here.

    Usage:
      powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File clipboard-variants.ps1 -File "C:\path\to\shot.png"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $File
)

Add-Type -AssemblyName System.Windows.Forms

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ helpers --

function Get-ClipboardFormatNames {
    try {
        $data = [System.Windows.Forms.Clipboard]::GetDataObject()
        if ($null -eq $data) { return @() }
        return @($data.GetFormats())
    }
    catch { return @() }
}

function Show-WhatIsOnTheClipboard {
    $formats = Get-ClipboardFormatNames
    Write-Host ("    clipboard now holds {0} format(s):" -f $formats.Count)
    foreach ($f in $formats) { Write-Host ("      {0}" -f $f) }
    if ($formats.Count -eq 1 -and $formats[0] -eq 'FileDrop') {
        Write-Host '      ^ only FileDrop: this is the shape the tool produces today'
    }
}

function Wait-ForVerdict {
    param([string] $Name)
    Write-Host ''
    Write-Host '  >>> Now switch to the RDP session and press Ctrl+V. <<<'
    Write-Host ''
    while ($true) {
        $answer = Read-Host ("  Did '{0}' paste in the remote session? [y]es / [n]o / [s]kip" -f $Name)
        switch ($answer.Trim().ToLowerInvariant()) {
            'y' { return 'YES' }
            'n' { return 'NO' }
            's' { return 'SKIP' }
        }
    }
}

# -------------------------------------------------------- variant: shell ----
# Ask the shell itself to perform the copy. Shell.Application is an
# out-of-process COM server running inside explorer.exe, so the clipboard ends
# up holding exactly what a manual Ctrl+C produces -- including the formats we
# cannot reasonably build by hand (Shell IDList Array).

function Set-ClipboardByShellVerb {
    param([string] $Path)

    $directory = Split-Path -Parent $Path
    $leaf      = Split-Path -Leaf $Path

    $shell = New-Object -ComObject Shell.Application
    $folder = $shell.Namespace($directory)
    if ($null -eq $folder) { throw "cannot open folder: $directory" }
    $item = $folder.ParseName($leaf)
    if ($null -eq $item) { throw "cannot find item: $leaf" }

    # Canonical verb name, not the localised menu text.
    $item.InvokeVerb('copy')
}

# ------------------------------------------------- variant: raw clipboard ----
# A hand-built IDataObject, so that custom formats can carry raw bytes. The
# WinForms DataObject cannot do this: handing it a MemoryStream for a custom
# format makes OLE wrap the stream in a SerializedObject, which is not what a
# consumer reading raw bytes expects.

function Initialize-RawClipboard {
    if ('RawClipboardBuilder' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class RawClipboardBuilder
{
    [DllImport("ole32.dll", ExactSpelling = true, PreserveSig = false)]
    static extern void OleSetClipboard(IDataObject pDataObj);

    [DllImport("ole32.dll", ExactSpelling = true)]
    static extern int OleFlushClipboard();

    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    static extern uint RegisterClipboardFormat(string lpszFormat);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GlobalLock(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GlobalUnlock(IntPtr hMem);

    [DllImport("shell32.dll", ExactSpelling = true)]
    static extern int SHCreateStdEnumFmtEtc(uint cfmt, FORMATETC[] afmt, out IEnumFORMATETC ppenumFormatEtc);

    const uint GMEM_MOVEABLE = 0x0002;
    const uint GMEM_ZEROINIT = 0x0040;
    const short CF_HDROP = 15;
    const int DV_E_FORMATETC = unchecked((int)0x80040064);
    const int DATA_S_SAMEFORMATETC = 0x00040130;
    const int OLE_E_ADVISENOTSUPPORTED = unchecked((int)0x80040003);

    static IntPtr AllocGlobal(byte[] bytes)
    {
        IntPtr h = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, (UIntPtr)(uint)bytes.Length);
        if (h == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        IntPtr p = GlobalLock(h);
        try { Marshal.Copy(bytes, 0, p, bytes.Length); }
        finally { GlobalUnlock(h); }
        return h;
    }

    // DROPFILES header (20 bytes) followed by a double-null-terminated UTF-16 list.
    static byte[] BuildHDrop(string path)
    {
        byte[] pathBytes = System.Text.Encoding.Unicode.GetBytes(path);
        byte[] buffer = new byte[20 + pathBytes.Length + 2];
        BitConverter.GetBytes(20).CopyTo(buffer, 0);   // pFiles
        BitConverter.GetBytes(1).CopyTo(buffer, 16);   // fWide = TRUE
        pathBytes.CopyTo(buffer, 20);
        return buffer;
    }

    static byte[] Utf16Z(string s)
    {
        byte[] b = System.Text.Encoding.Unicode.GetBytes(s);
        byte[] r = new byte[b.Length + 2];
        b.CopyTo(r, 0);
        return r;
    }

    class BuiltDataObject : IDataObject
    {
        readonly List<short> _formats = new List<short>();
        readonly List<byte[]> _payloads = new List<byte[]>();

        public void AddFixed(short cf, byte[] payload)
        {
            _formats.Add(cf);
            _payloads.Add(payload);
        }

        public void AddNamed(string name, byte[] payload)
        {
            AddFixed((short)RegisterClipboardFormat(name), payload);
        }

        int IndexOf(short cf)
        {
            for (int i = 0; i < _formats.Count; i++) { if (_formats[i] == cf) return i; }
            return -1;
        }

        public int QueryGetData(ref FORMATETC format)
        {
            return IndexOf(format.cfFormat) < 0 ? DV_E_FORMATETC : 0;
        }

        public void GetData(ref FORMATETC format, out STGMEDIUM medium)
        {
            int i = IndexOf(format.cfFormat);
            if (i < 0) { throw new COMException("format not offered", DV_E_FORMATETC); }
            medium = new STGMEDIUM();
            medium.tymed = TYMED.TYMED_HGLOBAL;
            medium.unionmember = AllocGlobal(_payloads[i]);
            medium.pUnkForRelease = null;
        }

        public void GetDataHere(ref FORMATETC format, ref STGMEDIUM medium)
        {
            throw new COMException("not implemented", DV_E_FORMATETC);
        }

        public int GetCanonicalFormatEtc(ref FORMATETC formatIn, out FORMATETC formatOut)
        {
            formatOut = formatIn;
            return DATA_S_SAMEFORMATETC;
        }

        public void SetData(ref FORMATETC formatIn, ref STGMEDIUM medium, bool release)
        {
            throw new COMException("read-only data object", DV_E_FORMATETC);
        }

        public int DAdvise(ref FORMATETC format, ADVF advf, IAdviseSink sink, out int connection)
        {
            connection = 0;
            return OLE_E_ADVISENOTSUPPORTED;
        }

        public void DUnadvise(int connection) { }

        public int EnumDAdvise(out IEnumSTATDATA enumAdvise)
        {
            enumAdvise = null;
            return OLE_E_ADVISENOTSUPPORTED;
        }

        public IEnumFORMATETC EnumFormatEtc(DATADIR direction)
        {
            if (direction != DATADIR.DATADIR_GET) { throw new COMException("only DATADIR_GET", DV_E_FORMATETC); }
            FORMATETC[] list = new FORMATETC[_formats.Count];
            for (int i = 0; i < _formats.Count; i++)
            {
                list[i].cfFormat = _formats[i];
                list[i].dwAspect = DVASPECT.DVASPECT_CONTENT;
                list[i].lindex = -1;
                list[i].ptd = IntPtr.Zero;
                list[i].tymed = TYMED.TYMED_HGLOBAL;
            }
            IEnumFORMATETC enumerator;
            int hr = SHCreateStdEnumFmtEtc((uint)list.Length, list, out enumerator);
            if (hr != 0) { throw new COMException("SHCreateStdEnumFmtEtc failed", hr); }
            return enumerator;
        }
    }

    public static void Set(string path, bool withDropEffect, bool withFileNames)
    {
        BuiltDataObject o = new BuiltDataObject();
        o.AddFixed(CF_HDROP, BuildHDrop(path));

        if (withDropEffect)
        {
            // DROPEFFECT_COPY = 1, little-endian DWORD
            o.AddNamed("Preferred DropEffect", BitConverter.GetBytes(1));
        }
        if (withFileNames)
        {
            o.AddNamed("FileNameW", Utf16Z(path));
            o.AddNamed("FileName", System.Text.Encoding.Default.GetBytes(path + "\0"));
        }

        OleSetClipboard(o);
        OleFlushClipboard();
    }
}
'@
}

function Set-ClipboardByRawDataObject {
    param([string] $Path, [switch] $WithDropEffect, [switch] $WithFileNames)

    Initialize-RawClipboard
    [RawClipboardBuilder]::Set($Path, [bool]$WithDropEffect, [bool]$WithFileNames)
}

# -------------------------------------------------------------------- main --

if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
    Write-Host "no such file: $File"
    exit 1
}

$watchers = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
              Where-Object { $_.CommandLine -like '*winshot2clip.ps1*' })
if ($watchers.Count -gt 0) {
    Write-Host ''
    Write-Host 'WARNING: winshot2clip looks like it is running. It will overwrite the'
    Write-Host '         clipboard the moment a new screenshot appears, which would ruin'
    Write-Host '         this test. Stop it first (see the README).'
    Write-Host ''
}

Write-Host ''
Write-Host ("file under test: {0}" -f $File)
Write-Host ''
Write-Host 'CONTROL FIRST. In Explorer, manually select that same file and press Ctrl+C,'
Write-Host 'then paste in the remote session. We need to see that succeed before any'
Write-Host 'variant means anything.'
$control = Wait-ForVerdict -Name 'manual Ctrl+C (control)'
if ($control -ne 'YES') {
    Write-Host ''
    Write-Host 'The control failed, so the RDP path itself is not working right now and'
    Write-Host 'these variants cannot tell us anything. Fix the manual path first.'
    exit 1
}
Write-Host ''
Write-Host 'Control works. Now the variants.'
Write-Host ''

$results = New-Object System.Collections.ArrayList

$variants = @(
    @{
        Name = 'A: shell copy verb (explorer does the copy itself)'
        Set  = { param($p) Set-ClipboardByShellVerb -Path $p }
    },
    @{
        Name = 'B: FileDrop + Preferred DropEffect=COPY'
        Set  = { param($p) Set-ClipboardByRawDataObject -Path $p -WithDropEffect }
    },
    @{
        Name = 'C: FileDrop + Preferred DropEffect + FileNameW + FileName'
        Set  = { param($p) Set-ClipboardByRawDataObject -Path $p -WithDropEffect -WithFileNames }
    },
    @{
        Name = 'D: FileDrop + FileNameW + FileName (no DropEffect)'
        Set  = { param($p) Set-ClipboardByRawDataObject -Path $p -WithFileNames }
    },
    @{
        Name = 'E: FileDrop only (what the tool does today)'
        Set  = { param($p)
                     $list = New-Object System.Collections.Specialized.StringCollection
                     [void]$list.Add($p)
                     [System.Windows.Forms.Clipboard]::SetFileDropList($list)
                 }
    }
)

foreach ($variant in $variants) {
    Write-Host ('--- {0}' -f $variant.Name)

    # The shell verb variant may set the clipboard asynchronously, so wait for
    # the format list to actually change rather than trusting a fixed sleep.
    # Otherwise a slow shell looks like a variant that set nothing.
    $before = Get-ClipboardFormatNames
    try {
        & $variant.Set $File
    }
    catch {
        Write-Host ('    SETTING IT FAILED: {0}' -f $_.Exception.Message)
        [void]$results.Add([pscustomobject]@{ Variant = $variant.Name; Result = 'SETUP FAILED' })
        Write-Host ''
        continue
    }

    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $after = Get-ClipboardFormatNames
        if (@(Compare-Object -ReferenceObject $before -DifferenceObject $after -ErrorAction SilentlyContinue).Count -gt 0) { break }
    }
    if (@(Compare-Object -ReferenceObject $before -DifferenceObject (Get-ClipboardFormatNames) -ErrorAction SilentlyContinue).Count -eq 0) {
        Write-Host '    (the clipboard did not change at all within 5s)'
    }
    Show-WhatIsOnTheClipboard

    $verdict = Wait-ForVerdict -Name $variant.Name
    [void]$results.Add([pscustomobject]@{ Variant = $variant.Name; Result = $verdict })
    Write-Host ''
}

Write-Host '================ summary ================'
$results | Format-Table -AutoSize | Out-String | Write-Host
Write-Host 'Tell the maintainer which row said YES.'
