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

    @testset "PriceCache" begin
        @testset "constructor with default TTL" begin
            cache = PriceCache()
            @test cache.ttl_s == 5.0
            @test cache_size(cache) == 0
        end

        @testset "constructor with custom TTL" begin
            cache = PriceCache(ttl_s = 10.0)
            @test cache.ttl_s == 10.0
        end

        @testset "put_cached! stores entry" begin
            cache = PriceCache()
            price = DydxPrice("BTC-USD", 50000.0, 49999.0, 50001.0)
            put_cached!(cache, "BTC-USD", price)
            @test cache_size(cache) == 1
        end

        @testset "get_cached returns fresh entry" begin
            cache = PriceCache()
            price = DydxPrice("ETH-USD", 3000.0, 2999.0, 3001.0)
            put_cached!(cache, "ETH-USD", price)
            result = get_cached(cache, "ETH-USD")
            @test result !== nothing
            @test result.ticker == "ETH-USD"
            @test result.oracle_price ≈ 3000.0
        end

        @testset "get_cached returns nothing for expired entry" begin
            cache = PriceCache(ttl_s = 5.0)
            price = DydxPrice("SOL-USD", 100.0, 99.0, 101.0)
            put_cached!(cache, "SOL-USD", price)
            # Deterministic expiry: backdate the stored timestamp (no sleep)
            lock(cache.lock) do
                cache.times["SOL-USD"] = time() - 10.0
            end
            @test get_cached(cache, "SOL-USD") === nothing
            # get_cached lazily evicts expired entries
            @test cache_size(cache) == 0
        end

        @testset "get_cached returns nothing for missing ticker" begin
            cache = PriceCache()
            @test get_cached(cache, "MISSING") === nothing
        end

        @testset "invalidate! removes specific entry" begin
            cache = PriceCache()
            put_cached!(cache, "BTC-USD", DydxPrice("BTC-USD", 50000.0, 49999.0, 50001.0))
            put_cached!(cache, "ETH-USD", DydxPrice("ETH-USD", 3000.0, 2999.0, 3001.0))
            @test cache_size(cache) == 2
            invalidate!(cache, "BTC-USD")
            @test cache_size(cache) == 1
            @test get_cached(cache, "BTC-USD") === nothing
            @test get_cached(cache, "ETH-USD") !== nothing
        end

        @testset "invalidate! on missing ticker is a no-op" begin
            cache = PriceCache()
            invalidate!(cache, "MISSING")
            @test cache_size(cache) == 0
        end

        @testset "clear! removes all entries" begin
            cache = PriceCache()
            put_cached!(cache, "BTC-USD", DydxPrice("BTC-USD", 50000.0, 49999.0, 50001.0))
            put_cached!(cache, "ETH-USD", DydxPrice("ETH-USD", 3000.0, 2999.0, 3001.0))
            put_cached!(cache, "SOL-USD", DydxPrice("SOL-USD", 100.0, 99.0, 101.0))
            @test cache_size(cache) == 3
            clear!(cache)
            @test cache_size(cache) == 0
            @test get_cached(cache, "BTC-USD") === nothing
            @test get_cached(cache, "ETH-USD") === nothing
            @test get_cached(cache, "SOL-USD") === nothing
        end

        @testset "clear! on empty cache is a no-op" begin
            cache = PriceCache()
            clear!(cache)
            @test cache_size(cache) == 0
        end

        @testset "cache_size returns correct count" begin
            cache = PriceCache()
            @test cache_size(cache) == 0
            put_cached!(cache, "A", DydxPrice("A", 1.0, 0.9, 1.1))
            @test cache_size(cache) == 1
            put_cached!(cache, "B", DydxPrice("B", 2.0, 1.9, 2.1))
            @test cache_size(cache) == 2
            put_cached!(cache, "A", DydxPrice("A", 1.5, 1.4, 1.6))
            @test cache_size(cache) == 2
        end
    end
end

# Integration tests (gated behind DYDX_INTEGRATION=true)
include("integration/test_dydx.jl")
