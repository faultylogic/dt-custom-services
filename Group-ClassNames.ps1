<#
.SYNOPSIS
  Groups class names or packages by the next N package levels under a root package.

.DESCRIPTION
  Reads class names or packages from a file (-ClassFile) or from the pipeline and groups them by the N package
  levels after a root (-Root takes one or more; default ca.gc.cra and ca.gc.ccra, 2 levels:
  ca.gc.cra.awsc.web.Foo -> "awsc.web"). Emits one object per group with Root, Name, Classes (the number of
  input lines in the group) and ClassNames (the distinct fully qualified class names). Lines under none of the
  roots are skipped with a warning. Nothing is sent to Dynatrace.

  Input lines may be dotted (ca.gc.cra.awsc.web.Foo), slashed (ca/gc/cra/awsc/web/Foo.class) or packages only.
  Blank lines and lines starting with # are ignored. A final segment starting with an upper-case letter, or
  containing '_' or digits (generated stubs), is a class name; anything else is a package. Package-only lines
  count toward the group but add no class name, so no rule can be built from them.

  A class line may carry one method after '#': Class#[visibility ]name(argType,argType):returnType, for example
  ca.gc.ccra.rccr.web.filter.CacheControlSetter#doFilter(javax.servlet.ServletRequest,javax.servlet.ServletResponse,javax.servlet.FilterChain):void
  Visibility defaults to public. Give the return type: Dynatrace requires one and documents no wildcard.
  Repeat the class on several lines for several methods (identical methods are merged). Emitted as Methods:
  class name -> method objects. A class with no method lines has no method list, and Create-CustomServices.ps1
  builds no rule for it.

.EXAMPLE
  .\Group-ClassNames.ps1 -ClassFile classes.txt

.EXAMPLE
  Get-Content classes.txt | .\Group-ClassNames.ps1 -Levels 3
#>
[CmdletBinding()]
param(
    [string]$ClassFile,
    [Parameter(ValueFromPipeline = $true)][string[]]$ClassPath,
    [string[]]$Root = @('ca.gc.cra', 'ca.gc.ccra'),
    [ValidateRange(1, 5)][int]$Levels = 2
)

begin { $lines = New-Object System.Collections.Generic.List[string] }
process { if ($ClassPath) { foreach ($c in $ClassPath) { $lines.Add($c) } } }
end {
    $ErrorActionPreference = 'Stop'
    if ($ClassFile) { Get-Content -LiteralPath $ClassFile | ForEach-Object { $lines.Add($_) } }
    if ($lines.Count -eq 0) { throw 'No input: pass -ClassFile <file> or pipe class names in.' }

    $roots = @($Root | ForEach-Object { $_.Trim().Trim('.') } | Where-Object { $_ })
    $services = [ordered]@{}
    foreach ($raw in $lines) {
        $l = $raw.Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        $methodText = $null   # optional "#[visibility ]method(argType,...):returnType" after the class
        $hash = $l.IndexOf('#')
        if ($hash -ge 0) { $methodText = $l.Substring($hash + 1).Trim(); $l = $l.Substring(0, $hash).Trim() }
        $l = ($l -replace '\.class$', '' -replace '[/\\]', '.').Trim('.')
        $match = $null   # longest root the line sits under
        foreach ($r in $roots) { if (($l -eq $r -or $l.StartsWith("$r.")) -and (-not $match -or $r.Length -gt $match.Length)) { $match = $r } }
        if (-not $match) { Write-Warning "Skipped (not under $($roots -join ', ')): $raw"; continue }
        $rest = @($l.Substring($match.Length).Trim('.').Split('.') | Where-Object { $_ })
        # A last segment is a class when it starts upper-case or contains '_' or digits (generated stubs like rccr_ctg_..._WLStub)
        $fullClass = $null
        if ($rest.Count -gt 0 -and ($rest[-1] -cmatch '^[A-Z]' -or $rest[-1] -match '[_0-9]')) {
            $fullClass = $l
            $rest = @($rest | Select-Object -SkipLast 1)   # drop the class name
        }
        else { Write-Warning "Package only, no class name (no rule can be built from it): $raw" }
        if ($rest.Count -lt $Levels) { Write-Warning "Skipped (fewer than $Levels package levels under $match): $raw"; continue }
        $name = ($rest[0..($Levels - 1)] -join '.')
        $key = "$match|$name"
        if (-not $services.Contains($key)) { $services[$key] = [pscustomobject]@{ Root = $match; Name = $name; Classes = 0; ClassNames = (New-Object System.Collections.Generic.List[string]); Methods = [ordered]@{} } }
        $services[$key].Classes++
        if ($fullClass -and -not $services[$key].ClassNames.Contains($fullClass)) { $services[$key].ClassNames.Add($fullClass) }
        if ($fullClass -and $methodText) {
            if ($methodText -match '^(?:(?<vis>public|private|protected|package)\s+)?(?<m>[^\s(]+)\s*\((?<args>[^)]*)\)\s*(?::\s*)?(?<ret>\S+)?$') {
                $vis = if ($Matches.vis) { $Matches.vis.ToUpper() } else { 'PUBLIC' }
                $argTypes = @($Matches.args.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $ret = if ($Matches.ret) { $Matches.ret } else { '*' }
                if (-not $services[$key].Methods.Contains($fullClass)) { $services[$key].Methods[$fullClass] = New-Object System.Collections.Generic.List[object] }
                $sig = "$vis $($Matches.m)($($argTypes -join ','))$ret"
                if (-not ($services[$key].Methods[$fullClass] | Where-Object { $_.Signature -eq $sig })) {
                    $services[$key].Methods[$fullClass].Add([pscustomobject]@{ Signature = $sig; MethodName = $Matches.m; ArgumentTypes = $argTypes; ReturnType = $ret; Visibility = $vis })
                }
            }
            else { Write-Warning "Method not understood (expected #[visibility ]name(argType,...):returnType): $raw" }
        }
    }
    if ($services.Count -eq 0) { throw "No input line starts with: $($roots -join ', ')." }

    $services.Values
}
