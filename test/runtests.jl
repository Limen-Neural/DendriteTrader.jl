# SPDX-License-Identifier: MIT OR Apache-2.0

using Test
using DendriteTrader

@testset "DendriteTrader" begin
    @testset "TradeSignal" begin
        d = Dict(
            "ticker"=>"MARKET-A",
            "side"=>"BUY",
            "price"=>100.0,
            "quantity"=>1.0,
            "confidence"=>0.9,
            "timestamp_ns"=>0,
        )
        s = TradeSignal(d)
        @test s.ticker == "MARKET-A"
        @test s.side == Buy
        @test s.confidence ≈ 0.9f0
        @test passes_gate(s, 0.85f0)
        @test !passes_gate(s, 0.95f0)
    end

    @testset "validate_signal" begin
        # Helper: valid signal dict
        valid = Dict(
            "ticker" => "MARKET-A",
            "side" => "BUY",
            "price" => 100.0,
            "quantity" => 1.0,
            "confidence" => 0.9,
            "timestamp_ns" => 1_000,
        )

        # Valid signal returns nothing
        @test validate_signal(valid) === nothing

        # Zero timestamp is rejected (contract: timestamp_ns > 0)
        zero_ts = copy(valid); zero_ts["timestamp_ns"] = 0
        res = validate_signal(zero_ts)
        @test res isa String && occursin("timestamp", res)

        # Missing each required field returns error
        for field in ("ticker", "side", "price", "confidence", "timestamp_ns")
            d = copy(valid)
            delete!(d, field)
            res = validate_signal(d)
            @test res isa String && occursin(field, res)
        end

        # Empty ticker returns error
        empty_ticker = copy(valid); empty_ticker["ticker"] = ""
        res = validate_signal(empty_ticker)
        @test res isa String && occursin("ticker", res)

        # Invalid side returns error
        for bad_side in ("hold", "Buy", "", "BUY SELL")
            d = copy(valid); d["side"] = bad_side
            r = validate_signal(d)
            @test r isa String && occursin("side", r)
        end

        # Negative price returns error
        neg_price = copy(valid); neg_price["price"] = -1.0
        res = validate_signal(neg_price)
        @test res isa String && occursin("price", res)

        # Zero price returns error
        zero_price = copy(valid); zero_price["price"] = 0.0
        res = validate_signal(zero_price)
        @test res isa String && occursin("price", res)

        # Confidence out of range returns error
        for bad_conf in (-0.1, 1.1, -1.0, 2.0)
            d = copy(valid); d["confidence"] = bad_conf
            res = validate_signal(d)
            @test res isa String && occursin("confidence", res)
        end

        # Boundary confidence values are accepted
        for edge_conf in (0.0, 1.0)
            d = copy(valid); d["confidence"] = edge_conf
            @test validate_signal(d) === nothing
        end

        # Bool rejected for price
        bool_price = copy(valid); bool_price["price"] = true
        res = validate_signal(bool_price)
        @test res isa String && occursin("number", res)

        # Bool rejected for confidence
        bool_conf = copy(valid); bool_conf["confidence"] = false
        res = validate_signal(bool_conf)
        @test res isa String && occursin("number", res)

        # Bool rejected for timestamp
        bool_ts = copy(valid); bool_ts["timestamp_ns"] = true
        res = validate_signal(bool_ts)
        @test res isa String && occursin("integer", res)

        # NaN rejected for price
        nan_price = copy(valid); nan_price["price"] = NaN
        res = validate_signal(nan_price)
        @test res isa String && occursin("finite", res)

        # Inf rejected for price
        inf_price = copy(valid); inf_price["price"] = Inf
        res = validate_signal(inf_price)
        @test res isa String && occursin("finite", res)

        # NaN rejected for confidence
        nan_conf = copy(valid); nan_conf["confidence"] = NaN
        res = validate_signal(nan_conf)
        @test res isa String && occursin("finite", res)

        # Inf rejected for confidence
        inf_conf = copy(valid); inf_conf["confidence"] = Inf
        res = validate_signal(inf_conf)
        @test res isa String && occursin("finite", res)

        # Negative timestamp returns error
        neg_ts = copy(valid); neg_ts["timestamp_ns"] = -1
        res = validate_signal(neg_ts)
        @test res isa String && occursin("timestamp", res)
    end

    @testset "ExecutionEngine — confidence gate" begin
        engine = ExecutionEngine(confidence_threshold = 0.85f0)

        # Signal above threshold → executed
        sig_hi = TradeSignal(
            Dict(
                "ticker"=>"MARKET-B",
                "side"=>"BUY",
                "price"=>90.0,
                "quantity"=>1.0,
                "confidence"=>0.90,
                "timestamp_ns"=>0,
            ),
        )
        dec = execute_signal!(engine, sig_hi, 10_000.0)
        @test dec.executed
        @test dec.position_units > 0.0
        @test dec.kelly_fraction > 0.0
        @test dec.applied_fraction > 0.0

        # Signal below threshold → rejected
        sig_lo = TradeSignal(
            Dict(
                "ticker"=>"MARKET-B",
                "side"=>"BUY",
                "price"=>90.0,
                "quantity"=>1.0,
                "confidence"=>0.70,
                "timestamp_ns"=>0,
            ),
        )
        dec_lo = execute_signal!(engine, sig_lo, 10_000.0)
        @test !dec_lo.executed
    end

    @testset "ExecutionEngine — position tracking" begin
        engine = ExecutionEngine()
        sig = TradeSignal(
            Dict(
                "ticker"=>"MARKET-C",
                "side"=>"BUY",
                "price"=>0.03,
                "quantity"=>100.0,
                "confidence"=>0.92,
                "timestamp_ns"=>0,
            ),
        )
        execute_signal!(engine, sig, 500.0)
        @test get(engine.positions, "MARKET-C", 0.0) > 0.0
    end

    @testset "fill_rate" begin
        engine = ExecutionEngine(confidence_threshold = 0.85f0)
        for conf in [0.90, 0.70, 0.88, 0.60]
            s = TradeSignal(
                Dict(
                    "ticker"=>"MARKET-A",
                    "side"=>"BUY",
                    "price"=>100.0,
                    "quantity"=>1.0,
                    "confidence"=>conf,
                    "timestamp_ns"=>0,
                ),
            )
            execute_signal!(engine, s, 10_000.0)
        end
        @test 0.0 < fill_rate(engine) < 1.0
    end

    @testset "DydxPrice" begin
        p = DydxPrice("MARKET-A", 100.0, 99.0, 101.0)
        @test mid_price(p) ≈ 100.0
        @test spread_bps(p) > 0.0
    end

    @testset "Kelly sizing" begin
        f = kelly_fraction(win_rate = 0.55, avg_win = 8.50, avg_loss = 5.20)
        @test 0.02 <= f <= 0.20
        @test f > 0.05

        f_bad = kelly_fraction(win_rate = 0.40, avg_win = 1.0, avg_loss = 2.0)
        @test f_bad == 0.0

        f_zero = kelly_fraction(win_rate = 0.0, avg_win = 1_000, avg_loss = 1)
        @test f_zero == 0.0

        f_hi = kelly_fraction(win_rate = 0.70, avg_win = 10.0, avg_loss = 5.0)
        f_lo = kelly_fraction(win_rate = 0.52, avg_win = 10.0, avg_loss = 5.0)
        @test f_hi > f_lo

        f_conf_high = from_confidence(confidence = 0.95)
        f_conf_low = from_confidence(confidence = 0.55)
        @test f_conf_high > f_conf_low
        @test 0.0 <= f_conf_low <= 1.0
        @test 0.0 <= f_conf_high <= 1.0

        hk = half_kelly(0.60, 1.5)
        @test 0.0 <= hk <= 1.0
        p, b = 0.60, 1.5
        q = 1.0 - p
        full = (p * b - q) / b
        @test half_kelly(p, b) ≈ full * 0.5 atol=1e-9

        @test risk_tier(0.97) == Aggressive
        @test risk_tier(0.90) == Moderate
        @test risk_tier(0.75) == Conservative
        @test risk_tier(0.50) == Minimal

        pos = size_position(confidence = 0.90, price = 100.0, account_balance = 10_000.0)
        @test pos.units > 0.0
        @test pos.kelly_fraction > 0.0
        @test pos.risk == Moderate
        @test 0.0 < pos.account_risk_pct < 100.0

        pos_from_ints = size_position(confidence = 0.90f0, price = 100, account_balance = 10_000)
        @test pos_from_ints.units > 0.0

        pos_hi = size_position(confidence = 0.95, price = 100.0, account_balance = 10_000.0)
        pos_lo = size_position(confidence = 0.72, price = 100.0, account_balance = 10_000.0)
        @test pos_hi.units >= pos_lo.units

        @test size_position(confidence = 0.90, price = 0.0, account_balance = 10_000.0).units == 0.0
        @test size_position(confidence = 0.90, price = 100.0, account_balance = -1.0).units == 0.0
    end

    @testset "ExecutionEngine — zero-sized rejection and capped units" begin
        engine = ExecutionEngine(max_position_size = 10.0)
        sig = TradeSignal(
            Dict(
                "ticker"=>"MARKET-D",
                "side"=>"BUY",
                "price"=>90.0,
                "quantity"=>1.0,
                "confidence"=>0.90,
                "timestamp_ns"=>0,
            ),
        )
        dec = execute_signal!(engine, sig, 10_000.0)
        @test dec.executed
        @test dec.position_units == 10.0
        k_model = size_position(
            confidence = Float64(sig.confidence),
            price = 90.0,
            account_balance = 10_000.0,
            payoff_ratio = engine.payoff_ratio,
        ).kelly_fraction
        @test dec.kelly_fraction ≈ k_model
        @test dec.kelly_fraction > dec.applied_fraction
        @test dec.applied_fraction ≈ 0.09

        zero_dec = execute_signal!(engine, sig, 0.0)
        @test !zero_dec.executed
        @test zero_dec.reason == "zero-sized position"
    end
end

# Integration tests (gated behind DYDX_INTEGRATION=true)
include("integration/test_dydx.jl")
