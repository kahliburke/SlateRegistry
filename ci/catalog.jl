# ── Catalog builder ───────────────────────────────────────────────────────────
# Turns this registry into `catalog.json`: the data behind Slate's Extensions gallery.
#
# The registry itself stays pure Pkg metadata — names, versions, repo URLs. Presentation lives
# here, assembled from three layers, ALL of them optional:
#
#   1. harvested — from the registry (name, uuid, version, repo, subdir) and, for a reachable
#      repo, its README blurb and Project.toml. Zero work for the package author: a package that
#      does nothing at all still gets a real listing.
#   2. authored  — an optional `SlateExtension.toml` at the package root (or subdir), shipped by
#      the author alongside their code. Every key optional; fill in one or ten.
#   3. curated   — an optional `catalog/<Name>.toml` in THIS repo, written by the registry
#      maintainer. Lets a bare package be made presentable, and organises the shelf.
#
# Later layers win per FIELD, so a curator note doesn't erase an author's screenshots. Every
# resolved field records where it came from (`sources`), which is what lets the gallery show how
# complete a listing is — and tells the maintainer where effort is worth spending.
#
# Versions come from the registry and are authoritative. Prose and images are harvested from the
# repo's DEFAULT BRANCH, not from the registered tag: a description fix shouldn't need a release.
# The two can therefore disagree, and that is intended.
#
# PRIVATE REPOSITORIES. This registry is public and most packages it points at are not. Harvesting
# runs with whatever credentials the caller has, so it CAN read private prose — and `catalog.json`
# is published publicly. Disclosure is therefore fail-closed: for a repo that is not anonymously
# readable, nothing harvested from its contents is published. Such an entry carries only what this
# public registry already states (name, version, repo URL) plus whatever a curator overlay
# explicitly writes. Set `publish_private_prose = true` in an overlay to opt one package in.
#
# stdlib only (TOML, Dates) and `git` on PATH — this runs in CI with no package installs.

module Catalog

using TOML, Dates, SHA, Downloads

# ── tiny JSON writer ──────────────────────────────────────────────────────────
# The output is plain data (strings, numbers, bools, vectors, dicts), so a ~25-line encoder beats
# taking a dependency. Escaping follows RFC 8259, plus `<` so the file stays safe to inline in HTML.
json(io::IO, ::Nothing) = print(io, "null")
json(io::IO, b::Bool)   = print(io, b ? "true" : "false")
json(io::IO, n::Real)   = print(io, isfinite(n) ? string(n) : "null")
function json(io::IO, s::AbstractString)
    print(io, '"')
    for c in s
        if     c == '"';  print(io, "\\\"")
        elseif c == '\\'; print(io, "\\\\")
        elseif c == '\n'; print(io, "\\n")
        elseif c == '\r'; print(io, "\\r")
        elseif c == '\t'; print(io, "\\t")
        elseif c == '<';  print(io, "\\u003c")
        elseif c < ' ';   print(io, "\\u", lpad(string(UInt32(c); base = 16), 4, '0'))
        else              print(io, c)
        end
    end
    print(io, '"')
end
function json(io::IO, v::AbstractVector)
    print(io, '[')
    for (i, x) in enumerate(v); i > 1 && print(io, ','); json(io, x); end
    print(io, ']')
end
function json(io::IO, d::AbstractDict)
    print(io, '{')
    for (i, k) in enumerate(sort!(collect(keys(d)); by = string))
        i > 1 && print(io, ',')
        json(io, string(k)); print(io, ':'); json(io, d[k])
    end
    print(io, '}')
end
json(x) = sprint(json, x)

# ── shelling out ──────────────────────────────────────────────────────────────
"Run `cmd`, returning `(ok, stdout)`. Never throws — a failure is data, not an exception, because
every remote here is allowed to be unreachable."
function run_capture(cmd::Cmd; timeout::Int = 120)
    out = IOBuffer()
    try
        p = run(pipeline(ignorestatus(cmd); stdout = out, stderr = devnull); wait = false)
        t = Timer(_ -> (process_running(p) && kill(p)), timeout)
        wait(p); close(t)
        return (success(p), String(take!(out)))
    catch
        return (false, String(take!(out)))
    end
