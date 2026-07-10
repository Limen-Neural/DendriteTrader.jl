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
- `risk_free_rate`: annualized risk-free rate for Sharpe/Sortino (default 0.0)
- `slippage_pct`: slippage percentage per trade (default 0.0)
- `commission_pct`: commission percentage per trade (default 0.0)
"""
struct BacktestConfig
    initial_balance::Float64
    confidence_threshold::Float32
    payoff_ratio::Float64
    max_position_size::Float64
    risk_free_rate::Float64
    slippage_pct::Float64
    commission_pct::Float64
end

function BacktestConfig(;
    initial_balance = 10_000.0,
    confidence_threshold = 0.85f0,
    payoff_ratio = 1.5,
    max_position_size = 10.0,
    risk_free_rate = 0.0,
    slippage_pct = 0.0,
    commission_pct = 0.0,
)
    BacktestConfig(
        Float64(initial_balance),
        Float32(confidence_threshold),
        Float64(payoff_ratio),
        Float64(max_position_size),
        Float64(risk_free_rate),
        Float64(slippage_pct),
        Float64(commission_pct),
    )
end

# Preserve the four-argument positional constructor for backward compatibility
function BacktestConfig(
    initial_balance::Real,
    confidence_threshold::Real,
    payoff_ratio::Real,
    max_position_size::Real,
)
    BacktestConfig(;
        initial_balance = initial_balance,
        confidence_threshold = confidence_threshold,
        payoff_ratio = payoff_ratio,
        max_position_size = max_position_size,
    )
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
- `sharpe_ratio`: annualized Sharpe ratio
- `sortino_ratio`: annualized Sortino ratio
- `calmar_ratio`: Calmar ratio
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
    sharpe_ratio::Float64
    sortino_ratio::Float64
    calmar_ratio::Float64
end

# Preserve the 10-argument positional constructor for backward compatibility
function BacktestResult(
    config::BacktestConfig,
    initial_balance::Float64,
    final_balance::Float64,
    equity_curve::Vector{Float64},
    trade_log::Vector{TradeRecord},
    events::Vector{SignalEvent},
    total_return::Float64,
    max_drawdown::Float64,
    win_rate::Float64,
    total_trades::Int,
)
    BacktestResult(
        config, initial_balance, final_balance, equity_curve, trade_log, events,
        total_return, max_drawdown, win_rate, total_trades, 0.0, 0.0, 0.0,
    )
end

"""
    OpenPosition

Open position state used for correct close sizing and short/long PnL.
"""
struct OpenPosition
    entry_price::Float64
    units::Float64
    side::TradeSide  # Buy = long, Sell = short
    entry_commission::Float64
    last_mark_price::Float64
end

"""
    apply_slippage(price, side, slippage_pct) -> Float64

Apply adverse market-order slippage: buys fill higher, sells fill lower.
This is adverse for both long entries and short entries (shorts sell into the bid).
"""
function apply_slippage(price::Float64, side::TradeSide, slippage_pct::Float64)
    if side == Buy
        return price * (1.0 + slippage_pct / 100.0)
    elseif side == Sell
        return price * (1.0 - slippage_pct / 100.0)
    else
        return price
    end
end

"""
    estimate_n_periods(signals, n_returns) -> (Int, Bool)

Estimate trading-day count for annualization.

Returns `(n_periods, is_calendar_days)`. Uses wall-clock span from signal
timestamps when available (>= 1 day), otherwise falls back to the number of
equity-curve return periods (one per processed signal). The flag lets callers
distinguish calendar days from signal counts for correct annualization.
"""
function estimate_n_periods(signals::Vector{TradeSignal}, n_returns::Int)::Tuple{Int,Bool}
    if length(signals) >= 2
        ts_min = minimum(s.timestamp_ns for s in signals)
        ts_max = maximum(s.timestamp_ns for s in signals)
        span_ns = ts_max - ts_min
        if span_ns > 0
            days = span_ns / 1e9 / 86_400.0
            if days >= 1.0
                return (max(1, round(Int, days)), true)
            end
        end
    end
    return (max(1, n_returns), false)
end

"""
    run_backtest(config, signals) -> BacktestResult

Replay signals through the ExecutionEngine and compute performance metrics.
Applies slippage and commission when configured.

Position sizing on close uses the units stored at open (not the exit signal's
Kelly size). Slippage is adverse for market orders: buys fill higher, sells
lower (also adverse for short entries). Annualization uses calendar span from
signal timestamps when that span is at least one day.

