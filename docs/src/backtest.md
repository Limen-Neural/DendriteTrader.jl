# Backtest

The `Backtest` module replays historical signals through the `ExecutionEngine` and computes performance metrics: total return, max drawdown, win rate, Sharpe ratio, Sortino ratio, and Calmar ratio.

```julia
using DendriteTrader

config = BacktestConfig(
    initial_balance      = 10_000.0,
    confidence_threshold = 0.85,
    payoff_ratio         = 1.5,
)

signals = load_signals_json("data/signals.json")
result  = run_backtest(config, signals)
print_summary(result)
```

## Configuration

```@docs
DendriteTrader.Backtest.BacktestConfig
```

## Running a Backtest

```@docs
DendriteTrader.Backtest.run_backtest
DendriteTrader.Backtest.print_summary
```

## Results

```@docs
DendriteTrader.Backtest.BacktestResult
DendriteTrader.Backtest.TradeRecord
```

## Signal I/O

```@docs
DendriteTrader.Backtest.load_signals_json
DendriteTrader.Backtest.load_signals_csv
DendriteTrader.Backtest.export_equity_csv
DendriteTrader.Backtest.export_trade_log_json
```

## Performance Metrics

```@docs
DendriteTrader.Backtest.compute_max_drawdown
DendriteTrader.Backtest.compute_period_returns
DendriteTrader.Backtest.compute_sharpe_ratio
DendriteTrader.Backtest.compute_sortino_ratio
DendriteTrader.Backtest.compute_calmar_ratio
DendriteTrader.Backtest.estimate_n_periods
```
