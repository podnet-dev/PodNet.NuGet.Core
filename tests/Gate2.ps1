param([string]$OutputFeed = '')

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('podnet-sdk-gate2-' + [guid]::NewGuid().ToString('N'))
$feed = Join-Path $work 'feed'
$consumer = Join-Path $work 'consumer'
$saved = @{}
foreach ($name in @('NUGET_PACKAGES', 'NUGET_HTTP_CACHE_PATH', 'DOTNET_CLI_HOME', 'DOTNET_TEST_RUNNER', 'MSBUILDDISABLENODEREUSE', 'DOTNET_CLI_USE_MSBUILD_SERVER', 'DOTNET_GENERATE_ASPNET_CERTIFICATE', 'DOTNET_NOLOGO')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
function Assert($condition, [string]$message) { if (!$condition) { throw $message } }
function Invoke-Dotnet([string[]]$arguments) {
    Write-Host "> dotnet $($arguments -join ' ')"
    & dotnet @arguments
    if ($LASTEXITCODE -ne 0) { throw "dotnet failed ($LASTEXITCODE): $($arguments -join ' ')" }
}
function Properties([string]$project, [string[]]$extra = @()) {
    $result = & dotnet msbuild $project '-getProperty:LangVersion,Nullable,ImplicitUsings,UseArtifactsOutput,IsPackable,Authors,Company,Copyright,RepositoryUrl,PackageLicenseExpression,IncludeSymbols,GenerateDocumentationFile,Deterministic,ContinuousIntegrationBuild' @extra -v:q
    if ($LASTEXITCODE -ne 0) { throw "Metadata evaluation failed: $project" }
    return ($result | ConvertFrom-Json).Properties
}
function ZipEntries([string]$path) {
    $zip = [IO.Compression.ZipFile]::OpenRead($path)
    try { return @($zip.Entries | ForEach-Object FullName) } finally { $zip.Dispose() }
}
try {
    New-Item -ItemType Directory -Path $feed -Force | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'consumer') $consumer -Recurse
    $env:NUGET_PACKAGES = Join-Path $work 'packages'
    $env:NUGET_HTTP_CACHE_PATH = Join-Path $work 'http-cache'
    $env:DOTNET_CLI_HOME = Join-Path $work 'dotnet-home'
    $env:DOTNET_TEST_RUNNER = 'Microsoft.Testing.Platform'
    $env:MSBUILDDISABLENODEREUSE = '1'
    $env:DOTNET_CLI_USE_MSBUILD_SERVER = '0'
    $env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
    $env:DOTNET_NOLOGO = 'true'
    $escapedFeed = [Security.SecurityElement]::Escape($feed)
    $config = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources><clear/><add key="candidate" value="$escapedFeed"/><add key="nuget.org" value="https://api.nuget.org/v3/index.json"/></packageSources>
  <packageSourceMapping><packageSource key="candidate"><package pattern="PodNet.Sdk"/></packageSource><packageSource key="nuget.org"><package pattern="*"/></packageSource></packageSourceMapping>
  <fallbackPackageFolders><clear/></fallbackPackageFolders>
</configuration>
"@
    $config | Set-Content -LiteralPath (Join-Path $work 'NuGet.Config') -Encoding utf8
    Push-Location $work
    try {
        $sdkProject = Join-Path $root 'sdk/PodNet.Sdk/PodNet.Sdk.csproj'
        Invoke-Dotnet @('pack', $sdkProject, '-c', 'Release', '-o', $feed, '--configfile', (Join-Path $work 'NuGet.Config'), '-p:Version=0.1.0-preview.1')
        $candidate = Join-Path $feed 'PodNet.Sdk.0.1.0-preview.1.nupkg'
        Assert (Test-Path -LiteralPath $candidate) 'Candidate missing.'
        $sdkEntries = ZipEntries $candidate
        foreach ($entry in @('Sdk/Sdk.props', 'Sdk/Sdk.targets', 'Sdk/icon.png', 'Sdk/SPONSORS.md')) { Assert ($entry -in $sdkEntries) "SDK package missing $entry" }
        Assert (!@($sdkEntries | Where-Object { $_ -like 'lib/*' }).Count) 'SDK package unexpectedly has library assets.'
        $sdkZip = [IO.Compression.ZipFile]::OpenRead($candidate)
        try {
            $sdkNuspec = $sdkZip.Entries | Where-Object FullName -Like '*.nuspec' | Select-Object -First 1
            $reader = [IO.StreamReader]::new($sdkNuspec.Open()); try { $sdkMetadata = $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $sdkZip.Dispose() }
        Assert ($sdkMetadata -match '<packageType name="MSBuildSdk"') 'MSBuildSdk package type missing.'
        Assert ($sdkMetadata -notmatch '<dependency\s') 'SDK package must not have dependencies.'

        Push-Location $consumer
        try {
            $library = Join-Path $consumer 'src/Fixture/Fixture.csproj'
            $tests = Join-Path $consumer 'tests/Fixture.Tests/Fixture.Tests.csproj'
            Assert (!(Test-Path (Join-Path $consumer 'artifacts'))) 'Consumer was already restored.'
            $p = Properties $library
            foreach ($pair in @(@('LangVersion','15.0'), @('Nullable','enable'), @('ImplicitUsings','enable'), @('UseArtifactsOutput','true'), @('IsPackable','true'), @('PackageLicenseExpression','MIT'), @('IncludeSymbols','true'), @('GenerateDocumentationFile','true'))) { Assert ($p.($pair[0]) -eq $pair[1]) "Unexpected $($pair[0]): $($p.($pair[0]))" }
            Assert ($p.RepositoryUrl -eq 'https://github.com/podnet-dev/Fixture') 'Repository URL default mismatch.'
            Assert ($p.Authors -eq 'podNET Hungary, Gábor Szabó' -and $p.Company -eq 'podNET Hungary') "Author or company default mismatch: $($p.Authors), $($p.Company)"
            Assert ($p.Copyright -eq 'Copyright (c) 2026 podNET Hungary') 'Stable year-based copyright default mismatch.'
            Assert ((Properties $tests).IsPackable -eq 'false') 'Test project must not be packable.'
            $overrides = Properties $library @('-p:LangVersion=14.0', '-p:Copyright=Explicit Copyright', '-p:RepositoryUrl=https://example.org/repo', '-p:IncludeSymbols=false')
            Assert ($overrides.LangVersion -eq '14.0' -and $overrides.Copyright -eq 'Explicit Copyright' -and $overrides.RepositoryUrl -eq 'https://example.org/repo' -and $overrides.IncludeSymbols -eq 'false') 'Explicit overrides did not win.'
            $projectOverrides = Properties (Join-Path $consumer 'src/Overrides/Overrides.csproj')
            Assert ($projectOverrides.LangVersion -eq '14.0' -and $projectOverrides.Authors -eq 'Custom author' -and $projectOverrides.Company -eq 'Custom company' -and $projectOverrides.Copyright -eq 'Custom copyright' -and $projectOverrides.RepositoryUrl -eq 'https://example.org/custom' -and $projectOverrides.IncludeSymbols -eq 'false' -and $projectOverrides.GenerateDocumentationFile -eq 'false') 'Project properties did not override defaults.'
            $ci = Properties $library @('-p:GITHUB_ACTIONS=true')
            Assert ($ci.Deterministic -eq 'true' -and $ci.ContinuousIntegrationBuild -eq 'true') 'CI determinism defaults missing.'
            Assert (Test-Path (Join-Path $env:NUGET_PACKAGES 'podnet.sdk/0.1.0-preview.1')) 'SDK was not resolved into isolated cache before restore.'
            $resolvedSdk = Join-Path $env:NUGET_PACKAGES 'podnet.sdk/0.1.0-preview.1/podnet.sdk.0.1.0-preview.1.nupkg'
            Assert ((Get-FileHash $resolvedSdk).Hash -eq (Get-FileHash $candidate).Hash) 'Resolved SDK differs from the built candidate.'
            Write-Host 'PASS: pre-restore defaults, opt-in, overrides, CI, and isolated SDK resolution.'

            $year = [DateTime]::UtcNow.Year.ToString()
            Invoke-Dotnet @('test', '--project', $tests, '-c', 'Release', '-p:PodNetCopyrightYear=2000')
            Write-Host 'PASS: Release build and MTP tests run with stale copyright year.'
            $badOutput = Join-Path $work 'bad-pack'
            foreach ($invalid in @('2000', '')) {
                Write-Host "> expected failure: Release pack year '$invalid'"
                $out = & dotnet pack $library -c Release -o $badOutput "-p:PodNetCopyrightYear=$invalid" 2>&1 | Out-String
                Assert ($LASTEXITCODE -ne 0 -and $out -match 'PodNetCopyrightYear') "Expected copyright diagnostic: $out"
                Assert (!@(Get-ChildItem $badOutput -Filter '*.nupkg' -ErrorAction SilentlyContinue).Count) 'A package was created despite invalid copyright year.'
            }
            Write-Host 'PASS: missing and stale year rejected before package creation.'
            $outDir = Join-Path $work 'consumer-pack'
            Invoke-Dotnet @('pack', $library, '-c', 'Release', '-o', $outDir, "-p:PodNetCopyrightYear=$year", '-p:Copyright=Explicit Copyright')
            $packed = Join-Path $outDir 'Fixture.1.0.0.nupkg'
            Assert (Test-Path $packed) 'Consumer package missing.'
            $entries = ZipEntries $packed
            foreach ($entry in @('README.md','icon.png','SPONSORS.md','lib/netstandard2.0/Fixture.dll','lib/netstandard2.0/Fixture.xml')) { Assert ($entry -in $entries) "Consumer package missing $entry" }
            Assert (@(Get-ChildItem $outDir -Filter '*.snupkg').Count -eq 1) 'Symbol package missing.'
            $zip = [IO.Compression.ZipFile]::OpenRead($packed)
            try {
                $entry = $zip.Entries | Where-Object FullName -Like '*.nuspec' | Select-Object -First 1
                $reader = [IO.StreamReader]::new($entry.Open()); try { $nuspec = $reader.ReadToEnd() } finally { $reader.Dispose() }
            } finally { $zip.Dispose() }
            Assert ($nuspec -match 'Explicit Copyright') 'Explicit copyright missing from package.'
            Assert ($nuspec -notmatch '<dependency id="PodNet\.Sdk"') 'SDK leaked into runtime dependencies.'
            Write-Host 'PASS: package assets, explicit copyright, symbols, and no SDK runtime dependency.'
        } finally { Pop-Location }

        $legacyOut = Join-Path $work 'legacy-pack'
        Invoke-Dotnet @('pack', (Join-Path $root 'src/PodNet.NuGet.Core/PodNet.NuGet.Core.csproj'), '-c', 'Release', '-o', $legacyOut, '--configfile', (Join-Path $work 'NuGet.Config'), '-p:Version=0.0.1-gate2')
        $legacy = Join-Path $legacyOut 'PodNet.NuGet.Core.0.0.1-gate2.nupkg'
        Assert (Test-Path $legacy) 'Legacy package missing.'
        $legacyEntries = ZipEntries $legacy
        foreach ($entry in @('build/PodNet.NuGet.Core.props','build/PodNet.NuGet.Core.targets','build/icon.png','build/SPONSORS.md','lib/netstandard2.0/_._')) { Assert ($entry -in $legacyEntries) "Legacy package missing $entry" }
        Write-Host 'PASS: legacy package still packs with its expected assets.'
        if ($OutputFeed) {
            Assert (Test-Path -LiteralPath $OutputFeed -PathType Container) 'Output feed must already exist.'
            $destination = Join-Path $OutputFeed (Split-Path $candidate -Leaf)
            Assert (!(Test-Path -LiteralPath $destination)) 'Refusing to overwrite an existing candidate.'
            Copy-Item -LiteralPath $candidate -Destination $destination
            Assert ((Get-FileHash $candidate).Hash -eq (Get-FileHash $destination).Hash) 'Staged candidate hash mismatch.'
            Write-Host "Validated candidate: $destination"
        }
        Write-Host 'Gate 2 passed.'
    } finally { Pop-Location }
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}