end

# ── registry side ─────────────────────────────────────────────────────────────
"""
    registry_entries(regdir) -> Vector{Dict}

Every package this registry knows, with the facts the registry itself is authoritative for:
`name`, `uuid`, `version` (the highest registered), `repo`, `subdir`, and `julia`/`deps` compat
from the newest version's entries. This is layer 1 and it can never fail — it's local TOML.
"""
function registry_entries(regdir::AbstractString)
    reg = TOML.parsefile(joinpath(regdir, "Registry.toml"))
    out = Dict{String,Any}[]
    for (uuid, info) in get(reg, "packages", Dict{String,Any}())
        pdir = joinpath(regdir, info["path"])
        pkg  = TOML.parsefile(joinpath(pdir, "Package.toml"))
        vers = isfile(joinpath(pdir, "Versions.toml")) ? TOML.parsefile(joinpath(pdir, "Versions.toml")) : Dict{String,Any}()
        latest = isempty(vers) ? "" : string(maximum(VersionNumber.(keys(vers))))
        e = Dict{String,Any}(
            "name"    => get(pkg, "name", info["name"]),
            "uuid"    => string(uuid),
            "version" => latest,
            "repo"    => rstrip(String(get(pkg, "repo", "")), '/'),
            "subdir"  => String(get(pkg, "subdir", "")),
            "versions" => sort!(string.(VersionNumber.(collect(keys(vers))))),
        )
        e["julia"] = compat_julia(pdir, latest)
        push!(out, e)
    end
    sort!(out; by = e -> lowercase(e["name"]))
    return out
end

"The julia version bound recorded for `version` in `Compat.toml`, or `\"\"`. Compat.toml keys are
version RANGES (`\"0.1-0.2\"`), so match the range that covers `version` — newest range wins."
function compat_julia(pdir::AbstractString, version::AbstractString)
    f = joinpath(pdir, "Compat.toml")
    (isfile(f) && !isempty(version)) || return ""
    v = VersionNumber(version)
    best = ""
    for (range, entries) in TOML.parsefile(f)
        covers(range, v) || continue
        j = get(entries, "julia", nothing)
        j === nothing && continue
        best = j isa AbstractVector ? join(string.(j), ", ") : string(j)
    end
    return best
end

"""
    covers(range, v) -> Bool

Does a registry `Compat.toml` range key cover version `v`? The keys are compressed version
PREFIXES, not full semver specs: `\"0.1.1\"` (exactly that patch line), `\"0.1-0.2\"` (a span),
`\"0\"` (everything in 0.x). A prefix is inclusive of everything beneath it, so `\"0.2\"` covers
0.2.9.
"""
function covers(range::AbstractString, v::VersionNumber)
    if occursin('-', range)
        lo, hi = split(range, '-'; limit = 2)
        return floor_of(lo) <= v && v < ceil_of(hi)
    end
    return floor_of(range) <= v && v < ceil_of(range)
end

"The lowest version a prefix admits: `\"0.2\"` → 0.2.0."
floor_of(p::AbstractString) = VersionNumber(join(vcat(split(p, '.'), fill("0", max(0, 3 - count(==('.'), p) - 1))), '.'))
"The exclusive upper bound a prefix admits: `\"0.2\"` → 0.3.0, so 0.2.9 is inside."
function ceil_of(p::AbstractString)
    parts = split(p, '.')
    return VersionNumber(join(vcat(parts[1:end-1], string(parse(Int, parts[end]) + 1)), '.'))
end

# ── repo harvest ──────────────────────────────────────────────────────────────
"Is `repo` readable WITHOUT credentials? Determines whether harvested prose may be published: this
registry is public, so anything not anonymously readable is treated as private."
function anonymously_readable(repo::AbstractString)
    isempty(repo) && return false
    env = copy(ENV)
    env["GIT_TERMINAL_PROMPT"] = "0"      # never block on a username prompt
    env["GIT_ASKPASS"] = "true"           # ...or a password one
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    # The SYSTEM config matters too, and forgetting it makes this probe LIE on a developer machine:
    # macOS ships an osxkeychain credential helper there, so a private repo the developer has access
    # to answers as public locally while CI correctly sees it as private. `-c credential.helper=`
    # clears any helper that survives regardless of which config file declared it.
    env["GIT_CONFIG_SYSTEM"] = "/dev/null"
    cmd = `git -c credential.helper= -c credential.useHttpPath=false ls-remote --exit-code -h $repo`
    ok, _ = run_capture(setenv(cmd, env); timeout = 45)
    return ok
