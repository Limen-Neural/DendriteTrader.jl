# SPDX-License-Identifier: MIT OR Apache-2.0

"""
    DendriteTrader

Julia strategy, diagnostics, paper-trading, and control-plane layer for neural trading systems.

Bridges Julia SNN strategy output to trading decisions with:
- ZMQ SUB socket for JSON trade signals from Rust nervous system
- Nanosecond latency tracking (signal creation → execution)
- Confidence gate (only executes signals above threshold)
- Integrated Kelly/fractional-Kelly position sizing
- dYdX v4 decentralized perpetuals REST client (no API key required)

## Architecture

```
Julia (Brain)          Rust (Muscle)           Exchange
     ↓                      ↑
LIF neurons → SNN signal → ZMQ bridge → Kelly sizing → dydx v4 → Order
(16 neurons)  (confidence)   (IPC)        (sizing)     (REST)
```

## Provenance

Developed as a Julia control-plane and paper-trading package for custom neuromorphic SNN models and ML trading integrations.
Latency-critical execution loops remain the responsibility of adjacent Rust services.

## Repository Boundary

DendriteTrader owns:
- `TradeSignal`, confidence gating, `ExecutionDecision`
- Kelly sizing proposals (`kelly_fraction`, `from_confidence`, `PositionSize`, `size_position`)
- dYdX v4 REST client (read-only market data)
- ZMQ SUB consumer — signal → decision only

DendriteTrader does **NOT** own:
- `GhostWallet`-like persistent accounting state
- Win rate, realized PnL, portfolio position tracking

Win-rate/PnL tracking belongs in `metabolic-ledger`.

## References

- Kelly, J.L. (1956). A New Interpretation of Information Rate.
  *Bell System Technical Journal*, 35(4), 917–926.
  https://doi.org/10.1002/j.1538-7305.1956.tb03809.x
  Position sizing via the Kelly Criterion.

- dYdX Foundation (2024). *dYdX v4 Indexer API Documentation*.
  REST endpoints for orderbook queries and perpetual market data.
  https://docs.dydx.exchange/api_integration-indexer/indexer_api

- iMatix Corporation (2013). *ZeroMQ: Messaging for Many Applications*.
  O'Reilly Media. SUB socket pattern for trade signal delivery.
  https://zguide.zeromq.org

## Usage

```julia
using DendriteTrader

engine = ExecutionEngine(confidence_threshold=0.85)
start!(engine, zmq_endpoint="tcp://localhost:5555")
```
"""

module DendriteTrader

using JSON
using HTTP
using ZMQ

export TradeSignal, TradeSide, Buy, Sell, Neutral, ExecutionEngine, ExecutionDecision
export validate_signal, execute_signal!, latency_ns, passes_gate
export DydxClient, DydxPrice, get_price, mid_price, spread_bps
export start!, stop!, fill_rate
export kelly_fraction, from_confidence, half_kelly
export RiskTier, Aggressive, Moderate, Conservative, Minimal, risk_tier
export PositionSize, size_position

include("sizing/kelly.jl")

# ── Trade Signal ─────────────────────────────────────────────────────────────

"""
    @enum TradeSide

Direction of a trade signal.
"""
@enum TradeSide begin
    Buy = 1
    Sell = 2
    Neutral = 0
end

"""
    TradeSignal

Deserialized trade signal from Rust nervous system via ZMQ.

# Fields
- `ticker`:       configurable venue symbol
- `side`:         Buy / Sell / Neutral
- `price`:        expected execution price (USD)
- `quantity`:     units to trade (Kelly-sized by Rust, override in Julia)
- `confidence`:   SNN output [0.0, 1.0]
- `timestamp_ns`: Unix nanoseconds for latency tracking
"""
struct TradeSignal
    ticker::String
    side::TradeSide
    price::Float64
    quantity::Float64
    confidence::Float32
    timestamp_ns::Int64
end

