param([Parameter(Mandatory)][string]$Resx, [Parameter(Mandatory)][string]$Out)
# Windows PowerShell 5.1 / .NET Framework: convert a .resx to a binary .resources file (replacement for resgen.exe).
Add-Type -AssemblyName System.Windows.Forms
$reader = New-Object System.Resources.ResXResourceReader($Resx)
$reader.BasePath = Split-Path -Parent (Resolve-Path $Resx)
$writer = New-Object System.Resources.ResourceWriter($Out)
try {
    foreach ($e in $reader) { $writer.AddResource([string]$e.Key, $e.Value) }
    $writer.Generate()
} finally { $writer.Close(); $reader.Close() }
"wrote $Out ($((Get-Item $Out).Length) bytes)"
