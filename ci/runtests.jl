# Tests for the catalog builder. stdlib only; no network — `build(offline = true)` exercises the
# degraded path, and the merge/blurb logic is pure and tested directly.
using Test
include("catalog.jl")
using .Catalog: merge_entry, readme_blurb, covers, absolutise, json, registry_entries, build, clone_key

const REGDIR = normpath(joinpath(@__DIR__, ".."))

@testset "catalog" begin

@testset "readme blurb" begin
    # A real README shape: title, badge row, then prose. Only the prose survives, flattened.
    md = """
    # GlobeSlate

    [![CI](https://img.shields.io/badge/ci-green.svg)](https://example.com)

    A 3-D **globe** for [Slate](https://example.com) notebooks,
    with tiled imagery.

    ## Install
    """
    @test readme_blurb(md) == "A 3-D globe for Slate notebooks, with tiled imagery."
    # Nothing prose-like at all → empty, not garbage. Covers a README that is only a banner.
    @test readme_blurb("# Title\n\n<img src=\"x.png\">\n") == ""
    @test readme_blurb("") == ""
    # A fenced block before any prose is skipped; one after it ends the paragraph.
    @test readme_blurb("# T\n\n```julia\nx = 1\n```\n\nReal text here.\n") == "Real text here."
    # Long prose is truncated on a word boundary with an ellipsis.
    long = readme_blurb("# T\n\n" * repeat("word ", 200); limit = 40)
    @test endswith(long, "…") && length(long) <= 41
end

@testset "module docstring blurb" begin
    # The real StarRating shape: an indented signature block, then prose. Several registered
    # packages ship no README at all, so this is what keeps them off the `bare` tier.
    src = """
    \"\"\"
        StarRating

    A sample Slate extension: a typed `@bind` star-rating control, built against the lean
    `SlateExtensionsBase` SDK.

    More detail follows here.
    \"\"\"
    module StarRating

    end
    """
    @test Catalog.module_docstring_blurb(src, "StarRating") ==
          "A sample Slate extension: a typed @bind star-rating control, built against the lean SlateExtensionsBase SDK."
    @test Catalog.module_docstring_blurb("module Bare\nend", "Bare") == ""
    # Must not match a docstring belonging to some OTHER module in the same file.
    @test Catalog.module_docstring_blurb("\"\"\"\nOther thing.\n\"\"\"\nmodule Other\nend\n", "Wanted") == ""
end

@testset "compat range coverage" begin
    @test covers("0.1.1", v"0.1.1")
    @test !covers("0.1.1", v"0.1.2")
    @test covers("0.2", v"0.2.9")          # a prefix is inclusive of everything beneath it
    @test !covers("0.2", v"0.3.0")
    @test covers("0.1-0.3", v"0.2.5")
    @test !covers("0.1-0.3", v"0.4.0")
    @test covers("1", v"1.9.9") && !covers("1", v"2.0.0")
end

@testset "asset URLs" begin
    reg = Dict("repo" => "https://github.com/o/R.jl.git", "subdir" => "")
    @test absolutise("docs/a.png", reg) == "https://raw.githubusercontent.com/o/R.jl/HEAD/docs/a.png"
    # A monorepo subdir prefixes the path — the asset lives under the package, not the repo root.
    sub = Dict("repo" => "https://github.com/o/R.jl.git", "subdir" => "examples/E")
    @test absolutise("a.png", sub) == "https://raw.githubusercontent.com/o/R.jl/HEAD/examples/E/a.png"
    @test absolutise("https://cdn/x.png", reg) == "https://cdn/x.png"   # absolute passes through
    @test absolutise("a.png", Dict("repo" => "https://gitlab.com/o/R.jl")) == "a.png"  # non-GitHub: left relative
end

@testset "clone cache keys" begin
    # Every GitHub remote shares the `https://github.com/kahliburke/` prefix, so a key derived from
    # a PREFIX of the url collides and one repo's content is served for all of them — which shows up
    # as several packages sharing a description. Keys must differ across the whole url.
    urls = ["https://github.com/kahliburke/CesiumSlate.jl.git",
            "https://github.com/kahliburke/GlobeSlate.jl.git",
            "https://github.com/kahliburke/KaimonSlate.jl.git"]
    @test length(unique(clone_key.(urls))) == length(urls)
    @test clone_key(urls[1]) == clone_key(urls[1])          # stable across calls
end

@testset "asset mirroring" begin
    # Unreachable or non-http references are returned unchanged, so a broken screenshot degrades one
    # card instead of failing the build. (A reachable fetch is exercised by the real build, not here —
    # these tests never touch the network.)
    out = mktempdir()
    @test Catalog.mirror_asset!("docs/local.png", "P", out) == "docs/local.png"   # not a URL
    @test Catalog.mirror_asset!("http://127.0.0.1:9/x.png", "P", out) == "http://127.0.0.1:9/x.png"

    # Mirroring rewrites in place and leaves an emoji icon alone — it isn't a URL.
    e = Dict{String,Any}("name" => "P", "icon" => "★",
                         "screenshots" => ["http://127.0.0.1:9/a.png"],
                         "video" => "http://127.0.0.1:9/v.webm")
    Catalog.mirror_entry_assets!(e, out)
    @test e["icon"] == "★"
    @test e["screenshots"] == ["http://127.0.0.1:9/a.png"]     # unreachable → hot-link preserved
    @test e["video"] == "http://127.0.0.1:9/v.webm"

    # Cache keys are per-URL, so two assets in one package can't overwrite each other.
    k1 = Catalog.clone_key("https://x/a.png"); k2 = Catalog.clone_key("https://x/b.png")
    @test k1 != k2
