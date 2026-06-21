# DendriteTrader

Julia strategy, diagnostics, paper-trading, and control-plane tooling for neural trading systems.

DendriteTrader consumes neural trade signals, applies confidence gating, sizes positions with integrated Kelly/fractional-Kelly helpers, tracks paper positions, and exposes read-only market-data utilities. It is intentionally scoped as the Julia-side control-plane layer; deterministic low-latency execution loops belong in Rust services such as `corpus-ipc` and adjacent ledger infrastructure such as `metabolic-ledger`.

## Features

- **ZMQ SUB socket** — consumes JSON trade signals from Rust or other signal producers
- **Nanosecond latency tracking** — Unix-epoch timestamps aligned with Rust `timestamp_nanos`
- **Confidence gate** — only accepts signals above a configurable threshold
- **Integrated Kelly sizing** — `kelly_fraction`, `half_kelly`, `from_confidence`, and `size_position`
- **Paper position tracking** — updates in-memory positions for strategy/control-plane decisions
- **dYdX v4 market data** — read-only REST client for orderbook and oracle price queries

## Repository Boundary

DendriteTrader is for Julia-side strategy and control-plane responsibilities:

- Strategy-facing signal ingestion and diagnostics
- Confidence gating and position sizing
- Paper-trading state transitions
- Read-only market data helpers
- Human-readable experimentation and test coverage around neural confidence signals

DendriteTrader is **not** the deterministic HFT execution runtime. Latency-critical production execution, IPC loops, and venue-critical paths should remain in Rust services, including `corpus-ipc`.

**Ownership split with `metabolic-ledger`:**

| Repo | Owns |
|------|------|
| **DendriteTrader.jl** | `TradeSignal`, confidence gate, Kelly sizing proposals (`kelly_fraction`, `from_confidence`, `PositionSize`), dYdX v4 REST client, ZMQ SUB consumer — **signal → decision only** |
| **metabolic-ledger** | `GhostWallet`, buy/sell state transitions, ATP energy, `GhostTradeLog`, realized PnL, win/loss tracking — **persistent accounting** |

See the module docstring in `src/DendriteTrader.jl` for the explicit boundary declaration. Win-rate/PnL tracking belongs in `metabolic-ledger`.

Persistent portfolio/accounting boundaries should be handled by adjacent infrastructure such as `metabolic-ledger`.

## Ecosystem

DendriteTrader is designed to remain composable with the broader Julia finance ecosystem rather than hard-code a single asset class or venue. Packages such as `Miletus.jl` can model complex financial contracts, while `LimitOrderBook.jl` can support high-frequency limit order book simulations. DendriteTrader should focus on neural signal control-plane logic, paper-trading decisions, and sizing helpers that can be manually adapted to whichever instruments, contracts, books, or venues are used later.

## Architecture

```text
Julia strategy/control-plane        Rust infrastructure             Exchange / ledger
        ↓                                  ↑                              ↑
SNN signal diagnostics → confidence gate → Kelly sizing → paper decision → corpus-ipc / metabolic-ledger
        │                                                                  │
        └────────────── read-only dYdX market data helpers ────────────────┘
```

## Installation

```julia
] instantiate
```

Or add directly:

```julia
] add https://github.com/Limen-Neural/DendriteTrader.jl
```

### Dependencies

| Package | Purpose |
|---------|---------|
| `ZMQ`   | ZeroMQ SUB socket for signal ingestion |
| `HTTP`  | REST calls to dYdX v4 indexer |
| `JSON`  | Signal deserialization |

## Quick Start

### 1. Create an execution engine

```julia
using DendriteTrader

engine = ExecutionEngine(
    confidence_threshold = Float32(0.85),
    max_position_size    = 10.0,
    payoff_ratio         = 1.5,
)
```

### 2. Process a signal manually

```julia
signal = TradeSignal(Dict(
    "ticker"       => "MARKET-PAIR",
    "side"         => "BUY",
    "price"        => 100.0,
    "quantity"     => 1.0,
    "confidence"   => 0.92,
    "timestamp_ns" => time_ns(),
))

decision = execute_signal!(engine, signal, 10_000.0)
println(decision)
```

### 3. Start the ZMQ listener

```julia
start!(engine, zmq_endpoint = "tcp://localhost:5555") do decision
    if decision.executed
        println("Executed: $(decision.signal.ticker) × $(round(decision.position_units, digits=4))")
        println("  Latency: $(decision.latency_ns) ns")
        println("  Kelly fraction: $(round(decision.kelly_fraction, digits=4))")
    else
        println("Rejected: $(decision.reason)")
    end
end
```

### 4. Fetch market data for any supported venue symbol

