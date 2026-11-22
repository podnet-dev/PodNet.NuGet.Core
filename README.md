# PodNet.NuGet.Core [![Nuget](https://img.shields.io/nuget/v/PodNet.NuGet.Core)](https://www.nuget.org/packages/PodNet.NuGet.Core/)

A project containing the shared source, configuration and resources for development of PodNet NuGet packages.

Intended to be only used internally with `PodNet` packages. Source is available for reference only.

## PodNet.Sdk preview

`PodNet.Sdk` is a separate, additive MSBuild SDK package. It is not in the legacy solution or its tag-driven release path, and building it uses `Microsoft.NET.Sdk`, not itself. Existing `PodNet.NuGet.Core` consumers and packages are unchanged. The SDK is not yet published; do not add it as a `PackageReference` or combine its conventions with the legacy package during migration.

### Bootstrap and consume

1. Build the candidate with `dotnet pack sdk/PodNet.Sdk/PodNet.Sdk.csproj -c Release -o <local-feed> -p:Version=0.1.0-preview.1`. Configure the consumer's `NuGet.Config` with that local feed and nuget.org **before** opening or evaluating its projects. Map `PodNet.Sdk` to the local feed if other feeds may contain the same version. A new package version or a fresh `NUGET_PACKAGES` cache is necessary when testing changes to a locally built package with the same version.
2. Pin `"PodNet.Sdk": "0.1.0-preview.1"` under `msbuild-sdks` in the consumer's root `global.json`. Also select a .NET SDK supporting C# 15/net11.0; pin `MSTest.Sdk` separately when used.
3. In the repository-root `Directory.Build.props`, import `<Import Project="Sdk.props" Sdk="PodNet.Sdk" />` exactly once, before other shared settings. Set `<PodNetCopyrightYear>2026</PodNetCopyrightYear>` there and maintain it annually. In the root `Directory.Build.targets`, import `<Import Project="Sdk.targets" Sdk="PodNet.Sdk" />` exactly once. Do not replace `Microsoft.NET.Sdk` or `MSTest.Sdk` as the project SDK.
4. Opt each distributable project in with `<IsPackable>true</IsPackable>`; set its `Description` and `PackageTags`. Projects without that opt-in, including tests, are not packable. Put the package `README.md` at the root containing `Directory.Build.props`, or set `PodNetRepositoryRoot` explicitly if that file is not the repository root.

The early props default C# 15.0, nullable and implicit usings, artifacts output, and non-packability. CI environments `GITHUB_ACTIONS=true` or `TF_BUILD=true` get deterministic build defaults. Consumer properties set before an import win over conditional defaults; properties set later in `Directory.Build.props` or the project also override them. The late targets add packable-project defaults for MIT, symbols/source, documentation, author/company, `podnet-dev` repository URLs, and shared icon/sponsors/readme. Set explicit metadata and `RepositoryUrl` for repositories whose name differs from the project. `PodNetIncludeDefaultIcon`, `PodNetIncludeDefaultSponsorsFile`, and `PodNetIncludeDefaultReadmePath` can be set to `false` before the targets import when supplying custom assets. Explicit `Copyright` wins; otherwise it is derived solely from `PodNetCopyrightYear`, never from the clock.

Release packing validates that the consumer-owned `PodNetCopyrightYear` equals the current UTC year before generating a nuspec/package, even when `Copyright` is overridden. This check does not run for ordinary build or test. Packable projects must also provide `Description` and `PackageTags`.

### Gate

Run `pwsh ./tests/Gate2.ps1` with .NET SDK 11 and network access to nuget.org. It packs the candidate, resolves it in an isolated temporary feed and cache, evaluates metadata before restore, builds/tests an MSTest.Sdk 4.5.3 consumer with MTP, checks pack contents and invalid-year failures, and verifies the legacy package. The optional `-OutputFeed <existing-directory>` copies the exact validated nupkg after success and refuses to overwrite an existing file. The test cleans its temporary files; no credentials or publishing are involved.

## Sponsorship

If you're using our work or like what you see, consider supporting us. Every bit counts. 🙏 [See here for more info.](https://github.com/podNET-Hungary/PodNet.NuGet.Core/blob/main/src/PodNet.NuGet.Core/build/SPONSORS.md)