Same-side re-entries accumulate position units with weighted-average entry.
Non-trade marks use unslipped signal prices. Calmar uses final equity (MTM).
total_trades counts closed round-trips only.
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
    # ticker -> open position (entry price, opened units, side, entry commission)
    positions = Dict{String, OpenPosition}()

    for signal in signals
        decision = execute_signal!(engine, signal, balance)

        if decision.executed
            execution_price = apply_slippage(signal.price, signal.side, config.slippage_pct)
            open_pos = get(positions, signal.ticker, nothing)

            if open_pos !== nothing && (
                (open_pos.side == Buy && signal.side == Sell) ||
                (open_pos.side == Sell && signal.side == Buy)
            )
                # Close: use opened units, not exit Kelly size
                entry_units = open_pos.units
                entry_price = open_pos.entry_price
                commission = entry_units * execution_price * (config.commission_pct / 100.0)
                balance -= commission

                if open_pos.side == Buy
                    gross_pnl = (execution_price - entry_price) * entry_units
                else
                    # Short close (buy to cover)
                    gross_pnl = (entry_price - execution_price) * entry_units
                end
                # Net trade PnL includes entry + close commissions so trade_log reconciles
                pnl = gross_pnl - commission - open_pos.entry_commission
                balance += gross_pnl
                delete!(positions, signal.ticker)

                push!(
                    trade_log,
                    TradeRecord(
                        signal.ticker,
                        string(signal.side),
                        signal.timestamp_ns,
                        execution_price,
                        entry_units,
                        decision.kelly_fraction,
                        pnl,
                    ),
                )
            elseif open_pos !== nothing && open_pos.side == signal.side
                # Same-side re-entry: accumulate units, weighted-average entry, charge commission
                new_units = decision.position_units
                new_commission = new_units * execution_price * (config.commission_pct / 100.0)
                balance -= new_commission
                total_units = min(open_pos.units + new_units, config.max_position_size)
                weighted_entry = (open_pos.entry_price * open_pos.units + execution_price * new_units) / total_units
                positions[signal.ticker] = OpenPosition(
                    weighted_entry,
                    total_units,
                    open_pos.side,
                    open_pos.entry_commission + new_commission,
                    signal.price,
                )
                # Record same-side fill in trade_log for ledger completeness
                push!(
                    trade_log,
                    TradeRecord(
                        signal.ticker,
                        string(signal.side),
                        signal.timestamp_ns,
                        execution_price,
                        new_units,
                        decision.kelly_fraction,
                        0.0,
                    ),
                )
            else
                # Open new position
                units = decision.position_units
                commission = units * execution_price * (config.commission_pct / 100.0)
                balance -= commission
                positions[signal.ticker] = OpenPosition(
                    execution_price,
                    units,
                    signal.side,
                    commission,
                    signal.price,
                )
            end
        elseif haskey(positions, signal.ticker)
            # Update mark price even when the signal is not executed (for MTM equity)
            # Use unslipped signal.price — no order was booked
            pos = positions[signal.ticker]
            positions[signal.ticker] = OpenPosition(
                pos.entry_price,
                pos.units,
                pos.side,
                pos.entry_commission,
                signal.price,
            )
        end

        # Mark-to-market equity: cash + unrealized PnL on open positions
        mtm = balance
        for (_, pos) in positions
            if pos.side == Buy
                mtm += (pos.last_mark_price - pos.entry_price) * pos.units
            else
                mtm += (pos.entry_price - pos.last_mark_price) * pos.units
            end
        end
        push!(equity_curve, mtm)
    end

    # Use final equity (MTM) for total_return so it matches equity_curve
    final_equity = balance
    for (_, pos) in positions
        if pos.side == Buy
            final_equity += (pos.last_mark_price - pos.entry_price) * pos.units
        else
            final_equity += (pos.entry_price - pos.last_mark_price) * pos.units
        end
    end
    final_balance = final_equity
    total_return = (final_equity - config.initial_balance) / config.initial_balance * 100.0
    max_dd = compute_max_drawdown(equity_curve)
    closed_trades = filter(t -> t.pnl != 0.0, trade_log)
    num_winning = count(t -> t.pnl > 0.0, closed_trades)
    wr = isempty(closed_trades) ? 0.0 : num_winning / length(closed_trades)

    returns = compute_period_returns(equity_curve)
    n_periods, is_calendar_days = estimate_n_periods(signals, length(returns))
    sr = compute_sharpe_ratio(returns, config.risk_free_rate, n_periods, is_calendar_days)
    sortino = compute_sortino_ratio(returns, config.risk_free_rate, n_periods, is_calendar_days)
    calmar = compute_calmar_ratio(total_return, max_dd, n_periods, is_calendar_days)

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
        length(closed_trades),
        sr,
        sortino,
        calmar,
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
    compute_period_returns(equity_curve) -> Vector{Float64}

Compute period-over-period returns from equity curve.

