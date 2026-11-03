<#
.SYNOPSIS
  Creates one Java custom service (entry point) per "<next N package levels>" under each root package
  (default roots: ca.gc.cra and ca.gc.ccra).

.DESCRIPTION
  Groups class names or packages into services with Group-ClassNames.ps1 (same folder; it owns the input format
  and the grouping: ca.gc.cra.awsc.web.Foo -> service "awsc.web"), validates each payload against the Dynatrace
  validator, and creates it. Dry run by default: nothing is created without -Create.
  Services that already exist (same name) are updated in place with -Create, so the script can be re-run.
  Each service gets one rule per class (EQUALS on the full class name, because this API only allows prefix
  matching together with an annotation), so the input needs full class names; package-only lines add no rule.
  A class line can list methods (Class#doFilter(argType,...):void, see Group-ClassNames.ps1) and the rule then
  matches exactly those. A class with no methods gets one wildcard rule (any public method; narrow it with
  -ReturnType / -ArgumentTypes), though Dynatrace may not treat '*' as a wildcard.
  -ProcessGroups limits every service to one or more process groups (IDs); omitted = all process groups.

.EXAMPLE
  $env:DT_URL = 'https://abc12345.live.dynatrace.com'; $env:DT_API_TOKEN = '...'   # token: ReadConfig + WriteConfig
  .\Create-CustomServices.ps1 -ClassFile classes.txt            # dry run: shows services and validates
  .\Create-CustomServices.ps1 -ClassFile classes.txt -Create    # creates them

.EXAMPLE
  Get-Content classes.txt | .\Create-CustomServices.ps1 -Create
#>
[CmdletBinding()]
param(
    [string]$ClassFile,
    [Parameter(ValueFromPipeline = $true)][string[]]$ClassPath,
    [string[]]$Root = @('ca.gc.cra', 'ca.gc.ccra'),
    [ValidateRange(1, 5)][int]$Levels = 2,
    [string]$EnvUrl = $env:DT_URL,
    [string]$Token = $env:DT_API_TOKEN,
    [string]$MethodName = '*',
    [string]$ReturnType = '*',  # the API requires a value; '*' = any return type
    [string[]]$ArgumentTypes,   # omitted = any arguments; pass @() for no-argument methods only
    [string[]]$ProcessGroups,   # process group IDs (PROCESS_GROUP-...) the services apply to; omitted = all    [switch]$Create
)

begin { $lines = New-Object System.Collections.Generic.List[string] }
process { if ($ClassPath) { foreach ($c in $ClassPath) { $lines.Add($c) } } }
end {
    $ErrorActionPreference = 'Stop'
    if (-not $ClassFile -and $lines.Count -eq 0) { throw 'No input: pass -ClassFile <file> or pipe class names in.' }
    if (-not $EnvUrl -or -not $Token) { throw 'Set DT_URL and DT_API_TOKEN (or pass -EnvUrl / -Token). Use the classic host, not *.apps.*.' }

    $EnvUrl = $EnvUrl.TrimEnd('/')
    $base = "$EnvUrl/api/config/v1/service/customServices/java"
    $headers = @{ Authorization = "Api-Token $Token" }

    # 1. Group the input by the next $Levels package levels under the root
    $groupArgs = @{ Root = $Root; Levels = $Levels }
    if ($ClassFile) { $groupArgs.ClassFile = $ClassFile }
    $groups = @($lines | & (Join-Path $PSScriptRoot 'Group-ClassNames.ps1') @groupArgs)
    # Same name under two roots: fall back to the full prefix so the services stay distinct
    $dupes = @($groups | Group-Object Name | Where-Object Count -gt 1 | ForEach-Object Name)
    $services = [ordered]@{}
    foreach ($g in $groups) {
        $prefix = "$($g.Root).$($g.Name)"
        $services[$(if ($dupes -contains $g.Name) { $prefix } else { $g.Name })] = [pscustomobject]@{ Prefix = $prefix; Classes = $g.Classes; ClassNames = @($g.ClassNames); Methods = $g.Methods }
    }

    # 2. Existing services, so re-runs skip them
    $existing = @{}
    foreach ($v in @((Invoke-RestMethod -Headers $headers -Uri $base).values)) { $existing[$v.name] = $v.id }

    # Method rule: every public method of the matched classes, any return type and arguments unless narrowed
    $methodRule = [ordered]@{ methodName = $MethodName; returnType = $ReturnType; visibility = 'PUBLIC' }
    if ($PSBoundParameters.ContainsKey('ArgumentTypes')) { $methodRule.argumentTypes = @($ArgumentTypes) }

    # 3. Build, validate, create
    $report = foreach ($name in $services.Keys) {
        # One EQUALS rule per class: this Dynatrace API only allows STARTS_WITH together with an annotation
        $rules = @(foreach ($c in $services[$name].ClassNames) {
                # Explicit methods from the input (#method(args):return) win; a class without any gets the wildcard rule
                $listed = $services[$name].Methods[$c]
                $methodRules = if ($listed -and $listed.Count) {
                    @($listed | ForEach-Object { [ordered]@{ methodName = $_.MethodName; argumentTypes = @($_.ArgumentTypes); returnType = $_.ReturnType; visibility = $_.Visibility } })
                } else { @($methodRule) }
                [ordered]@{ enabled = $true; className = $c; matcher = 'EQUALS'; methodRules = $methodRules }
            })
        if ($rules.Count -eq 0) {
            [pscustomobject]@{ Service = $name; Group = $services[$name].Prefix; Rules = 0; Status = 'SKIPPED: only package names given, full class names needed' }
            continue
        }
        $payload = [ordered]@{
            name            = $name
            enabled         = $true
            queueEntryPoint = $true
            rules           = $rules
            processGroups   = @($ProcessGroups)
        } | ConvertTo-Json -Depth 8

        $status = 'ok'
        try { Invoke-RestMethod -Method Post -Headers $headers -ContentType 'application/json' -Body $payload -Uri "$base/validator" | Out-Null }
        catch { $status = "INVALID: $($_.ErrorDetails.Message)" }

        if ($existing.ContainsKey($name)) {
            # Re-running with -Create brings an existing service in line with the current rule
            if ($status -eq 'ok' -and $Create) {
                try { Invoke-RestMethod -Method Put -Headers $headers -ContentType 'application/json' -Body $payload -Uri "$base/$($existing[$name])" | Out-Null; $status = "updated $($existing[$name])" }
                catch { $status = "FAILED: $($_.ErrorDetails.Message)" }
            }
            elseif ($status -eq 'ok') { $status = 'exists, valid (dry run: would update)' }
        }
        elseif ($status -eq 'ok' -and $Create) {
            try { $r = Invoke-RestMethod -Method Post -Headers $headers -ContentType 'application/json' -Body $payload -Uri $base; $status = "created $($r.id)" }
            catch { $status = "FAILED: $($_.ErrorDetails.Message)" }
        }
        elseif ($status -eq 'ok') { $status = 'valid (dry run)' }

        [pscustomobject]@{ Service = $name; Group = $services[$name].Prefix; Rules = $rules.Count; Status = $status }
    }
    $report | Format-Table -AutoSize
    # The table truncates long statuses, so print each distinct error in full
    foreach ($e in @($report | Where-Object { $_.Status -match '^(INVALID|FAILED)' } | ForEach-Object { $_.Status } | Select-Object -Unique)) { Write-Host $e -ForegroundColor Red }

    if (-not $Create) { Write-Host 'Dry run: nothing was created. Re-run with -Create to create the services.' }
    if ($EnvUrl -match '/e/[0-9a-f-]+$') {
        Write-Host "Custom service detection (Managed): $EnvUrl > Settings > Server-side service monitoring > Custom service detection"
    }
    else {
        $ui = $EnvUrl -replace '\.live\.dynatrace\.com$', '.apps.dynatrace.com' -replace '(?<!\.apps)\.dynatracelabs\.com$', '.apps.dynatracelabs.com'
        Write-Host "Custom service detection: $ui/ui/apps/dynatrace.settings/settings/custom-service-detection"
    }
}
