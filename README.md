# SlateRegistry

A Julia package registry for [Kaimon Slate](https://github.com/kahliburke/KaimonSlate.jl)
extension packages that aren't in the General registry.

`KaimonSlate` and `SlateExtensionsBase` are **in General** — you do not need this registry to
install Slate or to write an extension against the SDK. This registry carries only the extension
packages themselves.

This repository is public and contains only package metadata — names, versions and repository
URLs. Most of the packages it points at are private; installing those requires access to their
repositories.

## Use

Add the registry once per machine, from the Pkg REPL (press `]`):

```julia-repl
pkg> registry add https://github.com/kahliburke/SlateRegistry
```

It sits alongside General rather than replacing it — Pkg searches every installed registry, so
ordinary packages keep resolving as usual. After that, an extension installs like any other
package:

```julia-repl
pkg> add SlateAssess          # into your notebook's environment
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
| `BonitoSlate` | [KaimonSlate.jl](https://github.com/kahliburke/KaimonSlate.jl), `examples/extensions/BonitoSlate` | public |
| `SlateAFM` | KaimonSlate.jl, `examples/extensions/SlateAFM` | public |
| `StarRating` | KaimonSlate.jl, `examples/extensions/StarRating` | public |
| `CesiumSlate` | CesiumSlate.jl | private |
| `GiacSlate` | GiacSlate.jl | private |
| `GlobeSlate` | GlobeSlate.jl | private |
| `SlateAssess` | SlateAssess.jl | private |
| `SlateBench` | SlateBench.jl | private |
| `SlatePlotly` | SlatePlotly.jl | private |

Installing a private package needs git credentials for GitHub. The registry records repository
locations as **HTTPS** URLs, so an SSH key alone is not sufficient — the simplest route is:

```sh
gh auth login          # choose HTTPS for the git protocol
gh auth setup-git      # writes the credential helper; a separate step, easily missed
```

## The Extensions gallery

Slate's Extensions gallery (⌘K → "Extensions", or ☰ → Extensions) browses this registry and
installs from it. Its data is `catalog.json`, built from the registry by `ci/catalog.jl` and
published to GitHub Pages:

```
https://kahliburke.github.io/SlateRegistry/catalog.json
```

The registry itself stays pure package metadata — no descriptions, no images — so a depot that adds
it doesn't pay for content it will never look at. **No binary asset is ever committed here:** the
build fetches each package's imagery, writes it into `docs/` alongside `catalog.json`, and CI
deploys that straight to Pages. `docs/` is gitignored, so the repository stays text.

### Getting listed

Register the package. That is the whole requirement.

A package with no extra files still gets a real listing: its name, version, repository and compat
come from the registry, and its description is harvested from the repository's `README.md`, its
`Project.toml` `description`, or its module docstring — whichever it has. All nine packages
currently registered here produce a usable card with no author-side changes.

### Enriching a listing

Add a `SlateExtension.toml` at the package root (or, for a package in a monorepo subdirectory, at
that subdirectory's root). **Every key is optional** — add one, or all of them, whenever you like:

```toml
title    = "Star Rating"
tagline  = "A ★ rating control for @bind"
icon     = "★"                         # an emoji, or a repo-relative image path / URL
categories  = ["controls", "examples"]
screenshots = ["docs/stars.png"]       # repo-relative paths resolve against your repo
video    = "https://…"
docs     = "https://…"
example  = "notebooks/stars_demo.jl"   # a notebook that demonstrates the package
snippet  = """
using StarRating
@bind rating Stars(; max = 5)
"""
```

`snippet` is offered as a starter cell right after install, which is what turns an installed
package into a working one — installing a package doesn't `using` it.

`example` points at a demo notebook you already maintain. The gallery links to it, and
`docs/generate_extension_assets.mjs` in the KaimonSlate repo runs it headless and photographs the
page — so a package gets *some* imagery from code that can't go stale. It is deliberately unclever;
if you want a good picture, make one.

### Where to host images and video

**Host them; don't commit them.**

```toml
screenshots = ["https://you.github.io/Pkg.jl/shot.png"]                        # Pages
video       = "https://github.com/you/Pkg.jl/releases/download/media/demo.mp4" # release asset
```

A repo-relative path (`docs/shot.png`) also works and resolves against your repository's raw content
at its default branch — but it means committing binaries, and screenshots get replaced often enough
that they bloat history. Any absolute URL is better: GitHub Pages, a release asset, a CDN.

Either way the catalog build **mirrors** what it can fetch into the published artifact and rewrites
the entry to that copy, so the gallery loads every image from one origin. Your host only has to be
reachable when the catalog is BUILT, not every time someone opens the gallery — which also means a
later rename or deletion doesn't retroactively break the cards. Anything unreachable, or larger than
8 MB, keeps its original URL and is hot-linked instead.

`examples/extensions/StarRating` in the KaimonSlate repository is the worked example: the smallest
complete extension, with a fully populated `SlateExtension.toml`.

### How a listing is assembled

Three layers, all optional, later ones winning per FIELD:

| layer | source | who writes it |
|---|---|---|
| harvested | registry facts; README / `Project.toml` / module docstring | nobody |
| authored | `SlateExtension.toml` in the package | the package author |
| curated | `catalog/<Name>.toml` in this repo | the registry maintainer |

Versions come from the registry and are authoritative. Prose and images are read from each
repository's **default branch**, so correcting a description doesn't need a release — the two are
allowed to disagree.

Every resolved field records which layer it came from, which is how the gallery knows whether a
listing is bare, described, or rich.

### Curating

`catalog/<Name>.toml` overrides any presentation field for a package, using the same keys. Use it
to categorise the shelf, or to give a bare package a usable description without waiting on its
author. Two extra keys are maintainer-only:

- `hidden = true` — omit the package from the catalog entirely (it stays installable by name).
- `publish_private_prose = true` — see below.

### Private repositories

`catalog.json` is published publicly. Harvesting runs with whatever credentials CI has, so it *can*
read a private repository's prose — which is why disclosure is fail-closed: for a repository that
isn't anonymously readable, nothing read out of it is published. Such an entry carries only what
this public registry already states, plus whatever a curator overlay explicitly writes. Set
`publish_private_prose = true` in an overlay to opt a single package in.

### Building it locally

```sh
julia ci/runtests.jl                       # the builder's own tests — no network
julia ci/catalog.jl . docs/catalog.json    # the real build; clones each repo shallowly
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
