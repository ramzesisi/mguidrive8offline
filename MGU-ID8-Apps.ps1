param(
    [Parameter(Mandatory)]
    [ValidateSet('Download', 'Install')]
    [string]$Mode,

    [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}$')]
    [string]$MguAddress = 'ваш ip машины',

    [string]$Identity,
    [switch]$LegacyScp
)

$ErrorActionPreference = 'Stop'
$bundle = Join-Path $PSScriptRoot 'id8-bundle'

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)

    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program exited with code $LASTEXITCODE."
    }
}

if ($Mode -eq 'Download') {
    Get-Command git.exe, node.exe | Out-Null

    if (Test-Path -LiteralPath $bundle) {
        throw 'id8-bundle already exists. Use it or rename it before downloading a fresh bundle.'
    }

    $tags = Invoke-RestMethod 'https://api.github.com/repos/IterioDev/car-apps/tags?per_page=100'
    $tag = ($tags | Where-Object { $_.name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.name } -Descending |
        Select-Object -First 1).name
    if (-not $tag) { throw 'No stable car-apps tag found.' }

    $work = Join-Path $PSScriptRoot ('.id8-build-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work

    try {
        Invoke-Checked git.exe @('clone', '-c', 'core.autocrlf=false', '--depth', '1',
            '--branch', $tag, 'https://github.com/IterioDev/car-apps.git', 'car-apps')
        Invoke-Checked git.exe @('clone', '-c', 'core.autocrlf=false', '--depth', '1',
            'https://github.com/robertnisipeanu/mgu-store.git', 'store')
        New-Item -ItemType Directory -Path 'packages', 'deps' | Out-Null

        $metadata = @()
        foreach ($dir in Get-ChildItem '.\car-apps\apps' -Directory) {
            $file = Join-Path $dir.FullName 'app.json'
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }

            $app = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            if ($app.mguHmi -notcontains 'ID8') { continue }

            $name = "$($app.id)@$($app.version).tgz"
            Copy-Item -LiteralPath (Join-Path $dir.FullName $name) -Destination '.\packages'
            $metadata += $app
            Write-Host "$($app.title) $($app.version)"
        }
        if ($metadata.Count -eq 0) { throw 'No ID8 applications found.' }

        foreach ($dir in Get-ChildItem '.\car-apps\tools' -Directory) {
            $file = Join-Path $dir.FullName 'component.json'
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }

            $tool = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            if ($tool.mguHmi -and $tool.mguHmi -notcontains 'ID8') { continue }

            Invoke-Checked node.exe @('./store/deploy/hu', 'artifact',
                "./car-apps/tools/$($dir.Name)", '--out', './packages')

            $expected = ".\packages\$($tool.id)@$($tool.version).tgz"
            if (-not (Test-Path -LiteralPath $expected -PathType Leaf)) {
                throw "Expected tool archive not found: $expected"
            }
            $metadata += $tool
        }

        Invoke-Checked node.exe @('./store/deploy/mgu-install.js', 'usb-repo',
            './deps', 'github:robertnisipeanu/idrive-apps')
        Copy-Item '.\deps\mgu-repo\idrive-apps\cluster-render@*.tgz' -Destination '.\packages'

        $requirements = @(
            foreach ($item in $metadata) {
                if ($item.requires) {
                    foreach ($req in $item.requires.PSObject.Properties) {
                        [pscustomobject]@{ App = $item.id; Id = $req.Name; Min = [string]$req.Value }
                    }
                }
            }
        )

        ConvertTo-Json -InputObject $requirements |
            Set-Content '.\packages\requirements.json' -Encoding UTF8

        Move-Item -LiteralPath '.\packages' -Destination $bundle
    }
    finally {
        Pop-Location
    }

    Get-ChildItem -LiteralPath $bundle -Filter '*.tgz' -File |
        Select-Object -ExpandProperty Name
    Write-Host "Bundle ready: $bundle"
    return
}

if (-not $Identity) {
    $enrollments = Join-Path $PSScriptRoot 'data\enrollments'
    $keys = @(Get-ChildItem -LiteralPath $enrollments -Filter 'id_rsa' -File -Recurse)
    if ($keys.Count -ne 1) {
        throw 'Pass -Identity with the path to the id_rsa for this MGU.'
    }
    $Identity = $keys[0].FullName
}
$key = (Get-Item -LiteralPath $Identity).FullName

$manifest = Join-Path $bundle 'requirements.json'
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    throw 'Run Download first and wait for Bundle ready.'
}
$files = @(Get-ChildItem -LiteralPath $bundle -Filter '*.tgz' -File)
if ($files.Count -eq 0) { throw 'No packages in id8-bundle.' }

$target = "root@$MguAddress"
$sshArgs = @('-i', $key, '-o', 'ConnectTimeout=10', $target)
$deploy = 'sh /var/opt/mgu-deploy/mgu-deploy.sh'
$statusLines = Invoke-Checked ssh.exe ($sshArgs + @("$deploy status --read-only --json"))
$status = ($statusLines -join "`n") | ConvertFrom-Json

$versions = @{}
foreach ($component in $status.components) {
    $version = $component.version -as [version]
    if ($component.id -and $version) { $versions[$component.id] = $version }
}
if (-not $versions.ContainsKey('mgu-deploy') -or $versions['mgu-deploy'] -lt [version]'0.8.20') {
    throw 'MGU Store must have mgu-deploy 0.8.20 or newer.'
}

foreach ($file in $files) {
    if ($file.Name -notmatch '^([A-Za-z0-9_.-]+)@(\d+\.\d+\.\d+)\.tgz$') {
        throw "Unexpected package name: $($file.Name)"
    }
    $id = $Matches[1]
    $version = [version]$Matches[2]
    if (-not $versions.ContainsKey($id) -or $versions[$id] -lt $version) {
        $versions[$id] = $version
    }
}

foreach ($req in (Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json)) {
    $min = $req.Min -as [version]
    if (-not $min -or -not $versions.ContainsKey($req.Id) -or $versions[$req.Id] -lt $min) {
        throw "$($req.App) requires $($req.Id) $($req.Min) or newer."
    }
}

$remote = '/tmp/id8-apps-' + [guid]::NewGuid().ToString('N')
Invoke-Checked ssh.exe ($sshArgs + @("mkdir -p '$remote'"))

$scpArgs = @('-i', $key)
if ($LegacyScp) { $scpArgs = @('-O') + $scpArgs }
$paths = @($files | ForEach-Object { $_.FullName })
Invoke-Checked scp.exe ($scpArgs + $paths + @("${target}:$remote/"))

$artifacts = ($files | ForEach-Object { "--artifact '$remote/$($_.Name)'" }) -join ' '
Invoke-Checked ssh.exe ($sshArgs + @("$deploy check $artifacts"))
Invoke-Checked ssh.exe ($sshArgs + @("$deploy install $artifacts --skip-older --yes"))

Write-Host 'Install command completed. Restart iDrive if the log shows pending reboot.'