"""
    validate_signal(d::Dict) -> Union{Nothing, String}

Validate a trade signal dictionary. Returns `nothing` if valid, or an error message string.

# Required Fields
- `ticker`: String, non-empty
- `side`: "BUY", "SELL", or "NEUTRAL"
- `price`: Number > 0
- `confidence`: Number in [0.0, 1.0]
- `timestamp_ns`: Integer > 0
"""
function validate_signal(d::Dict)
    # Check required fields
    for field in ("ticker", "side", "price", "confidence", "timestamp_ns")
        if !haskey(d, field)
            return "missing required field: $field"
        end
    end

    # Validate ticker
    ticker = d["ticker"]
    if !(ticker isa AbstractString) || isempty(ticker)
        return "ticker must be a non-empty string"
    end

    # Validate side
    side = d["side"]
    if !(side isa AbstractString) || !(side in ("BUY", "SELL", "NEUTRAL"))
        return "side must be BUY, SELL, or NEUTRAL, got: $side"
    end

    # Validate price
    price = d["price"]
    if !(price isa Number)
        return "price must be a number, got: $(typeof(price))"
    end
    if price <= 0
        return "price must be positive, got: $price"
    end

    # Validate confidence
    confidence = d["confidence"]
    if !(confidence isa Number)
        return "confidence must be a number, got: $(typeof(confidence))"
    end
    if confidence < 0.0 || confidence > 1.0
        return "confidence must be in [0.0, 1.0], got: $confidence"
    end

    # Validate timestamp_ns
    timestamp = d["timestamp_ns"]
    if !(timestamp isa Integer)
        return "timestamp_ns must be an integer, got: $(typeof(timestamp))"
    end
    if timestamp <= 0
        return "timestamp_ns must be positive, got: $timestamp"
    end

    return nothing
end

function TradeSignal(d::Dict)
    side = if get(d, "side", "NEUTRAL") == "BUY"
        Buy
    elseif get(d, "side", "NEUTRAL") == "SELL"
        Sell
    else
        Neutral
    end
    TradeSignal(
        get(d, "ticker", "UNKNOWN"),
        side,
        Float64(get(d, "price", 0.0)),
        Float64(get(d, "quantity", 0.0)),
        Float32(get(d, "confidence", 0.0)),
        Int64(get(d, "timestamp_ns", 0)),
    )
end

"""
    latency_ns(signal) -> Int64

End-to-end latency from signal creation to now (nanoseconds).
Uses Unix epoch time to match Rust `timestamp_nanos` semantics.
"""
function latency_ns(s::TradeSignal)::Int64
    now_ns = round(Int64, time() * 1_000_000_000)
    return max(0, now_ns - s.timestamp_ns)
end

"""
    passes_gate(signal, threshold) -> Bool

True if signal confidence meets or exceeds the threshold.
"""
passes_gate(s::TradeSignal, threshold::Float32) = s.confidence >= threshold

# ── Execution Decision ────────────────────────────────────────────────────────

"""
    ExecutionDecision

Result of processing one signal through the execution engine.
"""
struct ExecutionDecision
    signal::TradeSignal
    executed::Bool
    reason::String
    kelly_fraction::Float64
    applied_fraction::Float64
    position_units::Float64
    latency_ns::Int64
end

# ── Execution Engine ──────────────────────────────────────────────────────────

"""
    ExecutionEngine

Stateful execution engine with confidence gating and position management.

# Fields
- `confidence_threshold`: minimum SNN confidence to execute (default 0.85)
- `max_position_size`:    hard cap on position units (default 10.0)
- `payoff_ratio`:         odds-style average win/loss ratio for Kelly sizing (default 1.5)
- `positions`:            current open positions (ticker → quantity)
"""
mutable struct ExecutionEngine
    confidence_threshold::Float32
    max_position_size::Float64
    payoff_ratio::Float64
    positions::Dict{String, Float64}
    total_signals::Int
    executed_signals::Int
    rejected_signals::Int
    should_stop::Bool
end