end

# Clones are cached per repo for the lifetime of a build: several packages can live in ONE
# monorepo (`subdir`), and cloning it once per package is the difference between one fetch and
# several of the largest repo in the registry. `nothing` marks a repo we failed to clone, so a
# private repo isn't retried for each package inside it.
const _CLONES = Dict{String,Union{String,Nothing}}()
# Scoped to ONE build (created on first use, cleaned up with the process): caching in a stable
# tempdir path would make a rebuild silently reuse yesterday's checkout.
const _CLONE_ROOT = Ref{String}("")
clone_root() = isempty(_CLONE_ROOT[]) ? (_CLONE_ROOT[] = mktempdir(; prefix = "slate-catalog-")) : _CLONE_ROOT[]

"The on-disk cache key for a repo. Digests the WHOLE url: every GitHub remote shares a long common
prefix, so any prefix-derived key collides and silently serves one repo's content for all of them."
clone_key(repo::AbstractString) = bytes2hex(sha1(String(repo)))

"Shallow-clone `repo` once per build, returning the checkout path (or `nothing` if unreachable)."
function clone_cached(repo::AbstractString)
    get!(_CLONES, String(repo)) do
        dest = joinpath(clone_root(), clone_key(repo))
        ok, _ = run_capture(`git clone --depth 1 --quiet --filter=blob:none $repo $dest`; timeout = 300)
        ok || return nothing
        return dest
    end
end

"""
    harvest(repo, subdir; dest) -> Dict

Shallow-clone `repo`'s default branch and read what a listing can be built from: an optional
`SlateExtension.toml`, the `README.md` blurb, and `Project.toml`. Returns `Dict()` when the repo
can't be cloned with the credentials available — an unreachable repo degrades to a registry-only
listing rather than failing the build.
"""
function harvest(repo::AbstractString, subdir::AbstractString = "")
    isempty(repo) && return Dict{String,Any}()
    src = clone_cached(repo)
    src === nothing && return Dict{String,Any}()
    let
        root = isempty(subdir) ? src : joinpath(src, subdir)
        isdir(root) || return Dict{String,Any}()
        out = Dict{String,Any}()
        # Author layer, if they shipped one.
        for candidate in ("SlateExtension.toml", joinpath("docs", "SlateExtension.toml"))
            f = joinpath(root, candidate)
            if isfile(f)
                try; out["authored"] = TOML.parsefile(f); catch; end
                break
            end
        end
        # Harvested prose + declared deps.
        rd = joinpath(root, "README.md")
        isfile(rd) && (out["readme"] = readme_blurb(read(rd, String)))
        pj = joinpath(root, "Project.toml")
        name = ""
        if isfile(pj)
            try
                p = TOML.parsefile(pj)
                name = String(get(p, "name", ""))
                haskey(p, "description") && (out["description"] = String(p["description"]))
                out["deps"] = sort!(collect(keys(get(p, "deps", Dict{String,Any}()))))
            catch; end
        end
        # Several packages ship no README but do document their module. That docstring is written
        # for exactly this audience, so it's the next-best blurb and costs the author nothing.
        if isempty(get(out, "readme", "")) && !isempty(name)
            mf = joinpath(root, "src", name * ".jl")
            isfile(mf) && (out["readme"] = module_docstring_blurb(read(mf, String), name))
        end
        return out
    end
end