end

@testset "merge layers" begin
    reg = Dict{String,Any}("name" => "StarRating", "uuid" => "u", "version" => "0.1.1",
                           "repo" => "https://github.com/o/R.jl", "subdir" => "")

    # Tier 0: registry only. A package that ships NOTHING still produces a usable listing — this is
    # the low-barrier guarantee, so it is asserted directly.
    bare = merge_entry(reg, Dict{String,Any}(), Dict{String,Any}(); public = true)
    @test bare["name"] == "StarRating" && bare["version"] == "0.1.1"
    @test bare["title"] == "StarRating"        # title falls back to the package name
    @test bare["tier"] == "bare" && isempty(bare["sources"])

    # Tier 1: a README exists → it becomes the description, attributed to the harvest.
    described = merge_entry(reg, Dict{String,Any}("readme" => "Stars for @bind."), Dict{String,Any}(); public = true)
    @test described["description"] == "Stars for @bind." && described["sources"]["description"] == "readme"
    @test described["tier"] == "described"

    # Tier 2: the author's own file wins over the harvest, per field.
    authored = merge_entry(reg,
        Dict{String,Any}("readme" => "Stars for @bind.",
                         "authored" => Dict("tagline" => "A ★ rating control",
                                            "categories" => ["controls"],
                                            "screenshots" => ["docs/s.png"])),
        Dict{String,Any}(); public = true)
    @test authored["tagline"] == "A ★ rating control" && authored["sources"]["tagline"] == "author"
    @test authored["description"] == "Stars for @bind."          # untouched by the author layer
    @test authored["tier"] == "rich"
    @test authored["screenshots"] == ["https://raw.githubusercontent.com/o/R.jl/HEAD/docs/s.png"]

    # Tier 3: the curator overrides ONE field; the author's other fields survive.
    curated = merge_entry(reg,
        Dict{String,Any}("authored" => Dict("tagline" => "A ★ rating control", "categories" => ["controls"])),
        Dict{String,Any}("tagline" => "The worked example every extension starts from",
                         "category" => "examples"); public = true)
    @test curated["sources"]["tagline"] == "curator"
    @test curated["categories"] == ["examples"]         # singular `category` is shorthand
    @test !haskey(curated, "category")

    # Unknown keys in either layer are dropped — the published payload has a fixed shape.
    @test !haskey(merge_entry(reg, Dict{String,Any}(), Dict{String,Any}("evil" => "x"); public = true), "evil")
end

@testset "private repos are fail-closed" begin
    reg = Dict{String,Any}("name" => "P", "uuid" => "u", "version" => "1.0.0",
                           "repo" => "https://github.com/o/P.jl", "subdir" => "")
    harvested = Dict{String,Any}("readme" => "Secret internal tool.",
                                 "authored" => Dict("tagline" => "Also secret"))
    # Not anonymously readable → nothing read out of the repo reaches the public catalog...
    closed = merge_entry(reg, harvested, Dict{String,Any}(); public = false)
    @test !haskey(closed, "description") && !haskey(closed, "tagline")
    @test closed["visibility"] == "private" && closed["tier"] == "bare"
    # ...but a curator overlay is the maintainer's own words, so it still publishes.
    noted = merge_entry(reg, harvested, Dict{String,Any}("tagline" => "Internal"); public = false)
    @test noted["tagline"] == "Internal" && !haskey(noted, "description")
    # ...and one package can be opted in explicitly.
    opted = merge_entry(reg, harvested, Dict{String,Any}("publish_private_prose" => true); public = false)
    @test opted["description"] == "Secret internal tool." && opted["tagline"] == "Also secret"
end

@testset "json encoding" begin
    @test json(Dict("a" => 1, "b" => [true, nothing])) == "{\"a\":1,\"b\":[true,null]}"
    # Escaping: quotes, newlines, and `<` (so the payload stays safe to inline in a page).
    @test json("he said \"hi\"\n<script>") == "\"he said \\\"hi\\\"\\n\\u003cscript>\""
    @test json(Dict("k" => "é")) == "{\"k\":\"é\"}"     # non-ASCII passes through as UTF-8
end

@testset "real registry, offline" begin
    # The degraded path over the ACTUAL registry: no network, so every entry is registry-only.
    # This is what the gallery falls back to when the published catalog can't be fetched.
    entries = registry_entries(REGDIR)
    @test length(entries) >= 9
    star = only(filter(e -> e["name"] == "StarRating", entries))
    @test star["subdir"] == "examples/extensions/StarRating"
    @test VersionNumber(star["version"]) >= v"0.1.1"
    @test !isempty(star["julia"])                       # compat harvested from Compat.toml

    cat = build(REGDIR; offline = true)
    @test cat["schema"] == 1 && cat["registry"] == "SlateRegistry"
    @test length(cat["entries"]) == length(entries)
    @test all(e -> !isempty(e["title"]) && haskey(e, "tier"), cat["entries"])
    @test isvalid(json(cat))                            # encodes without throwing
end

end
