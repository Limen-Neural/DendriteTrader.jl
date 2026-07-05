# SPDX-License-Identifier: MIT OR Apache-2.0

# dYdX v4 Integration Tests
# These tests hit the dYdX v4 testnet and are gated behind DYDX_INTEGRATION=true

using Test
using DendriteTrader

@testset "dYdX v4 Integration" begin
    if get(ENV, "DYDX_INTEGRATION", "false") != "true"
        @info "Skipping dYdX integration tests (set DYDX_INTEGRATION=true to run)"
        return
    end

    @info "Running dYdX v4 integration tests against testnet"

    client = DydxClient(
        base_url = "https://indexer.v4testnet.dydx.exchange/v4",
        timeout_s = 10.0,
    )

    @testset "DydxClient construction" begin
        @test client.base_url == "https://indexer.v4testnet.dydx.exchange/v4"
        @test client.timeout_s == 10.0
        @test client.rate_limiter === nothing
        @test client.cache === nothing
    end

    @testset "get_price — BTC-USD" begin
        price = get_price(client, "BTC-USD")

        if price !== nothing
            @test price.ticker == "BTC-USD"
            @test price.oracle_price > 0.0
            @test price.best_bid > 0.0
            @test price.best_ask > 0.0
            @test price.best_ask >= price.best_bid

            @testset "mid_price" begin
                mp = mid_price(price)
                @test mp > 0.0
                @test mp >= price.best_bid
                @test mp <= price.best_ask
            end

            @testset "spread_bps" begin
                sp = spread_bps(price)
                @test sp >= 0.0
                @test sp < 1000.0  # spread should be reasonable
            end
        else
            @warn "dYdX testnet returned nothing for BTC-USD (network issue?)"
        end
    end

    @testset "get_price — ETH-USD" begin
        price = get_price(client, "ETH-USD")

        if price !== nothing
            @test price.ticker == "ETH-USD"
            @test price.oracle_price > 0.0
            @test price.best_bid > 0.0
            @test price.best_ask > 0.0
        else
            @warn "dYdX testnet returned nothing for ETH-USD (network issue?)"
        end
    end

    @testset "get_price — invalid ticker" begin
        price = get_price(client, "NONEXISTENT-USD")
        @test price === nothing
    end

    @testset "get_price — timeout/network failure returns nothing" begin
        # Use a very small timeout and a reserved non-routable test IP to exercise timeout handling.
        client_timeout = DydxClient(
            base_url = "http://192.0.2.1/v4",
            timeout_s = 0.01,
        )
        price = get_price(client_timeout, "BTC-USD")
        @test price === nothing
    end

    @testset "rate limiter" begin
        client_limited = DydxClient(
            base_url = "https://indexer.v4testnet.dydx.exchange/v4",
            timeout_s = 10.0,
            rate_limit = RateLimiter(requests_per_second = 5.0),
        )

        @test client_limited.rate_limiter !== nothing
        @test client_limited.rate_limiter.refill_rate == 5.0

        # Should still work with rate limiting
        price = get_price(client_limited, "BTC-USD")
        if price !== nothing
            @test price.ticker == "BTC-USD"
        end
    end

    @testset "price cache" begin
        client_cached = DydxClient(
            base_url = "https://indexer.v4testnet.dydx.exchange/v4",
            timeout_s = 10.0,
            cache = PriceCache(ttl_s = 60.0),
        )

        @test client_cached.cache !== nothing

        # First call - cache miss
        price1 = get_price(client_cached, "BTC-USD")
        if price1 !== nothing
            @test price1.ticker == "BTC-USD"
            @test cache_size(client_cached.cache) >= 1

            # Second call - cache hit
            price2 = get_price(client_cached, "BTC-USD")
            @test price2 !== nothing
            @test price2.ticker == "BTC-USD"
        end
    end
end