"""
    readme_blurb(md; limit = 400) -> String

The first real paragraph of a README — what a card shows when the author wrote no tagline. Drops
the leading `# Title`, badge-only lines, HTML blocks and blockquote callouts, then takes the first
prose paragraph and flattens it to one line. Returns `""` if there's nothing prose-like.
"""
function readme_blurb(md::AbstractString; limit::Int = 400)
    para = String[]
    fenced = false
    for raw in split(md, '\n')
        line = strip(raw)
        # A fenced block before the prose is skipped WHOLE (an install snippet up top is common);
        # one after it ends the paragraph.
        if startswith(line, "```")
            isempty(para) || break
            fenced = !fenced
            continue
        end
        fenced && continue
        if isempty(line)
            isempty(para) && continue
            break                                  # end of the first paragraph
        end
        startswith(line, '#') && continue          # heading
        startswith(line, '>') && continue          # callout
        startswith(line, '<') && continue          # raw HTML / <img> banner
        # A badge-only line: nothing but images/links.
        isempty(strip(replace(line, r"\[?!\[[^\]]*\]\([^)]*\)\]?(\([^)]*\))?" => ""))) && continue
        push!(para, line)
    end
    txt = join(para, " ")
    # Flatten inline markdown to plain text: links to their text, emphasis and code marks away.
    txt = replace(txt, r"\[([^\]]*)\]\([^)]*\)" => s"\1")
    txt = replace(txt, r"[*_`]" => "")
    txt = strip(replace(txt, r"\s+" => " "))
    return length(txt) <= limit ? String(txt) : String(rstrip(txt[1:prevind(txt, limit)])) * "…"
end

"""
    module_docstring_blurb(src, name; limit = 400) -> String

The first prose paragraph of the docstring attached to `module <name>` in `src`. Julia docstrings
open with an indented signature block (`    StarRating`), which is dropped; the remainder is
flattened like a README blurb. Returns `""` when the module carries no docstring.
"""
function module_docstring_blurb(src::AbstractString, name::AbstractString; limit::Int = 400)
    m = match(Regex("\"\"\"(.*?)\"\"\"\\s*module\\s+\\Q$name\\E\\b", "s"), src)
    m === nothing && return ""
    body = String(m[1])
    # Drop the leading indented signature lines, then reuse the README flattening.
    lines = collect(split(body, '\n'))
    i = findfirst(l -> !isempty(strip(l)) && !startswith(l, "    ") && !startswith(l, "\t"), lines)
    i === nothing && return ""
    return readme_blurb(join(lines[i:end], '\n'); limit)
end

# ── merge ─────────────────────────────────────────────────────────────────────
# Presentation fields, in the order a card reads them. Anything not listed here is ignored, so an
# author or curator can't inject arbitrary keys into the published payload.
#
# `example` is a repo-relative path to a notebook that demonstrates the package (most extensions
# already ship one). It is the cheapest possible route to a screenshot: the shot job installs the
# extension, runs that notebook headless, and captures its output — so an author gets card imagery
# from a file they already maintain, and it can never go stale against the code.
const STRING_FIELDS = ("title", "tagline", "description", "icon", "video", "docs", "snippet", "example")
const LIST_FIELDS   = ("categories", "screenshots", "provides", "keywords")

"Rewrite a layer's shorthands into the canonical field names, so precedence between layers compares
like with like. Currently just `category` (singular) → a one-element `categories`."
function normalise_layer(layer::AbstractDict)
    d = Dict{String,Any}(layer)
    v = get(d, "category", nothing)
    if v !== nothing && !haskey(d, "categories") && !isempty(string(v))
        d["categories"] = [string(v)]
    end
    delete!(d, "category")
    return d
end

