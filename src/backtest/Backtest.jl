# SPDX-License-Identifier: MIT OR Apache-2.0

"""
    Backtest

Paper trading backtest harness for DendriteTrader.

Replays historical signals through the ExecutionEngine and computes
performance metrics (PnL, Sharpe, max drawdown, win rate).

```julia
using DendriteTrader

config = BacktestConfig(
    initial_balance = 10_000.0,
    confidence_threshold = 0.85,
    payoff_ratio = 1.5,
)

signals = load_signals_json("data/signals.json")
result = run_backtest(config, signals)
print_summary(result)
```
"""
module Backtest

using JSON
using Printf
using ..DendriteTrader: TradeSignal, TradeSide, Buy, Sell, Neutral, ExecutionEngine, execute_signal!, SignalEvent, events

export BacktestConfig, BacktestResult
export run_backtest, print_summary
export load_signals_json, load_signals_csv
export export_equity_csv, export_trade_log_json

"""
    BacktestConfig

Configuration for backtest runs.

# Fields
- `initial_balance`: starting account balance (default 10,000)
- `confidence_threshold`: minimum signal confidence to execute (default 0.85)
- `payoff_ratio`: odds-style average win/loss ratio for Kelly sizing (default 1.5)
- `max_position_size`: hard cap on position units (default 10.0)
- `slippage_pct`: slippage percentage per trade (default 0.0)
- `commission_pct`: commission percentage per trade (default 0.0)
"""
struct BacktestConfig
    initial_balance::Float64
    confidence_threshold::Float32
    payoff_ratio::Float64
    max_position_size::Float64
    slippage_pct::Float64
    commission_pct::Float64
end

function BacktestConfig(;
    initial_balance::Float64 = 10_000.0,
    confidence_threshold::Float32 = Float32(0.85),
    payoff_ratio::Float64 = 1.5,
    max_position_size::Float64 = 10.0,
    slippage_pct::Float64 = 0.0,
    commission_pct::Float64 = 0.0,
)
    BacktestConfig(initial_balance, confidence_threshold, payoff_ratio, max_position_size, slippage_pct, commission_pct)
end

"""
    TradeRecord

Record of a single trade in the backtest.

# Fields
- `ticker`: market symbol
- `side`: BUY or SELL
- `entry_time`: signal timestamp (ns)
- `price`: execution price
- `units`: position size
- `kelly_fraction`: Kelly fraction used
- `pnl`: realized PnL (0.0 until closed)
"""
struct TradeRecord
    ticker::String
    side::String
    entry_time::Int64
    price::Float64
    units::Float64
    kelly_fraction::Float64
    pnl::Float64
end

"""
    BacktestResult

Result of a backtest run.

# Fields
- `config`: the BacktestConfig used
- `initial_balance`: starting balance
- `final_balance`: ending balance
- `equity_curve`: balance at each signal
- `trade_log`: list of all trades
- `events`: raw SignalEvents from the engine
- `total_return`: total return percentage
- `max_drawdown`: maximum drawdown percentage
- `win_rate`: fraction of profitable trades
- `total_trades`: number of trades executed
"""
struct BacktestResult
    config::BacktestConfig
    initial_balance::Float64
    final_balance::Float64
    equity_curve::Vector{Float64}
    trade_log::Vector{TradeRecord}
    events::Vector{SignalEvent}
    total_return::Float64
    max_drawdown::Float64
    win_rate::Float64
    total_trades::Int
end

"""
    run_backtest(config, signals) -> BacktestResult

Replay signals through the ExecutionEngine and compute performance metrics.
Applies slippage and commission when configured.
"""
function run_backtest(config::BacktestConfig, signals::Vector{TradeSignal})::BacktestResult
    engine = ExecutionEngine(
        confidence_threshold = config.confidence_threshold,
        max_position_size = config.max_position_size,
        payoff_ratio = config.payoff_ratio,
    )

    equity_curve = Float64[config.initial_balance]
    trade_log = TradeRecord[]
    balance = config.initial_balance
    positions = Dict{String, Float64}()  # ticker -> entry_price

    for signal in signals
        prev_balance = balance
        decision = execute_signal!(engine, signal, balance)

        # Record trade if executed
        if decision.executed
            # Apply slippage to execution price
            if signal.side == Buy
                execution_price = signal.price * (1.0 + config.slippage_pct / 100.0)
            else
                execution_price = signal.price * (1.0 - config.slippage_pct / 100.0)
            end

            # Apply commission
            commission = decision.position_units * execution_price * (config.commission_pct / 100.0)
            balance -= commission

            if signal.side == Buy
                # Opening a long position
                positions[signal.ticker] = execution_price
            elseif signal.side == Sell && haskey(positions, signal.ticker)
                # Closing a position — compute PnL
                entry_price = pop!(positions, signal.ticker)
                pnl = (execution_price - entry_price) * decision.position_units
                balance += pnl

                trade = TradeRecord(
                    signal.ticker,
                    string(signal.side),
                    signal.timestamp_ns,
                    execution_price,
                    decision.position_units,
                    decision.kelly_fraction,
                    pnl,
                )
                push!(trade_log, trade)
            else
                # Opening a new position (sell short or buy)
                positions[signal.ticker] = execution_price

                trade = TradeRecord(
                    signal.ticker,
                    string(signal.side),
                    signal.timestamp_ns,
                    execution_price,
                    decision.position_units,
                    decision.kelly_fraction,
                    0.0,  # PnL computed on close
                )
                push!(trade_log, trade)
            end
        end

        # Update equity curve after processing
        push!(equity_curve, balance)
    end

    final_balance = balance
    total_return = (final_balance - config.initial_balance) / config.initial_balance * 100.0
    max_dd = compute_max_drawdown(equity_curve)
    closed_trades = filter(t -> t.pnl != 0.0, trade_log)
    num_winning = count(t -> t.pnl > 0.0, closed_trades)
    wr = isempty(closed_trades) ? 0.0 : num_winning / length(closed_trades)

    return BacktestResult(
        config,
        config.initial_balance,
        final_balance,
        equity_curve,
        trade_log,
        events(engine),
        total_return,
        max_dd,
        wr,
        length(trade_log),
    )
