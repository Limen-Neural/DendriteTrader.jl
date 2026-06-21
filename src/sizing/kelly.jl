# SPDX-License-Identifier: MIT OR Apache-2.0

"""
    kelly_fraction(; win_rate, avg_win, avg_loss) -> Float64

Compute a conservative half-Kelly position fraction from historical trade statistics.

# Arguments
- `win_rate`: fraction of trades that were profitable (0.0–1.0)
- `avg_win`: average profit of winning trades
- `avg_loss`: average loss of losing trades as an absolute value

# Returns
Half-Kelly fraction clamped to `[0.0, 0.20]`.
"""
function kelly_fraction(; win_rate::Real, avg_win::Real, avg_loss::Real)::Float64
    win_rate = clamp(Float64(win_rate), 0.0, 1.0)
    avg_win = max(Float64(avg_win), 1e-9)
    avg_loss = max(Float64(avg_loss), 1e-9)

    b = avg_win / avg_loss
    q = 1.0 - win_rate
    full = (win_rate * b - q) / b
    half = full * 0.5

    return clamp(half, 0.0, 0.20)
end

"""
    half_kelly(p, b) -> Float64

Compute the half-Kelly fraction for win probability `p` and payoff ratio `b`.
"""
function half_kelly(p::Real, b::Real)::Float64
    p = clamp(Float64(p), 0.0, 1.0)
    b = max(Float64(b), 1e-9)
    q = 1.0 - p
    full = (p * b - q) / b
    return clamp(full * 0.5, 0.0, 1.0)
end

"""
    from_confidence(; confidence, payoff_ratio=1.5) -> Float64

Map neural confidence `[0, 1]` to a half-Kelly position fraction.

`payoff_ratio` is interpreted as an odds-style average win/loss ratio.
"""
function from_confidence(; confidence::Real, payoff_ratio::Real = 1.5)::Float64
    return half_kelly(confidence, payoff_ratio)
end

"""
    @enum RiskTier

Qualitative risk classification derived from neural confidence.
"""
@enum RiskTier begin
    Aggressive = 4
    Moderate = 3
    Conservative = 2
    Minimal = 1
end

"""
    risk_tier(confidence) -> RiskTier

Classify neural confidence into a qualitative risk tier.
"""
function risk_tier(confidence::Real)::RiskTier
    confidence = Float64(confidence)
    if confidence >= 0.95
        return Aggressive
    elseif confidence >= 0.85
        return Moderate
    elseif confidence >= 0.70
        return Conservative
    else
        return Minimal
    end
end

"""
    PositionSize

Result of a Kelly position sizing calculation.

# Fields
- `units`: number of asset units to trade
- `kelly_fraction`: fraction of account balance committed
- `confidence`: original neural confidence input
- `risk`: qualitative risk tier
- `account_risk_pct`: percentage of account balance committed
"""
struct PositionSize
    units::Float64
    kelly_fraction::Float64
    confidence::Float64
    risk::RiskTier
    account_risk_pct::Float64
end

"""
    size_position(; confidence, price, account_balance, payoff_ratio=1.5, kelly_scalar=0.5) -> PositionSize

Compute position sizing from neural confidence.

`payoff_ratio` is interpreted as an odds-style average win/loss ratio. Non-positive
prices or balances return a zero-sized position.
"""
function size_position(;
    confidence::Real,
    price::Real,
    account_balance::Real,
    payoff_ratio::Real = 1.5,
    kelly_scalar::Real = 0.5,
)::PositionSize
    confidence = Float64(confidence)
    price = Float64(price)
    account_balance = Float64(account_balance)
    payoff_ratio = Float64(payoff_ratio)
    kelly_scalar = Float64(kelly_scalar)

    if price <= 0.0 || account_balance <= 0.0
        return PositionSize(0.0, 0.0, confidence, risk_tier(confidence), 0.0)
    end

    p = clamp(confidence, 0.0, 1.0)
    b = max(payoff_ratio, 1e-9)
    q = 1.0 - p
    full_k = (p * b - q) / b
    k = clamp(full_k * kelly_scalar, 0.0, 1.0)

    units = (k * account_balance) / price
    risk_pct = (units * price) / account_balance * 100.0

    return PositionSize(units, k, confidence, risk_tier(confidence), risk_pct)
end
