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

    @testset "Backtest" begin
        @testset "BacktestConfig constructor with defaults" begin
            cfg = BacktestConfig()
            @test cfg.initial_balance == 10_000.0
            @test cfg.confidence_threshold == Float32(0.85)
            @test cfg.payoff_ratio == 1.5
            @test cfg.max_position_size == 10.0
            @test cfg.slippage_pct == 0.0
            @test cfg.commission_pct == 0.0
        end

        @testset "BacktestConfig constructor with custom values" begin
            cfg = BacktestConfig(
                initial_balance = 50_000.0,
                confidence_threshold = Float32(0.90),
                payoff_ratio = 2.0,
                max_position_size = 20.0,
                slippage_pct = 0.05,
                commission_pct = 0.1,
            )
            @test cfg.initial_balance == 50_000.0
            @test cfg.confidence_threshold == Float32(0.90)
            @test cfg.payoff_ratio == 2.0
            @test cfg.max_position_size == 20.0
            @test cfg.slippage_pct == 0.05
            @test cfg.commission_pct == 0.1
        end

        @testset "run_backtest with buy signals — equity curve changes" begin
            cfg = BacktestConfig(initial_balance = 10_000.0)
            signals = [
                TradeSignal(Dict(
                    "ticker" => "BTC-USD",
                    "side" => "BUY",
                    "price" => 100.0,
                    "quantity" => 1.0,
                    "confidence" => 0.92,
                    "timestamp_ns" => 1_000_000_000,
                )),
                TradeSignal(Dict(
                    "ticker" => "ETH-USD",
                    "side" => "BUY",
                    "price" => 50.0,
                    "quantity" => 1.0,
                    "confidence" => 0.90,
                    "timestamp_ns" => 2_000_000_000,
                )),
            ]
            result = run_backtest(cfg, signals)
            @test length(result.equity_curve) == 3  # initial + 2 signals
            @test result.equity_curve[1] == 10_000.0
            # Buy-only: no trades recorded until a sell closes the position
            @test result.total_trades == 0
            @test result.final_balance == cfg.initial_balance
        end

        @testset "run_backtest with buy+sell — PnL computed" begin
            cfg = BacktestConfig(initial_balance = 10_000.0)
            signals = [
                TradeSignal(Dict(
                    "ticker" => "BTC-USD",
                    "side" => "BUY",
                    "price" => 100.0,
                    "quantity" => 1.0,
                    "confidence" => 0.92,
                    "timestamp_ns" => 1_000_000_000,
                )),
                TradeSignal(Dict(
                    "ticker" => "BTC-USD",
                    "side" => "SELL",
                    "price" => 110.0,
                    "quantity" => 1.0,
                    "confidence" => 0.90,
                    "timestamp_ns" => 2_000_000_000,
                )),
            ]
            result = run_backtest(cfg, signals)
            @test result.final_balance != cfg.initial_balance
            @test result.total_return != 0.0
            closed = filter(t -> t.pnl != 0.0, result.trade_log)
            @test length(closed) >= 1
            @test closed[1].pnl > 0.0  # bought at 100, sold at 110
        end

        @testset "run_backtest with neutral signals — no trades" begin
            cfg = BacktestConfig(initial_balance = 10_000.0)
            signals = [
                TradeSignal(Dict(
                    "ticker" => "BTC-USD",
                    "side" => "NEUTRAL",
                    "price" => 100.0,
                    "quantity" => 1.0,
                    "confidence" => 0.92,
                    "timestamp_ns" => 1_000_000_000,
                )),
            ]
            result = run_backtest(cfg, signals)
            @test result.total_trades == 0
            @test result.final_balance == cfg.initial_balance
            @test result.equity_curve == [10_000.0, 10_000.0]
        end

        @testset "run_backtest with slippage — execution price adjusted" begin
            cfg = BacktestConfig(
                initial_balance = 10_000.0,
                slippage_pct = 0.5,  # 0.5% slippage
            )
            signals = [
                TradeSignal(Dict(
                    "ticker" => "BTC-USD",
                    "side" => "BUY",
                    "price" => 100.0,
                    "quantity" => 1.0,
                    "confidence" => 0.92,
                    "timestamp_ns" => 1_000_000_000,
                )),
                TradeSignal(Dict(
                    "ticker" => "BTC-USD",
                    "side" => "SELL",
                    "price" => 110.0,
                    "quantity" => 1.0,
                    "confidence" => 0.90,
                    "timestamp_ns" => 2_000_000_000,
                )),
            ]
            result = run_backtest(cfg, signals)
            # With 0.5% slippage, sell price = 110 * (1 - 0.5/100) = 109.45
            # Buy price stored as 100 * (1 + 0.5/100) = 100.5
            # PnL = (109.45 - 100.5) * units — should be positive but less than without slippage
            @test result.total_trades == 1
            @test result.trade_log[1].price ≈ 109.45 atol=0.01
            # Final balance should differ from no-slippage case
            cfg_noslip = BacktestConfig(initial_balance = 10_000.0)
            result_noslip = run_backtest(cfg_noslip, signals)
            @test result.final_balance < result_noslip.final_balance
        end

        @testset "run_backtest with commission — balance reduced" begin
            cfg = BacktestConfig(
                initial_balance = 10_000.0,
                commission_pct = 0.1,  # 0.1% commission
            )
            signals = [
                TradeSignal(Dict(
                    "ticker" => "BTC-USD",
                    "side" => "BUY",
                    "price" => 100.0,
                    "quantity" => 1.0,
                    "confidence" => 0.92,
                    "timestamp_ns" => 1_000_000_000,
                )),
            ]
            result = run_backtest(cfg, signals)
            # Commission should reduce balance: units * price * 0.1%
            @test result.final_balance < cfg.initial_balance
        end

        @testset "run_backtest with slippage and commission combined" begin
            cfg = BacktestConfig(
                initial_balance = 10_000.0,
                slippage_pct = 0.5,
                commission_pct = 0.1,
            )
            signals = [
                TradeSignal(Dict(
                    "ticker" => "BTC-USD",
                    "side" => "BUY",
                    "price" => 100.0,
                    "quantity" => 1.0,
                    "confidence" => 0.92,
                    "timestamp_ns" => 1_000_000_000,
                )),
                TradeSignal(Dict(
                    "ticker" => "BTC-USD",
                    "side" => "SELL",
                    "price" => 110.0,
                    "quantity" => 1.0,
                    "confidence" => 0.90,
                    "timestamp_ns" => 2_000_000_000,
                )),
            ]
            result = run_backtest(cfg, signals)
            # trade_log has the sell trade only (buy-only doesn't create trade records)
            # Sell with 0.5% slippage: 110 * (1 - 0.5/100) = 109.45
            @test result.trade_log[1].price ≈ 109.45 atol=0.01
            # Commission applied on both buy and sell, so balance should be reduced
            @test result.final_balance != cfg.initial_balance
        end

        @testset "print_summary — no errors" begin
            cfg = BacktestConfig()
            signals = [
                TradeSignal(Dict(
                    "ticker" => "BTC-USD",
                    "side" => "BUY",
                    "price" => 100.0,
                    "quantity" => 1.0,
                    "confidence" => 0.92,
                    "timestamp_ns" => 1_000_000_000,
                )),
            ]
            result = run_backtest(cfg, signals)
            @test_nowarn print_summary(result)
        end

        @testset "format_currency" begin
            fmt = DendriteTrader.Backtest.format_currency
            @test fmt(1234.56) == "1,234.56"
            @test fmt(-5000.10) == "-5,000.10"
            @test fmt(0.0) == "0.00"
            @test fmt(1_000_000.00) == "1,000,000.00"
        end

        @testset "compute_max_drawdown" begin
            mdd = DendriteTrader.Backtest.compute_max_drawdown
            # Flat curve → no drawdown
            @test mdd([100.0, 100.0, 100.0]) == 0.0
            # Single element → 0
            @test mdd([100.0]) == 0.0
            # Dip from 100 to 80 → 20% drawdown
            @test mdd([100.0, 110.0, 88.0]) ≈ 20.0 atol=0.01
            # Recover after dip
            @test mdd([100.0, 120.0, 90.0, 130.0]) ≈ 25.0 atol=0.01
        end

        @testset "close PnL uses open units not exit Kelly size" begin
            cfg = BacktestConfig(initial_balance = 10_000.0, max_position_size = 1000.0)
            signals = [
                TradeSignal(Dict(
                    "ticker" => "BTC-USD",
                    "side" => "BUY",
                    "price" => 100.0,
                    "quantity" => 1.0,
                    "confidence" => 0.99,
                    "timestamp_ns" => 1_000_000_000,
                )),
                TradeSignal(Dict(
                    "ticker" => "BTC-USD",
                    "side" => "SELL",
                    "price" => 110.0,
                    "quantity" => 1.0,
                    "confidence" => 0.86,
                    "timestamp_ns" => 2_000_000_000,
                )),
            ]
            result = run_backtest(cfg, signals)
            closed = filter(t -> t.pnl != 0.0, result.trade_log)
            @test length(closed) == 1
            eng = ExecutionEngine(
                confidence_threshold = Float32(0.85),
                max_position_size = 1000.0,
                payoff_ratio = 1.5,
            )
            open_dec = execute_signal!(eng, signals[1], 10_000.0)
            @test closed[1].units ≈ open_dec.position_units atol=1e-9
            @test closed[1].pnl ≈ (110.0 - 100.0) * open_dec.position_units atol=1e-6
        end

        @testset "integer kwargs coerce into BacktestConfig" begin
            cfg = BacktestConfig(initial_balance = 10_000, slippage_pct = 0, commission_pct = 0)
            @test cfg.initial_balance == 10_000.0
            @test cfg.slippage_pct == 0.0
        end

        @testset "short open sell slippage fills below mid" begin
            cfg = BacktestConfig(initial_balance = 10_000.0, slippage_pct = 1.0)
            signals = [
                TradeSignal(Dict(
                    "ticker" => "BTC-USD",
                    "side" => "SELL",
                    "price" => 100.0,
                    "quantity" => 1.0,
                    "confidence" => 0.92,
                    "timestamp_ns" => 1_000_000_000,
                )),
            ]
            result = run_backtest(cfg, signals)
            @test result.total_trades == 1
            @test result.trade_log[1].price ≈ 99.0 atol=1e-9
        end
    end
end

# Integration tests (gated behind DYDX_INTEGRATION=true)
include("integration/test_dydx.jl")