When prior equity is non-positive (account wiped out), the period return is
recorded as `-1.0` (full loss) if equity falls further or stays non-positive,
rather than `0.0`, so risk metrics still reflect the blow-up.
"""
function compute_period_returns(equity::Vector{Float64})
    n = length(equity)
    if n < 2
        return Float64[]
    end
    returns = Vector{Float64}(undef, n - 1)
    for i in 2:n
        prev = equity[i - 1]
        curr = equity[i]
        if prev > 0.0
            returns[i - 1] = (curr - prev) / prev
        elseif curr < prev
            returns[i - 1] = -1.0
        else
            returns[i - 1] = 0.0
        end
    end
    return returns
end

"""
    _per_signal_risk_free(risk_free_rate, spd) -> Float64

Convert annualized risk-free rate to a per-signal rate.
Accounts for signals-per-day (spd) so Sharpe/Sortino subtract a rate on the
same timescale as per-signal returns. Returns 0.0 when the rate is outside
the valid domain `>= -1.0`.
"""
function _per_signal_risk_free(risk_free_rate::Float64, spd::Float64)
    if risk_free_rate < -1.0 || !isfinite(risk_free_rate)
        return 0.0
    end
    return (1.0 + risk_free_rate)^(1.0 / (252.0 * spd)) - 1.0
end

"""
    compute_sharpe_ratio(returns, risk_free_rate, n_periods, is_calendar_days) -> Float64

Compute annualized Sharpe ratio using sample std (N-1).

Uses per-signal risk-free rate (divided by signals_per_day when calendar days)
so the subtraction is on the same timescale as per-signal returns. The spd
scaling cancels between numerator and denominator, making the ratio
independent of signal frequency.
"""
function compute_sharpe_ratio(returns::Vector{Float64}, risk_free_rate::Float64, n_periods::Int, is_calendar_days::Bool)
    n = length(returns)
    if n < 2
        return 0.0
    end
    spd = is_calendar_days ? n / n_periods : 1.0
    rf = _per_signal_risk_free(risk_free_rate, spd)
    mean_r = sum(returns) / n
    std_r = sqrt(sum((r - mean_r)^2 for r in returns) / (n - 1))
    if std_r < 1e-12
        return 0.0
    end
    return (mean_r - rf) / std_r * sqrt(252.0 * spd)
end

"""
    compute_sortino_ratio(returns, risk_free_rate, n_periods, is_calendar_days) -> Float64

Compute annualized Sortino ratio using sample downside deviation (N-1).

Uses per-signal risk-free rate (divided by signals_per_day when calendar days)
so the subtraction is on the same timescale as per-signal returns. The spd
scaling cancels between numerator and denominator, making the ratio
independent of signal frequency.
"""
function compute_sortino_ratio(returns::Vector{Float64}, risk_free_rate::Float64, n_periods::Int, is_calendar_days::Bool)
    n = length(returns)
    if n < 2
        return 0.0
    end
    spd = is_calendar_days ? n / n_periods : 1.0
    rf = _per_signal_risk_free(risk_free_rate, spd)
    mean_r = sum(returns) / n
    mean_excess = mean_r - rf
    downside_sum = sum(min(r - rf, 0.0)^2 for r in returns)
    downside_dev = sqrt(downside_sum / (n - 1))
    if downside_dev < 1e-12
        return 0.0
    end
    return mean_excess / downside_dev * sqrt(252.0 * spd)
end

"""
    compute_calmar_ratio(total_return, max_drawdown, n_periods, is_calendar_days) -> Float64

Compute Calmar ratio (annualized return / max drawdown).

Returns 0.0 when the account is wiped out (`total_return <= -100`) or the
wealth multiple is non-positive, avoiding `DomainError` from a negative base
raised to a fractional power.

When `is_calendar_days` is true, uses `365.0 / n_periods` exponent (calendar
days -> annual). Otherwise uses `252.0 / n_periods` (trading days -> annual).
"""
function compute_calmar_ratio(total_return::Float64, max_drawdown::Float64, n_periods::Int, is_calendar_days::Bool)
    if max_drawdown < 1e-12 || n_periods < 1 || total_return <= -100.0
        return 0.0
    end
    wealth_multiple = 1.0 + total_return / 100.0
    if wealth_multiple <= 0.0 || !isfinite(wealth_multiple)
        return 0.0
    end
    year_divisor = is_calendar_days ? 365.0 : 252.0
    annualized = wealth_multiple^(year_divisor / n_periods) - 1.0
    return annualized / (max_drawdown / 100.0)
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
    println("───────────────────────────────────────────")
    println("  Sharpe Ratio:       $(round(result.sharpe_ratio, digits=3))")
    println("  Sortino Ratio:      $(round(result.sortino_ratio, digits=3))")
    println("  Calmar Ratio:       $(round(result.calmar_ratio, digits=3))")
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
