# SlateRegistry

A Julia package registry for [Kaimon Slate](https://github.com/kahliburke/KaimonSlate.jl) and
its extension packages, which aren't in the General registry.

This repository is public and contains only package metadata — names, versions and repository
URLs. Some of the packages it points at are private; installing those still requires access to
their repositories.

## Use

Add the registry once per machine, from the Pkg REPL (press `]`):

```julia-repl
pkg> registry add https://github.com/kahliburke/SlateRegistry
```

It sits alongside General rather than replacing it — Pkg searches every installed registry, so
ordinary packages keep resolving as usual. After that, Slate installs like any other package:

```julia-repl
pkg> app add KaimonSlate      # the `slate` launcher
pkg> add SlateAssess          # an extension, into your notebook's environment
```

Registries are cached locally, so a newly published version isn't visible until you refresh:

```julia-repl
pkg> registry update
```

If a package or version "does not exist" and you think it should, run that first — a stale
registry is the usual cause.

## Packages

| Package | Repository | Visibility |
|---|---|---|
| `KaimonSlate` | [KaimonSlate.jl](https://github.com/kahliburke/KaimonSlate.jl) | public |
| `SlateExtensionsBase` | KaimonSlate.jl, `lib/SlateExtensionsBase` | public |
| `SlatePlotly` | SlatePlotly.jl | private |
| `SlateAssess` | SlateAssess.jl | private |

Installing a private package needs git credentials for GitHub. The registry records repository
locations as **HTTPS** URLs, so an SSH key alone is not sufficient — the simplest route is:

```sh
gh auth login          # choose HTTPS for the git protocol
gh auth setup-git      # writes the credential helper; a separate step, easily missed
```

## Publishing (maintainers)

With [LocalRegistry.jl](https://github.com/GunnarFarneback/LocalRegistry.jl), from the
package's own checkout, after bumping `version` and pushing the commit:

```julia
using LocalRegistry
register("/path/to/Package.jl"; registry = "SlateRegistry", push = true)
```

Two things to remember: push the package commit **before** registering (the registry records a
git tree SHA that has to be reachable), and register from a clean working tree — `register`
refuses a dirty one, so use a fresh clone if your checkout has work in progress.
