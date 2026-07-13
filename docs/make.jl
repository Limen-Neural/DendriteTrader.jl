# SPDX-License-Identifier: MIT OR Apache-2.0

using Documenter
using DendriteTrader
using DendriteTrader.SizingModule
using DendriteTrader.Backtest

makedocs(
    sitename = "DendriteTrader.jl",
    modules = [DendriteTrader, DendriteTrader.SizingModule, DendriteTrader.Backtest],
    authors = "Raul Montoya Cardenas",
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://limen-neural.github.io/DendriteTrader.jl",
    ),
    pages = [
        "Home" => "index.md",
        "Modules" => [
            "Execution" => "execution.md",
            "Sizing" => "sizing.md",
            "Backtest" => "backtest.md",
        ],
    ],
    checkdocs = :exports,
    warnonly = [:missing_docs],
)

deploydocs(
    repo = "github.com/Limen-Neural/DendriteTrader.jl",
    push_preview = true,
)
