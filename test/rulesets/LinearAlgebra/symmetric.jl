@testset "Symmetric/Hermitian rules" begin
    @testset "$(SymHerm)(::AbstractMatrix{$T}, :$(uplo))" for
        SymHerm in (Symmetric, Hermitian),
        T in (Float64, ComplexF64),
        uplo in (:U, :L)

        N = 3
        @testset "frule" begin
            x = randn(T, N, N)
            Δx = randn(T, N, N)
            # can't use frule_test here because it doesn't yet ignore nothing tangents
            Ω = SymHerm(x, uplo)
            Ω_ad, ∂Ω_ad = frule((Zero(), Δx, Zero()), SymHerm, x, uplo)
            @test Ω_ad == Ω
            ∂Ω_fd = jvp(_fdm, z -> SymHerm(z, uplo), (x, Δx))
            @test ∂Ω_ad ≈ ∂Ω_fd
        end
        @testset "rrule" begin
            x = randn(T, N, N)
            ∂x = randn(T, N, N)
            ΔΩ = randn(T, N, N)
            @testset "back(::$MT)" for MT in (Matrix, LowerTriangular, UpperTriangular)
                rrule_test(SymHerm, MT(ΔΩ), (x, ∂x), (uplo, nothing))
            end
            @testset "back(::Diagonal)" begin
                rrule_test(SymHerm, Diagonal(ΔΩ), (x, Diagonal(∂x)), (uplo, nothing))
            end
        end
    end
    @testset "$(f)(::$(SymHerm){$T}) with uplo=:$uplo" for f in (Matrix, Array),
        SymHerm in (Symmetric, Hermitian),
        T in (Float64, ComplexF64),
        uplo in (:U, :L)

        N = 3
        x = SymHerm(randn(T, N, N), uplo)
        Δx = randn(T, N, N)
        ∂x = SymHerm(randn(T, N, N), uplo)
        ΔΩ = f(SymHerm(randn(T, N, N), uplo))
        frule_test(f, (x, Δx))
        frule_test(f, (x, SymHerm(Δx, uplo)))
        rrule_test(f, ΔΩ, (x, ∂x))
    end

    # symmetric/hermitian eigendecomposition follows the sign convention
    # v = v * sign(real(vₖ)) * sign(vₖ)', where vₖ is the first or last coordinate
    # in the eigenvector. This is unstable for finite differences, but using the convention
    # v = v * sign(vₖ)' seems to be more stable, the (co)tangents are related as
    # ∂v_ad = sign(real(vₖ)) * ∂v_fd

    function _eigvecs_stabilize_mat(vectors, uplo)
        Ui = Symbol(uplo) === :U ? @view(vectors[end, :]) : @view(vectors[1, :])
        return Diagonal(conj.(sign.(Ui)))
    end

    @testset "eigendecomposition" begin
        @testset "eigen/eigen!" begin
            # avoid implementing to_vec(::Eigen)
            asnt(E::Eigen) = (values=E.values, vectors=E.vectors)

            function _eigen_stable(A)
                F = eigen(A)
                rmul!(F.vectors, _eigvecs_stabilize_mat(F.vectors, A.uplo))
                return F
            end

            n = 10
            @testset "eigen!(::$SymHerm{$T}) uplo=$uplo" for SymHerm in (Symmetric, Hermitian),
                T in (SymHerm === Symmetric ? (Float64,) : (Float64, ComplexF64)),
                uplo in (:L, :U)

                A, ΔA = randn(T, n, n), randn(T, n, n)
                symA = SymHerm(A, uplo)
                ΔsymA = frule((Zero(), ΔA, Zero()), SymHerm, A, uplo)[2]

                F = eigen!(copy(symA))
                @test @inferred(frule((Zero(), Zero()), eigen!, copy(symA))) == (F, Zero())
                F_ad, ∂F_ad = @inferred frule((Zero(), copy(ΔsymA)), eigen!, copy(symA))
                @test F_ad == F
                @test ∂F_ad isa Composite{typeof(F)}
                @test ∂F_ad.values isa typeof(F.values)
                @test ∂F_ad.vectors isa typeof(F.vectors)

                f = x -> asnt(eigen(SymHerm(x, uplo)))
                ∂F_fd = jvp(_fdm, f, (A, ΔA))
                @test ∂F_ad.values ≈ ∂F_fd.values

                f_stable = x -> asnt(_eigen_stable(SymHerm(x, uplo)))
                F_stable = f_stable(A)
                ∂F_stable_fd = jvp(_fdm, f_stable, (A, ΔA))
                C = _eigvecs_stabilize_mat(F.vectors, uplo)
                @test ∂F_ad.vectors * C ≈ ∂F_stable_fd.vectors
            end

            @testset "eigen(::$SymHerm{$T}) uplo=$uplo" for SymHerm in (Symmetric, Hermitian),
                T in (SymHerm === Symmetric ? (Float64,) : (Float64, ComplexF64)),
                uplo in (:L, :U)

                A, ΔU, Δλ = randn(T, n, n), randn(T, n, n), randn(n)
                symA = SymHerm(A, uplo)

                F = eigen(symA)
                ΔF = Composite{typeof(F)}(; values=Δλ, vectors=ΔU)
                F_ad, back = @inferred rrule(eigen, symA)
                @test F_ad == F

                C = _eigvecs_stabilize_mat(F.vectors, uplo)
                CT = Composite{typeof(F)}

                @testset for nzprops in ([:values], [:vectors], [:values, :vectors])
                    ∂F = CT(; [s => getproperty(ΔF, s) for s in nzprops]...)
                    ∂F_stable = (; [s => copy(getproperty(ΔF, s)) for s in nzprops]...)
                    :vectors in nzprops && rmul!(∂F_stable.vectors, C)

                    f_stable = function(x)
                        F_ = _eigen_stable(SymHerm(x, uplo))
                        return (; (s => getproperty(F_, s) for s in nzprops)...)
                    end

                    ∂self, ∂symA = @inferred back(∂F)
                    @test ∂self === NO_FIELDS
                    @test ∂symA isa typeof(symA)
                    @test ∂symA.uplo == symA.uplo
                    ∂A = rrule(SymHerm, A, uplo)[2](∂symA)[2]
                    ∂A_fd = j′vp(_fdm, f_stable, ∂F_stable, A)[1]
                    @test ∂A ≈ ∂A_fd
                end

                @test @inferred(back(Zero())) == (NO_FIELDS, Zero())
                @test @inferred(back(CT())) == (NO_FIELDS, Zero())
            end
        end

        @testset "eigvals!/eigvals" begin
            n = 10
            @testset "eigvals!(::$SymHerm{$T}) uplo=$uplo" for SymHerm in (Symmetric, Hermitian),
                T in (SymHerm === Symmetric ? (Float64,) : (Float64, ComplexF64)),
                uplo in (:L, :U)

                A, ΔA = randn(T, n, n), randn(T, n, n)
                symA = SymHerm(A, uplo)
                ΔsymA = @inferred frule((Zero(), ΔA, Zero()), SymHerm, A, uplo)[2]

                λ = eigvals!(copy(symA))
                λ_ad, ∂λ_ad = @inferred frule((Zero(), copy(ΔsymA)), eigvals!, copy(symA))
                @test λ_ad ≈ λ # inexact because frule uses eigen not eigvals
                @test ∂λ_ad isa typeof(λ)
                @test ∂λ_ad ≈ jvp(_fdm, A -> eigvals(SymHerm(A, uplo)), (A, ΔA))
            end

            @testset "eigvals(::$SymHerm{$T}) uplo=$uplo" for SymHerm in (Symmetric, Hermitian),
                T in (SymHerm === Symmetric ? (Float64,) : (Float64, ComplexF64)),
                uplo in (:L, :U)

                A, Δλ = randn(T, n, n), randn(n)
                symA = SymHerm(A, uplo)

                λ = eigvals(symA)
                λ_ad, back = @inferred rrule(eigvals, symA)
                @test λ_ad ≈ λ # inexact because rrule uses eigen not eigvals
                ∂self, ∂symA = @inferred back(Δλ)
                @test ∂self === NO_FIELDS
                @test ∂symA isa typeof(symA)
                @test ∂symA.uplo == symA.uplo

                # pull the cotangent back to A to test against finite differences
                ∂A = rrule(SymHerm, A, uplo)[2](∂symA)[2]
                @test ∂A ≈ j′vp(_fdm, A -> eigvals(SymHerm(A, uplo)), Δλ, A)[1]

                @test @inferred(back(Zero())) == (NO_FIELDS, Zero())
            end
        end
    end

    @testset "singular value decomposition" begin
        # avoid implementing to_vec(::Eigen)
        asnt(F::SVD) = (U=F.U, S=F.S, V=F.V, Vt=F.Vt)

        function _svd_stable(A)
            F = svd(A)
            C = _eigvecs_stabilize_mat(F.U, A.uplo)
            rmul!(F.U, C)
            lmul!(C, F.Vt)
            return F
        end

        n = 10
        @testset "svd(::$SymHerm{$T}) uplo=$uplo" for SymHerm in (Symmetric, Hermitian),
            T in (SymHerm === Symmetric ? (Float64,) : (Float64, ComplexF64)),
            uplo in (:L, :U)

            A, ΔU, ΔV, ΔVt = ntuple(_ -> randn(T, n, n), 4)
            ΔS = randn(n)
            symA = SymHerm(A, uplo)

            F = svd(symA)
            CT = Composite{typeof(F)}
            ΔF = CT(; U=ΔU, V=ΔV, Vt=ΔVt, S=ΔS)
            F_ad, back = @inferred rrule(svd, symA)
            @test F_ad == F

            C = _eigvecs_stabilize_mat(F.U, uplo)

            @testset for nzprops in ([:U], [:S], [:V], [:Vt], [:U, :S, :V, :Vt])
                ∂F = CT(; [s => getproperty(ΔF, s) for s in nzprops]...)
                ∂F_stable = (; [s => copy(getproperty(ΔF, s)) for s in nzprops]...)
                :U in nzprops && rmul!(∂F_stable.U, C)
                :Vt in nzprops && lmul!(C, ∂F_stable.Vt)
                :V in nzprops && rmul!(∂F_stable.V, C)

                f_stable = function(x)
                    F_ = _svd_stable(SymHerm(x, uplo))
                    return (; (s => getproperty(F_, s) for s in nzprops)...)
                end

                ∂self, ∂symA = @inferred back(∂F)
                @test ∂self === NO_FIELDS
                @test ∂symA isa typeof(symA)
                @test ∂symA.uplo == symA.uplo
                ∂A = rrule(SymHerm, A, uplo)[2](∂symA)[2]
                ∂A_fd = j′vp(_fdm, f_stable, ∂F_stable, A)[1]
                @test ∂A ≈ ∂A_fd
            end

            @test @inferred(back(Zero())) == (NO_FIELDS, Zero())
            @test @inferred(back(CT())) == (NO_FIELDS, Zero())
        end
    end
end
