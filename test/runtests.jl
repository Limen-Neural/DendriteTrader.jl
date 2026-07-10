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

        # Signal above threshold -> executed
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

        # Signal below threshold -> rejected
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
            @test cfg.risk_free_rate == 0.0
        end

        @testset "BacktestConfig four-argument positional constructor" begin
            cfg = BacktestConfig(50_000.0, 0.90, 2.0, 20.0)
            @test cfg.initial_balance == 50_000.0
            @test cfg.confidence_threshold == Float32(0.90)
            @test cfg.payoff_ratio == 2.0
            @test cfg.max_position_size == 20.0
            @test cfg.risk_free_rate == 0.0
            @test cfg.slippage_pct == 0.0
            @test cfg.commission_pct == 0.0
        end

        @testset "BacktestConfig non-default fields" begin
            cfg = BacktestConfig(
                initial_balance = 50_000.0,
                confidence_threshold = 0.90,
                payoff_ratio = 2.0,
                max_position_size = 20.0,
                risk_free_rate = 0.05,
                slippage_pct = 0.1,
                commission_pct = 0.05,
            )
            @test cfg.risk_free_rate == 0.05
            @test cfg.slippage_pct == 0.1
            @test cfg.commission_pct == 0.05
            # Run a backtest with non-default config to verify end-to-end
            signals = [
                TradeSignal(Dict("ticker" => "X", "side" => "BUY", "price" => 100.0,
                    "quantity" => 1.0, "confidence" => 0.95, "timestamp_ns" => 1_000_000_000)),
                TradeSignal(Dict("ticker" => "X", "side" => "SELL", "price" => 110.0,
                    "quantity" => 1.0, "confidence" => 0.95, "timestamp_ns" => 2_000_000_000)),
            ]
            result = run_backtest(cfg, signals)
            @test result.config.risk_free_rate == 0.05
            @test result.config.slippage_pct == 0.1
            @test result.config.commission_pct == 0.05
            @test isfinite(result.sharpe_ratio)
            @test isfinite(result.sortino_ratio)
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
            # Buy-only: no closed trades
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

        @testset "compute_max_drawdown" begin
            mdd = DendriteTrader.Backtest.compute_max_drawdown
            @test mdd([100.0, 100.0, 100.0]) == 0.0
            @test mdd([100.0]) == 0.0
            @test mdd([100.0, 110.0, 88.0]) ≈ 20.0 atol=0.01
            @test mdd([100.0, 120.0, 90.0, 130.0]) ≈ 25.0 atol=0.01
        end

        @testset "compute_period_returns" begin
            cpr = DendriteTrader.Backtest.compute_period_returns
            @test cpr([100.0]) == Float64[]
            @test cpr([100.0, 110.0]) ≈ [0.1]
            r = cpr([100.0, 110.0, 104.5])
            @test r[1] ≈ 0.1
            @test r[2] ≈ -0.05
        end

        @testset "compute_sharpe_ratio" begin
            sharpe = DendriteTrader.Backtest.compute_sharpe_ratio
            # n_days = length(returns) -> spd=1, no scaling
            @test sharpe([0.01], 0.0, 1, false) == 0.0
            @test sharpe([0.01, 0.01, 0.01], 0.0, 3, false) == 0.0
            r = [0.01, 0.02, -0.005, 0.015, 0.008]
            s = sharpe(r, 0.0, 5, false)
            @test s > 0.0
            # Assert exact value: mean/std * sqrt(252)
            n = length(r)
            mean_r = sum(r) / n
            std_r = sqrt(sum((x - mean_r)^2 for x in r) / (n - 1))
            expected = mean_r / std_r * sqrt(252.0)
            @test s ≈ expected atol=0.01
            s_low = sharpe(r, 0.005, 5, false)
            @test s_low < s
        end

        @testset "compute_sortino_ratio" begin
            sortino = DendriteTrader.Backtest.compute_sortino_ratio
            @test sortino([0.01], 0.0, 1, false) == 0.0
            @test sortino([0.01, 0.02, 0.03], 0.0, 3, false) == 0.0
            r = [0.02, -0.01, 0.03, -0.005, 0.01]
            s = sortino(r, 0.0, 5, false)
            @test s > 0.0
            # Assert exact value: mean_excess / downside_dev * sqrt(252)
            n = length(r)
            mean_r = sum(r) / n
            downside_sum = sum(min(x, 0.0)^2 for x in r)
            downside_dev = sqrt(downside_sum / (n - 1))
            expected = mean_r / downside_dev * sqrt(252.0)
            @test s ≈ expected atol=0.01
            sharpe = DendriteTrader.Backtest.compute_sharpe_ratio
            @test s >= sharpe(r, 0.0, 5, false) - 1e-9
        end

        @testset "compute_calmar_ratio" begin
            calmar = DendriteTrader.Backtest.compute_calmar_ratio
            @test calmar(50.0, 0.0, 252, false) == 0.0
            c = calmar(20.0, 10.0, 252, false)
            # annualized = (1.2)^(252/252) - 1 = 0.2; calmar = 0.2/0.1 = 2.0
            @test c ≈ 2.0 atol=0.01
            @test calmar(20.0, 10.0, 0, false) == 0.0
        end

        @testset "BacktestResult includes ratio fields" begin
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
            @test hasfield(typeof(result), :sharpe_ratio)
            @test hasfield(typeof(result), :sortino_ratio)
            @test hasfield(typeof(result), :calmar_ratio)
            @test isfinite(result.sharpe_ratio)
            @test isfinite(result.sortino_ratio)
            @test isfinite(result.calmar_ratio)
        end

        @testset "calmar handles wipeout without DomainError" begin
            calmar = DendriteTrader.Backtest.compute_calmar_ratio
            @test calmar(-100.0, 50.0, 10, false) == 0.0
            @test calmar(-150.0, 50.0, 10, false) == 0.0
            @test isfinite(calmar(-99.0, 50.0, 10, false))
        end

        @testset "sortino uses sample (N-1) downside deviation like Sharpe" begin
            sortino = DendriteTrader.Backtest.compute_sortino_ratio
            sharpe = DendriteTrader.Backtest.compute_sharpe_ratio
            r = [0.02, -0.01, 0.03, -0.005, 0.01]
            s = sortino(r, 0.0, 5, false)
            @test isfinite(s)
            @test s > 0.0
            @test s >= sharpe(r, 0.0, 5, false) - 1e-9
        end

        @testset "risk_free_rate < -1 does not throw" begin
            sharpe = DendriteTrader.Backtest.compute_sharpe_ratio
            sortino = DendriteTrader.Backtest.compute_sortino_ratio
            r = [0.01, -0.02, 0.015]
            @test isfinite(sharpe(r, -1.5, 3, false))
            @test isfinite(sortino(r, -1.5, 3, false))
        end

        @testset "estimate_n_periods uses calendar days when span >= 1 day" begin
            est = DendriteTrader.Backtest.estimate_n_periods
            day_ns = Int64(86_400) * Int64(1_000_000_000)
            sigs = [
                TradeSignal(Dict(
                    "ticker" => "BTC-USD", "side" => "BUY", "price" => 100.0,
                    "quantity" => 1.0, "confidence" => 0.9, "timestamp_ns" => 0,
                )),
                TradeSignal(Dict(
                    "ticker" => "BTC-USD", "side" => "SELL", "price" => 110.0,
                    "quantity" => 1.0, "confidence" => 0.9, "timestamp_ns" => 10 * day_ns,
                )),
            ]
            n, is_cal = est(sigs, 100)
            @test n == 10
            @test is_cal == true
            # Sub-day span falls back to return count
            sigs_short = [
                TradeSignal(Dict(
                    "ticker" => "BTC-USD", "side" => "BUY", "price" => 100.0,
                    "quantity" => 1.0, "confidence" => 0.9, "timestamp_ns" => 0,
                )),
                TradeSignal(Dict(
                    "ticker" => "BTC-USD", "side" => "SELL", "price" => 110.0,
                    "quantity" => 1.0, "confidence" => 0.9, "timestamp_ns" => 1_000_000_000,
                )),
            ]
            n2, is_cal2 = est(sigs_short, 5)
            @test n2 == 5
            @test is_cal2 == false
        end

        @testset "total_trades counts closed round-trips only" begin
            cfg = BacktestConfig(initial_balance = 10_000.0)
            signals = [
                TradeSignal(Dict("ticker" => "A", "side" => "BUY", "price" => 100.0,
                    "quantity" => 1.0, "confidence" => 0.92, "timestamp_ns" => 1_000_000_000)),
                TradeSignal(Dict("ticker" => "A", "side" => "SELL", "price" => 110.0,
                    "quantity" => 1.0, "confidence" => 0.90, "timestamp_ns" => 2_000_000_000)),
                TradeSignal(Dict("ticker" => "B", "side" => "SELL", "price" => 100.0,
                    "quantity" => 1.0, "confidence" => 0.92, "timestamp_ns" => 3_000_000_000)),
                TradeSignal(Dict("ticker" => "B", "side" => "BUY", "price" => 90.0,
                    "quantity" => 1.0, "confidence" => 0.90, "timestamp_ns" => 4_000_000_000)),
            ]
            result = run_backtest(cfg, signals)
            # Both round-trips have non-zero PnL -> both counted
            @test result.total_trades == 2
        end

        @testset "same-side re-entry accumulates position" begin
            cfg = BacktestConfig(initial_balance = 10_000.0, max_position_size = 1000.0)
            signals = [
                TradeSignal(Dict("ticker" => "BTC-USD", "side" => "BUY", "price" => 100.0,
                    "quantity" => 1.0, "confidence" => 0.99, "timestamp_ns" => 1_000_000_000)),
                TradeSignal(Dict("ticker" => "BTC-USD", "side" => "BUY", "price" => 110.0,
                    "quantity" => 1.0, "confidence" => 0.99, "timestamp_ns" => 2_000_000_000)),
                TradeSignal(Dict("ticker" => "BTC-USD", "side" => "SELL", "price" => 120.0,
                    "quantity" => 1.0, "confidence" => 0.90, "timestamp_ns" => 3_000_000_000)),
            ]
            result = run_backtest(cfg, signals)
            closed = filter(t -> t.pnl != 0.0, result.trade_log)
            @test length(closed) == 1
            @test closed[1].price ≈ 120.0 atol=1e-9
            # Close should carry accumulated units from both entries, not just the last fill
            fills = filter(t -> t.pnl == 0.0, result.trade_log)
            @test length(fills) == 1
            @test closed[1].units > fills[1].units
        end

        @testset "calmar uses 365 for calendar days" begin
            calmar = DendriteTrader.Backtest.compute_calmar_ratio
            # With calendar days (365), 1-year return should annualize cleanly
            c = calmar(20.0, 10.0, 365, true)
            # annualized = (1.2)^(365/365) - 1 = 0.2; calmar = 0.2/0.1 = 2.0
            @test c ≈ 2.0 atol=0.01
        end

        @testset "estimate_n_periods handles unsorted signals" begin
            est = DendriteTrader.Backtest.estimate_n_periods
            day_ns = Int64(86_400) * Int64(1_000_000_000)
            # Signals in reverse order — should use min/max
            sigs = [
                TradeSignal(Dict(
                    "ticker" => "BTC-USD", "side" => "SELL", "price" => 110.0,
                    "quantity" => 1.0, "confidence" => 0.9, "timestamp_ns" => 10 * day_ns,
                )),
                TradeSignal(Dict(
                    "ticker" => "BTC-USD", "side" => "BUY", "price" => 100.0,
                    "quantity" => 1.0, "confidence" => 0.9, "timestamp_ns" => 0,
                )),
            ]
            n, is_cal = est(sigs, 100)
            @test n == 10
            @test is_cal == true
        end

        @testset "final_balance uses MTM equity" begin
            cfg = BacktestConfig(initial_balance = 10_000.0)
            signals = [
                TradeSignal(Dict(
                    "ticker" => "BTC-USD", "side" => "BUY", "price" => 100.0,
                    "quantity" => 1.0, "confidence" => 0.92, "timestamp_ns" => 1_000_000_000,
                )),
                # Non-executed signal moves the mark price to 110
                TradeSignal(Dict(
                    "ticker" => "BTC-USD", "side" => "BUY", "price" => 110.0,
                    "quantity" => 1.0, "confidence" => 0.50, "timestamp_ns" => 2_000_000_000,
                )),
            ]
            result = run_backtest(cfg, signals)
            # Open position: entry at 100, mark at 110 → unrealized PnL > 0
            @test result.final_balance > cfg.initial_balance
            @test result.total_return > 0.0
        end

        @testset "same-side re-entry recorded in trade_log" begin
            cfg = BacktestConfig(initial_balance = 10_000.0, max_position_size = 1000.0)
            signals = [
                TradeSignal(Dict("ticker" => "BTC-USD", "side" => "BUY", "price" => 100.0,
                    "quantity" => 1.0, "confidence" => 0.99, "timestamp_ns" => 1_000_000_000)),
                TradeSignal(Dict("ticker" => "BTC-USD", "side" => "BUY", "price" => 110.0,
                    "quantity" => 1.0, "confidence" => 0.99, "timestamp_ns" => 2_000_000_000)),
                TradeSignal(Dict("ticker" => "BTC-USD", "side" => "SELL", "price" => 120.0,
                    "quantity" => 1.0, "confidence" => 0.90, "timestamp_ns" => 3_000_000_000)),
            ]
            result = run_backtest(cfg, signals)
            # Same-side fill + close = 2 trade_log entries
            @test length(result.trade_log) == 2
            @test result.trade_log[1].pnl == 0.0  # same-side fill
            @test result.trade_log[2].pnl > 0.0   # close
            closed = filter(t -> t.pnl != 0.0, result.trade_log)
            @test length(closed) == 1
            @test closed[1].price ≈ 120.0 atol=1e-9
        end

        @testset "short round-trip counted once in total_trades" begin
            cfg = BacktestConfig(initial_balance = 10_000.0)
            signals = [
                TradeSignal(Dict("ticker" => "A", "side" => "SELL", "price" => 100.0,
                    "quantity" => 1.0, "confidence" => 0.92, "timestamp_ns" => 1_000_000_000)),
                TradeSignal(Dict("ticker" => "A", "side" => "BUY", "price" => 90.0,
                    "quantity" => 1.0, "confidence" => 0.90, "timestamp_ns" => 2_000_000_000)),
            ]
            result = run_backtest(cfg, signals)
            # Short open no longer logged; only the cover close is in trade_log
            @test result.total_trades == 1
            @test result.trade_log[1].pnl > 0.0  # short profit
        end

        @testset "flat close counts as completed trade" begin
            # BUY then SELL at same price with zero costs → pnl == 0, still a round-trip
            cfg = BacktestConfig(
                initial_balance = 10_000.0,
                slippage_pct = 0.0,
                commission_pct = 0.0,
            )
            signals = [
                TradeSignal(Dict("ticker" => "A", "side" => "BUY", "price" => 100.0,
                    "quantity" => 1.0, "confidence" => 0.95, "timestamp_ns" => 1_000_000_000)),
                TradeSignal(Dict("ticker" => "A", "side" => "SELL", "price" => 100.0,
                    "quantity" => 1.0, "confidence" => 0.95, "timestamp_ns" => 2_000_000_000)),
            ]
            result = run_backtest(cfg, signals)
            @test result.total_trades == 1
            @test length(result.trade_log) == 1
            @test result.trade_log[1].pnl == 0.0
            @test result.win_rate == 0.0  # flat is not a win
        end

        @testset "position cap uses actual_new_units for commission and entry" begin
            # Small max_position_size so same-side re-entry hits the cap
            cfg = BacktestConfig(
                initial_balance = 10_000.0,
                max_position_size = 1.0,
                commission_pct = 1.0,  # 1% so commission is observable
                slippage_pct = 0.0,
            )
            signals = [
                TradeSignal(Dict("ticker" => "BTC-USD", "side" => "BUY", "price" => 100.0,
                    "quantity" => 1.0, "confidence" => 0.99, "timestamp_ns" => 1_000_000_000)),
                # Same-side: would add more units but must cap at max_position_size
                TradeSignal(Dict("ticker" => "BTC-USD", "side" => "BUY", "price" => 200.0,
                    "quantity" => 1.0, "confidence" => 0.99, "timestamp_ns" => 2_000_000_000)),
                TradeSignal(Dict("ticker" => "BTC-USD", "side" => "SELL", "price" => 200.0,
                    "quantity" => 1.0, "confidence" => 0.99, "timestamp_ns" => 3_000_000_000)),
            ]
            result = run_backtest(cfg, signals)
            # Same-side fill + close
            @test length(result.trade_log) == 2
            same_side = result.trade_log[1]
            close_rec = result.trade_log[2]
            # Units actually added on re-entry must not exceed remaining room
            @test same_side.units >= 0.0
            @test same_side.units <= 1.0
            # Close units = position size after cap, never above max
            @test close_rec.units <= 1.0 + 1e-12
            # If already at/near cap after first fill, same-side adds ~0 and charges ~0
            # Entry commission on zero added units must not inflate close costs incorrectly
            @test isfinite(close_rec.pnl)
        end

        @testset "BacktestResult 10-arg constructor accepts Real integers" begin
            cfg = BacktestConfig()
            # Integer literals must convert (old generated constructor accepted convertibles)
            r = DendriteTrader.Backtest.BacktestResult(
                cfg,
                10_000,          # Int initial_balance
                11_000,          # Int final_balance
                Float64[10_000.0, 11_000.0],
                DendriteTrader.Backtest.TradeRecord[],
                DendriteTrader.SignalEvent[],
                10,              # Int total_return
                5,               # Int max_drawdown
                1,               # Int win_rate (will convert to 1.0)
                2,               # Int total_trades
            )
            @test r.initial_balance == 10_000.0
            @test r.final_balance == 11_000.0
            @test r.total_return == 10.0
            @test r.max_drawdown == 5.0
            @test r.win_rate == 1.0
            @test r.total_trades == 2
            @test r.sharpe_ratio == 0.0
            @test r.sortino_ratio == 0.0
            @test r.calmar_ratio == 0.0
        end

        @testset "compute_sharpe_ratio with per-signal risk-free" begin
            sharpe = DendriteTrader.Backtest.compute_sharpe_ratio
            r = [0.01, 0.02, -0.005, 0.015, 0.008]
            s = sharpe(r, 0.0, 5, false)
            @test s > 0.0
            @test isfinite(s)
            s_low = sharpe(r, 0.005, 5, false)
            @test s_low < s
        end

        @testset "compute_sortino_ratio consistent with Sharpe" begin
            sortino = DendriteTrader.Backtest.compute_sortino_ratio
            sharpe = DendriteTrader.Backtest.compute_sharpe_ratio
            r = [0.02, -0.01, 0.03, -0.005, 0.01]
            s = sortino(r, 0.0, 5, false)
            @test isfinite(s)
            @test s > 0.0
            @test s >= sharpe(r, 0.0, 5, false) - 1e-9
        end
    end
end

# Integration tests (gated behind DYDX_INTEGRATION=true)
include("integration/test_dydx.jl")