"""
    merge_entry(reg, harvested, curated; public) -> Dict

Resolve one catalog entry from the three layers. Registry facts are never overridden. Presentation
fields take the LAST layer that supplies them (harvest → author → curator), recording the winner in
`sources` so the gallery can show how complete a listing is.

`public = false` (a repo that isn't anonymously readable) suppresses everything harvested from that
repo's contents, unless a curator overlay sets `publish_private_prose = true`.
"""
function merge_entry(reg::AbstractDict, harvested::AbstractDict, curated::AbstractDict; public::Bool)
    e = Dict{String,Any}(reg)
    sources = Dict{String,Any}()
    disclose = public || Bool(get(curated, "publish_private_prose", false))

    authored = disclose ? Dict{String,Any}(get(harvested, "authored", Dict{String,Any}())) : Dict{String,Any}()
    # Normalise the `category` singular shorthand INSIDE each layer, before precedence is applied —
    # otherwise a curator's `category` would lose to an author's `categories` rather than override it.
    layers = ["author" => normalise_layer(authored), "curator" => normalise_layer(Dict{String,Any}(curated))]

    # Harvested prose is the weakest layer and only fills `description`.
    if disclose
        blurb = String(get(harvested, "description", get(harvested, "readme", "")))
        if !isempty(blurb); e["description"] = blurb; sources["description"] = "readme"; end
        deps = get(harvested, "deps", nothing)
        deps === nothing || (e["deps"] = deps)
    end

    for f in STRING_FIELDS, (who, layer) in layers
        v = get(layer, f, nothing)
        (v === nothing || isempty(string(v))) && continue
        e[f] = string(v); sources[f] = who
    end
    for f in LIST_FIELDS, (who, layer) in layers
        v = get(layer, f, nothing)
        (v isa AbstractVector && !isempty(v)) || continue
        e[f] = string.(v); sources[f] = who
    end

    e["title"]      = get(e, "title", reg["name"])
    e["visibility"] = public ? "public" : "private"
    e["sources"]    = sources
    # How much of a listing exists — drives the gallery's "add a description" nudge and tells the
    # maintainer where a curator overlay would pay off.
    e["tier"] = haskey(sources, "tagline") || haskey(sources, "screenshots") ? "rich" :
                haskey(e, "description")                                     ? "described" : "bare"
    # Screenshots given as repo-relative paths resolve against the repo's raw content.
    e["screenshots"] = [absolutise(s, reg) for s in get(e, "screenshots", String[])]
    haskey(e, "icon") && (e["icon"] = length(e["icon"]) <= 4 ? e["icon"] : absolutise(e["icon"], reg))
    return e
end

# ── asset mirroring ───────────────────────────────────────────────────────────
# Card imagery is MIRRORED into the published artifact rather than hot-linked. Authors still point
# wherever they like — their own repo, a CDN — and this copies what it can reach, rewriting the
# entry to the local path and falling back to the original URL when it can't.
#
# Worth the step for three reasons: the gallery then loads everything from ONE origin instead of
# fanning out to raw.githubusercontent (which is rate-limited and uncached); a repo that is renamed
# or made private stops silently 404-ing every card; and the artifact is rebuilt fresh in CI and
# never committed, so none of this grows the registry.

"Largest asset worth mirroring. Above this the artifact stops being cheap to publish, and the entry
keeps hot-linking instead — a card that loads slowly beats a Pages deploy that times out."
const MAX_ASSET_BYTES = 8 * 1024 * 1024

"""
    mirror_asset!(url, name, outdir) -> String

Download `url` into `outdir/assets/<name>/` and return the artifact-relative URL, or the original
`url` unchanged if it can't be fetched or is too large. Never throws: a missing screenshot degrades
a card, it doesn't fail the build.
"""
function mirror_asset!(url::AbstractString, name::AbstractString, outdir::AbstractString)
    startswith(url, "http") || return String(url)
    ext = let e = last(splitext(first(split(basename(url), '?'))))
        (isempty(e) || length(e) > 6) ? "" : e
    end
    fname = bytes2hex(sha1(String(url)))[1:12] * ext
    rel = joinpath("assets", String(name), fname)
    dest = joinpath(outdir, rel)
    isfile(dest) && return rel
    try
        mkpath(dirname(dest))
        Downloads.download(String(url), dest; timeout = 60)
        sz = filesize(dest)
        if sz == 0 || sz > MAX_ASSET_BYTES
            rm(dest; force = true)
            @info "catalog: not mirroring $url ($(sz) bytes)"
            return String(url)
        end
        return rel
    catch e
        @info "catalog: could not mirror $url" error = first(sprint(showerror, e), 120)
        rm(dest; force = true)
        return String(url)
    end
end

"Mirror every image/video an entry references, rewriting it in place. `outdir` is the artifact root."
function mirror_entry_assets!(e::AbstractDict, outdir::AbstractString)
    name = String(e["name"])
    if haskey(e, "screenshots")
        e["screenshots"] = [mirror_asset!(s, name, outdir) for s in e["screenshots"]]
    end
    for k in ("video", "icon")
        v = get(e, k, "")
        # An emoji icon is not a URL — leave short strings alone.
        (v isa AbstractString && startswith(v, "http")) || continue
        e[k] = mirror_asset!(v, name, outdir)
    end
    return e