```julia
client = DydxClient(base_url = "https://indexer.dydx.trade/v4")

price = get_price(client, "MARKET-PAIR")
if price !== nothing
    println("Mid:  \$$(mid_price(price))")
    println("Spread: $(spread_bps(price)) bps")
end
```

## Kelly Sizing

DendriteTrader folds the former standalone SpikeKelly sizing helpers into the main package. The sizing API maps neural confidence scores and trade statistics to Kelly or fractional-Kelly capital allocations.

```julia
using DendriteTrader

fraction = kelly_fraction(win_rate = 0.55, avg_win = 8.50, avg_loss = 5.20)
half = half_kelly(0.60, 1.5)
confidence_fraction = from_confidence(confidence = 0.90, payoff_ratio = 1.5)

position = size_position(
    confidence = 0.90,
    price = 100.0,
    account_balance = 10_000.0,
    payoff_ratio = 1.5,
)

println(position.units)
println(position.kelly_fraction)
println(position.risk)
```

### Sizing API

| Type / Function | Description |
|-----------------|-------------|
| `kelly_fraction(; win_rate, avg_win, avg_loss)` | Conservative half-Kelly fraction from historical trade statistics, clamped to `[0.0, 0.20]` |
| `half_kelly(p, b)` | Half-Kelly fraction for win probability `p` and payoff ratio `b` |
| `from_confidence(; confidence, payoff_ratio)` | Maps neural confidence directly to a half-Kelly fraction |
| `RiskTier` | Qualitative risk enum: `Aggressive`, `Moderate`, `Conservative`, `Minimal` |
| `risk_tier(confidence)` | Classifies confidence into a `RiskTier` |
| `PositionSize` | Result struct with units, Kelly fraction, confidence, risk tier, and account risk percentage |
| `size_position(; confidence, price, account_balance, payoff_ratio, kelly_scalar)` | Computes full position sizing from neural confidence |

## Signal Format

The ZMQ listener expects JSON objects matching this schema:

```json
{
  "ticker":       "MARKET-PAIR",
  "side":         "BUY",
  "price":        100.0,
  "quantity":     1.0,
  "confidence":   0.92,
  "timestamp_ns": 1744156800000000000
}
```

| Field | Type | Description |
|-------|------|-------------|
| `ticker` | string | Configurable venue symbol, e.g. `"MARKET-PAIR"` |
| `side` | string | `"BUY"`, `"SELL"`, or `"NEUTRAL"` |
| `price` | float | Expected execution price in USD |
| `quantity` | float | Producer-provided units; DendriteTrader may compute its own Kelly-sized units |
| `confidence` | float | Neural model output in `[0.0, 1.0]` |
| `timestamp_ns` | int | Unix nanoseconds at signal creation |

## API Reference

### Core Types

| Type / Function | Description |
|-----------------|-------------|
| `TradeSignal` | Immutable struct holding a deserialized trade signal |
| `ExecutionEngine` | Stateful engine with confidence gate, Kelly sizing, and position tracking |
| `ExecutionDecision` | Result of processing one signal, including requested `kelly_fraction` and capped `applied_fraction` |
| `execute_signal!(engine, signal, balance)` | Gate, size, and process a single signal |
| `latency_ns(signal)` | End-to-end latency in nanoseconds |
| `passes_gate(signal, threshold)` | Boolean check: `signal.confidence >= threshold` |
| `fill_rate(engine)` | Fraction of signals executed vs. rejected |

### dYdX v4 Client

| Type / Function | Description |
|-----------------|-------------|
| `DydxClient` | REST client for read-only dYdX v4 market data |
| `get_price(client, ticker)` | Fetch oracle price and orderbook top as `DydxPrice` or `nothing` |
| `DydxPrice` | Struct with `oracle_price`, `best_bid`, and `best_ask` |
| `mid_price(p)` | Mid between best bid and ask |
| `spread_bps(p)` | Bid-ask spread in basis points |

## Migration Notes

### From SpikenautExecution

The package/module identity is now `DendriteTrader`.

```julia
# Before
using SpikenautExecution

# After
using DendriteTrader
```

The repository is scoped as a Julia strategy/control-plane, diagnostics, and paper-trading package rather than a low-latency production execution loop.

### From SpikeKelly

The standalone SpikeKelly package is superseded by DendriteTrader's integrated sizing API.

```julia
# Before
using SpikenautKelly

# After
using DendriteTrader
```

The former SpikeKelly function names are preserved inside DendriteTrader where possible: `kelly_fraction`, `half_kelly`, `from_confidence`, `risk_tier`, and `size_position`.

## Running Tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

## License

MIT — see [`LICENSE`](LICENSE).
