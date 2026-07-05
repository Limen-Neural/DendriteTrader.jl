# SPDX-License-Identifier: MIT OR Apache-2.0

using Test
using DendriteTrader

@testset "validate_signal" begin
    @testset "valid signal" begin
        d = Dict(
            "ticker" => "BTC-USD",
            "side" => "BUY",
            "price" => 100.0,
            "confidence" => 0.5,
            "timestamp_ns" => 1,
        )
        @test validate_signal(d) === nothing
    end

    @testset "missing required fields" begin
        d = Dict(
            "ticker" => "BTC-USD",
            "side" => "BUY",
            "price" => 100.0,
            "confidence" => 0.5,
            # timestamp_ns missing
        )
        err = validate_signal(d)
        @test err !== nothing
        @test occursin("missing required field", err)
        @test occursin("timestamp_ns", err)
    end

    @testset "bad types" begin
        @test occursin(
            "ticker must be a non-empty string",
            validate_signal(
                Dict(
                    "ticker" => 123,
                    "side" => "BUY",
                    "price" => 100.0,
                    "confidence" => 0.5,
                    "timestamp_ns" => 1,
                ),
            ),
        )

        @test occursin(
            "side must be BUY",
            validate_signal(
                Dict(
                    "ticker" => "BTC-USD",
                    "side" => 1,
                    "price" => 100.0,
                    "confidence" => 0.5,
                    "timestamp_ns" => 1,
                ),
            ),
        )

        @test occursin(
            "price must be a number",
            validate_signal(
                Dict(
                    "ticker" => "BTC-USD",
                    "side" => "BUY",
                    "price" => "100.0",
                    "confidence" => 0.5,
                    "timestamp_ns" => 1,
                ),
            ),
        )

        @test occursin(
            "confidence must be a number",
            validate_signal(
                Dict(
                    "ticker" => "BTC-USD",
                    "side" => "BUY",
                    "price" => 100.0,
                    "confidence" => "0.5",
                    "timestamp_ns" => 1,
                ),
            ),
        )

        @test occursin(
            "timestamp_ns must be an integer",
            validate_signal(
                Dict(
                    "ticker" => "BTC-USD",
                    "side" => "BUY",
                    "price" => 100.0,
                    "confidence" => 0.5,
                    "timestamp_ns" => 1.0,
                ),
            ),
        )
    end

    @testset "out-of-range values" begin
        @test occursin(
            "price must be positive",
            validate_signal(
                Dict(
                    "ticker" => "BTC-USD",
                    "side" => "BUY",
                    "price" => 0.0,
                    "confidence" => 0.5,
                    "timestamp_ns" => 1,
                ),
            ),
        )

        @test occursin(
            "confidence must be in [0.0, 1.0]",
            validate_signal(
                Dict(
                    "ticker" => "BTC-USD",
                    "side" => "BUY",
                    "price" => 100.0,
                    "confidence" => 1.1,
                    "timestamp_ns" => 1,
                ),
            ),
        )

        @test occursin(
            "timestamp_ns must be positive",
            validate_signal(
                Dict(
                    "ticker" => "BTC-USD",
                    "side" => "BUY",
                    "price" => 100.0,
                    "confidence" => 0.5,
                    "timestamp_ns" => 0,
                ),
            ),
        )
    end
end
