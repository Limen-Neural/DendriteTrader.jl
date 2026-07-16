# Sizing

The `SizingModule` provides Kelly and fractional-Kelly position sizing, mapping neural confidence scores and historical trade statistics to capital allocations.

```julia
using DendriteTrader

fraction = kelly_fraction(win_rate = 0.55, avg_win = 8.50, avg_loss = 5.20)
position = size_position(confidence = 0.90, price = 100.0, account_balance = 10_000.0)
```

## Kelly Helpers

```@docs
DendriteTrader.SizingModule.kelly_fraction
DendriteTrader.SizingModule.half_kelly
DendriteTrader.SizingModule.from_confidence
```

## Risk Classification

```@docs
DendriteTrader.SizingModule.RiskTier
DendriteTrader.SizingModule.risk_tier
```

## Position Sizing

```@docs
DendriteTrader.SizingModule.PositionSize
DendriteTrader.SizingModule.size_position
```
