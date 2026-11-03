# dt-custom-services

PowerShell scripts that create Dynatrace Java custom services (entry points), one per group of package levels under a root package.

- `Group-ClassNames.ps1` groups class names or packages by the next N package levels under one or more roots. Nothing is sent to Dynatrace.
- `Create-CustomServices.ps1` uses it, validates each service against the Dynatrace API, and creates it. Dry run by default; add `-Create` to create.

Both scripts must sit in the same folder.

```powershell
$env:DT_URL = 'https://<env-id>.live.dynatrace.com'
$env:DT_API_TOKEN = '<token with ReadConfig + WriteConfig>'
.\Create-CustomServices.ps1 -ClassFile classes.txt            # dry run
.\Create-CustomServices.ps1 -ClassFile classes.txt -Create    # create
```

If scripts are blocked: `powershell.exe -ExecutionPolicy Bypass -File .\Create-CustomServices.ps1 -ClassFile classes.txt`

See the comment-based help at the top of each script for all parameters.