end

"""
    compute_max_drawdown(equity_curve) -> Float64

Compute maximum drawdown percentage from equity curve.
"""
function compute_max_drawdown(equity::Vector{Float64})
    if length(equity) < 2
        return 0.0
    end

    peak = equity[1]
    max_dd = 0.0

    for val in equity
        if val > peak
            peak = val
        end
        dd = (peak - val) / peak * 100.0
        if dd > max_dd
            max_dd = dd
        end
    end

    return max_dd
end

"""
    print_summary(result)

Print a formatted summary table of backtest results.
"""
function print_summary(result::BacktestResult)
    println()
    println("═══════════════════════════════════════════")
    println("  DendriteTrader Backtest")
    println("═══════════════════════════════════════════")
    println("  Initial Balance:    \$$(format_currency(result.initial_balance))")
    println("  Final Balance:      \$$(format_currency(result.final_balance))")
    println(
        "  Total Return:       $(result.total_return >= 0 ? "+" : "")$(round(result.total_return, digits=2))%",
    )
    println("  Max Drawdown:       -$(round(result.max_drawdown, digits=2))%")
    println("  Win Rate:           $(round(result.win_rate * 100, digits=1))%")
    println("  Total Trades:       $(result.total_trades)")
    println("═══════════════════════════════════════════")
    println()
end

"""
    format_currency(val) -> String

Format a number as currency with commas.
"""
function format_currency(val::Float64)
    sign = val < 0 ? "-" : ""
    s = @sprintf("%.2f", abs(val))
    int_part, dec_part = split(s, ".")
    n = length(int_part)
    result = Char[]
    for (i, d) in enumerate(int_part)
        if i > 1 && (n - i + 1) % 3 == 0
            push!(result, ',')
        end
        push!(result, d)
    end
    return sign * String(result) * "." * dec_part
end

"""
    load_signals_json(path) -> Vector{TradeSignal}

Load trade signals from a JSON file.
"""
function load_signals_json(path::String)::Vector{TradeSignal}
    data = JSON.parsefile(path)
    signals = TradeSignal[]
    for d in data
        push!(signals, TradeSignal(d))
    end
    return signals
end

"""
    load_signals_csv(path) -> Vector{TradeSignal}

Load trade signals from a CSV file.
Expected columns: ticker, side, price, quantity, confidence, timestamp_ns
"""
function load_signals_csv(path::String)::Vector{TradeSignal}
    signals = TradeSignal[]
    lines = readlines(path)

    # Skip header if present
    start_idx = 2
    if !isempty(lines) && occursin("ticker", lowercase(lines[1]))
        start_idx = 2
    else
        start_idx = 1
    end

    for i in start_idx:length(lines)
        line = strip(lines[i])
        if isempty(line)
            continue
        end
        parts = split(line, ",")
        if length(parts) >= 6
            d = Dict(
                "ticker" => strip(parts[1]),
                "side" => strip(parts[2]),
                "price" => parse(Float64, strip(parts[3])),
                "quantity" => parse(Float64, strip(parts[4])),
                "confidence" => parse(Float64, strip(parts[5])),
                "timestamp_ns" => parse(Int64, strip(parts[6])),
            )
            push!(signals, TradeSignal(d))
        end
    end
    return signals
end

"""
    export_equity_csv(result, path)

Export equity curve to a CSV file.
"""
function export_equity_csv(result::BacktestResult, path::String)
    open(path, "w") do io
        println(io, "index,equity")
        for (i, val) in enumerate(result.equity_curve)
            println(io, "$i,$val")
        end
    end
    @info "Equity curve exported to $path"
end

"""
    export_trade_log_json(result, path)

Export trade log to a JSON file.
"""
function export_trade_log_json(result::BacktestResult, path::String)
    trades = [
        Dict(
            "ticker" => t.ticker,
            "side" => t.side,
            "entry_time" => t.entry_time,
            "price" => t.price,
            "units" => t.units,
            "kelly_fraction" => t.kelly_fraction,
            "pnl" => t.pnl,
        ) for t in result.trade_log
    ]

    open(path, "w") do io
        JSON.print(io, trades, 2)
    end
    @info "Trade log exported to $path"
end

end # module