function ExecutionEngine(;
    confidence_threshold::Float32 = Float32(0.85),
    max_position_size::Float64 = 10.0,
    payoff_ratio::Float64 = 1.5,
)
    ExecutionEngine(
        confidence_threshold,
        max_position_size,
        payoff_ratio,
        Dict{String, Float64}(),
        0,
        0,
        0,
        false,
    )
end

"""
    stop!(engine)

Signal the engine to stop its ZMQ listener loop.

Call this from another task or thread to gracefully shut down `start!`.
"""
function stop!(engine::ExecutionEngine)
    engine.should_stop = true
end

"""
    execute_signal!(engine, signal, account_balance) -> ExecutionDecision

Process one signal: gate by confidence, size via Kelly, update positions.
"""
function execute_signal!(
    engine::ExecutionEngine,
    signal::TradeSignal,
    account_balance::Float64 = 10_000.0,
)::ExecutionDecision
    engine.total_signals += 1
    lat = latency_ns(signal)

    if !passes_gate(signal, engine.confidence_threshold)
        engine.rejected_signals += 1
        return ExecutionDecision(
            signal,
            false,
            "confidence=$(signal.confidence) < threshold=$(engine.confidence_threshold)",
            0.0,
            0.0,
            0.0,
            lat,
        )
    end

    if signal.side == Neutral
        engine.rejected_signals += 1
        return ExecutionDecision(signal, false, "neutral signal", 0.0, 0.0, 0.0, lat)
    end

    position = size_position(
        confidence = Float64(signal.confidence),
        price = signal.price,
        account_balance = account_balance,
        payoff_ratio = engine.payoff_ratio,
    )
    units = min(position.units, engine.max_position_size)

    if units <= 0.0
        engine.rejected_signals += 1
        return ExecutionDecision(
            signal,
            false,
            "zero-sized position",
            position.kelly_fraction,
            0.0,
            0.0,
            lat,
        )
    end

    applied_fraction = account_balance <= 0.0 ? 0.0 : (units * signal.price) / account_balance

    # Update position book
    current = get(engine.positions, signal.ticker, 0.0)
    if signal.side == Buy
        engine.positions[signal.ticker] = current + units
    elseif signal.side == Sell
        engine.positions[signal.ticker] = max(0.0, current - units)
    end

    engine.executed_signals += 1
    return ExecutionDecision(
        signal,
        true,
        "executed",
        position.kelly_fraction,
        applied_fraction,
        units,
        lat,
    )
end

"""
    fill_rate(engine) -> Float64

Fraction of signals that were executed (not rejected).
"""
fill_rate(e::ExecutionEngine) = e.total_signals == 0 ? 0.0 : e.executed_signals / e.total_signals

# ── dYdX v4 REST Client ───────────────────────────────────────────────────────

"""
    DydxPrice

Current price data from dYdX v4 indexer.
"""
struct DydxPrice
    ticker::String
    oracle_price::Float64
    best_bid::Float64
    best_ask::Float64
end

"""
    mid_price(p) -> Float64

Mid-price between best bid and ask.
"""
mid_price(p::DydxPrice) = (p.best_bid + p.best_ask) / 2.0

"""
    spread_bps(p) -> Float64

Bid-ask spread in basis points.
"""
spread_bps(p::DydxPrice) = max(p.best_ask - p.best_bid, 0.0) / max(p.best_ask, 1e-9) * 10_000.0

"""
    DydxClient

REST client for dYdX v4 perpetuals (no API key required for read-only market data).
"""
struct DydxClient
    base_url::String
    timeout_s::Float64
end

DydxClient(; base_url::String = "https://indexer.dydx.trade/v4", timeout_s::Float64 = 5.0) =
    DydxClient(base_url, timeout_s)