end

"Resolve a repo-relative asset path to a fetchable URL. Absolute URLs pass through; a GitHub repo
gets its raw-content host, anything else is left relative for the client to resolve against `repo`."
function absolutise(path::AbstractString, reg::AbstractDict)
    (startswith(path, "http://") || startswith(path, "https://")) && return String(path)
    repo = String(get(reg, "repo", "")); isempty(repo) && return String(path)
    m = match(r"github\.com[:/]([^/]+)/(.+?)(?:\.git)?$", repo)
    m === nothing && return String(path)
    sub = String(get(reg, "subdir", ""))
    rel = isempty(sub) ? String(path) : "$sub/$path"
    return "https://raw.githubusercontent.com/$(m[1])/$(m[2])/HEAD/$rel"
end

# ── build ─────────────────────────────────────────────────────────────────────
"""
    build(regdir = "."; overlays = "catalog", offline = false) -> Dict

Assemble the full catalog. `offline` skips every network call, producing the registry-only listing
(what the build degrades to when a repo is unreachable) — used by the tests.
"""
function build(regdir::AbstractString = "."; overlays::AbstractString = "catalog", offline::Bool = false,
               mirror_to::Union{Nothing,AbstractString} = nothing)
    entries = Dict{String,Any}[]
    for reg in registry_entries(regdir)
        name = reg["name"]
        ofile = joinpath(regdir, overlays, name * ".toml")
        curated = isfile(ofile) ? TOML.parsefile(ofile) : Dict{String,Any}()
        if Bool(get(curated, "hidden", false))
            @info "catalog: skipping $name (hidden by overlay)"
            continue
        end
        public = offline ? false : anonymously_readable(reg["repo"])
        harvested = offline ? Dict{String,Any}() : harvest(reg["repo"], reg["subdir"])
        e = merge_entry(reg, harvested, curated; public)
        mirror_to === nothing || mirror_entry_assets!(e, mirror_to)
        @info "catalog: $name" version=e["version"] tier=e["tier"] visibility=e["visibility"]
        push!(entries, e)
    end
    return Dict{String,Any}(
        "schema"   => 1,
        "registry" => TOML.parsefile(joinpath(regdir, "Registry.toml"))["name"],
        "url"      => TOML.parsefile(joinpath(regdir, "Registry.toml"))["repo"],
        "generated" => string(now(UTC)) * "Z",
        "entries"  => entries,
    )
end

"""
    write_catalog(out; regdir=".", mirror=true, kw...) -> String

Write `build(...)` to `out`. With `mirror=true` (the default) card imagery is copied into an
`assets/` tree NEXT TO `out` and the entries are rewritten to point at it, so the whole artifact —
catalog and pictures — deploys and is served from one place.
"""
function write_catalog(out::AbstractString; regdir::AbstractString = ".", mirror::Bool = true,
                       site::Bool = true, kw...)
    outdir = dirname(out)
    mkpath(outdir)
    cat = build(regdir; mirror_to = (mirror ? outdir : nothing), kw...)
    open(out, "w") do io; json(io, cat); end
    site && copy_site!(regdir, outdir)
    return out
end

"""
    copy_site!(regdir, outdir)

Copy the static browse page (`ci/site/`) in beside the catalog. It reads `catalog.json` from its own
origin at run time, so the page is deployed as-is and can never disagree with the notebook gallery —
both render the same document. Kept in the repo and copied at build time because the artifact
directory itself is generated and gitignored.
"""
function copy_site!(regdir::AbstractString, outdir::AbstractString)
    src = joinpath(regdir, "ci", "site")
    isdir(src) || return outdir
    for f in readdir(src)
        cp(joinpath(src, f), joinpath(outdir, f); force = true)
    end
    return outdir
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    regdir = get(ARGS, 1, ".")
    out    = get(ARGS, 2, joinpath(regdir, "docs", "catalog.json"))
    Catalog.write_catalog(out; regdir)
    @info "catalog: wrote $out ($(filesize(out)) bytes)"
end