"""
    get_price(client, ticker) -> Union{DydxPrice, Nothing}

Fetch current oracle price and order book top for `ticker`.
Returns `nothing` on network error.
"""
function get_price(client::DydxClient, ticker::String)::Union{DydxPrice, Nothing}
    try
        url = "$(client.base_url)/orderbooks/perpetualMarket/$(ticker)"
        resp = HTTP.get(url; readtimeout = client.timeout_s)
        data = JSON.parse(String(resp.body))

        bids = get(data, "bids", [])
        asks = get(data, "asks", [])

        best_bid = isempty(bids) ? 0.0 : parse(Float64, first(bids)["price"])
        best_ask = isempty(asks) ? 0.0 : parse(Float64, first(asks)["price"])

        # Oracle price from markets endpoint
        market_url = "$(client.base_url)/perpetualMarkets?ticker=$(ticker)"
        market_resp = HTTP.get(market_url; readtimeout = client.timeout_s)
        market_data = JSON.parse(String(market_resp.body))
        markets = get(market_data, "markets", Dict())
        oracle = if haskey(markets, ticker)
            parse(Float64, get(markets[ticker], "oraclePrice", "0"))
        else
            (best_bid + best_ask) / 2.0
        end

        return DydxPrice(ticker, oracle, best_bid, best_ask)
    catch e
        @warn "dYdX price fetch failed for $ticker: $e"
        return nothing
    end
end

# ── ZMQ Signal Listener ───────────────────────────────────────────────────────

"""
    start!(engine; zmq_endpoint, account_balance, on_decision, timeout_s)

Start the ZMQ SUB listener loop (requires ZMQ.jl).

Subscribes to `zmq_endpoint` and processes incoming JSON trade signals
through the execution engine, calling `on_decision` for each result.

# Arguments
- `engine`:          `ExecutionEngine` instance
- `zmq_endpoint`:    ZMQ endpoint (e.g. "tcp://localhost:5555" or "ipc:///tmp/signals.ipc")
- `account_balance`: account size for Kelly sizing
- `on_decision`:     callback `(ExecutionDecision) -> Nothing`
- `timeout_s`:       total seconds to run before auto-stopping (nothing = run forever)

# Shutdown

Call `stop!(engine)` from another task to gracefully stop the listener.
The loop checks `engine.should_stop` periodically.

# Example
```julia
engine = ExecutionEngine(confidence_threshold=Float32(0.85))

# Run in background task
t = @async start!(engine, zmq_endpoint="tcp://localhost:5555") do decision
    println("Decision: \$(decision.executed)")
end

# Stop after 60 seconds
sleep(60)
stop!(engine)
```
"""
function start!(
    engine::ExecutionEngine;
    zmq_endpoint::String = "tcp://localhost:5555",
    account_balance::Float64 = 10_000.0,
    on_decision = decision -> nothing,
    timeout_s::Union{Float64, Nothing} = nothing,
)
    ctx = ZMQ.Context()
    socket = ZMQ.Socket(ctx, ZMQ.SUB)
    ZMQ.subscribe(socket, "")
    ZMQ.connect(socket, zmq_endpoint)

    # Set receive timeout to 1 second so we can check should_stop periodically
    ZMQ.set_rcvtimeo(socket, 1000)

    @info "[execution] ZMQ SUB connected to $zmq_endpoint"

    start_time = time()
    try
        while !engine.should_stop
            if timeout_s !== nothing && (time() - start_time) >= timeout_s
                @info "[execution] Timeout reached, stopping listener"
                break
            end

            try
                msg = ZMQ.recv(socket)
                data = JSON.parse(String(msg))

                # Validate signal before processing
                err = validate_signal(data)
                if err !== nothing
                    @warn "[execution] Invalid signal: $err"
                    continue
                end

                signal = TradeSignal(data)
                decision = execute_signal!(engine, signal, account_balance)
                on_decision(decision)
            catch e
                if e isa ZMQ.TimeoutError
                    # recv timeout, loop back to check should_stop
                    continue
                else
                    rethrow(e)
                end
            end
        end
    finally
        ZMQ.close(socket)
        ZMQ.close(ctx)
        @info "[execution] ZMQ listener stopped"
    end
end

end # module
