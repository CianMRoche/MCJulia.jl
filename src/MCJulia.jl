# MC Julia

# Ensemble sampling MCMC inspired by the emcee package for Python
# http://danfm.ca/emcee/

# ref.:
# Goodman & Weare, Ensemble Samplers With Affine Invariance
#   Comm. App. Math. Comp. Sci., Vol. 5 (2010), No. 1, 65–80

# Start module
module MCJulia

using JLD
import Random: rand
import Distributed: pmap
using ProgressMeter
using NPZ
export Sampler, sample, reset, flat_chain, save_chain

# Random generator for the Z distribution of Goodman & Weare, where
# p(x) = 1/sqrt(x) when 1/a <= x <= a.
randZ(a::Float64) = ((a - 1.0) * rand() + 1.0)^2 / a

# The Sampler type is the interface between the user and the machinery.
mutable struct Sampler
    n_walkers::Int64
    dim::Int64
    probfn::Function
    a::Float64
    chain::Array{Float64, 3}
    ln_posterior::Array{Float64,2}
    iterations::Int64
    accepted::Int64
    args::Tuple{Vararg{Any}} # args::(Any...)
    callback::Function
end

function dummy_callback(s::Sampler, iter::Int64, saveindex::Int64, k::Int64)
end

# Constructor
function Sampler(k::Integer, dim::Integer, f::Function, a::Real, args::Tuple{Vararg{Any}}, callback::Function)
    accpt=0
    iter=0
    chain = zeros(Float64, (k, dim, 0))
    ln_p = zeros(Float64, (k, 0))
    S = Sampler(k,dim,f,a,chain,ln_p,iter,accpt,args,callback)
    return S
end

# Minimal constructors
Sampler(k::Integer, dim::Integer, f::Function, a::Real; callback::Function = dummy_callback) = Sampler(k, dim, f, a, (), callback)
Sampler(k::Integer, dim::Integer, f::Function, args::Tuple{Vararg{Any}}; callback::Function = dummy_callback) = Sampler(k, dim, f, 2.0, args, callback)
Sampler(k::Integer, dim::Integer, f::Function, a::Real, args::Tuple{Vararg{Any}}; callback::Function = dummy_callback) = Sampler(k, dim, f, a, args, callback) # if changing a is desired
Sampler(k::Integer, dim::Integer, f::Function; callback::Function = dummy_callback) = Sampler(k, dim, f, 2.0, (), callback)

call_lnprob(S::Sampler, pos::Array{Float64}) = S.probfn(pos, S.args...)

# Return all lnprobs at given position
function get_lnprob(S::Sampler, pos::Array{Float64})
    lnprob = zeros(Float64, S.n_walkers)
    for k = 1:S.n_walkers
	lnprob[k] = call_lnprob(S, vec(pos[k,:]))
    end
    return lnprob
end

function sample_serial(S::Sampler, p0::Array{Float64,2}, N::Int64, thin::Int64, storechain::Bool)
    println("Starting serial sampling...")
    k = S.n_walkers
    halfk = fld(k, 2)

    progress_meter = Progress(k*N; dt = 5.0, showspeed=true) # update every 5 seconds
    
    p = copy(p0)
    lnprob = get_lnprob(S, p)
    
    i0 = size(S.chain, 3)
    
    # Add N/thin columns of zeroes to the Sampler's chain and ln_posterior
    if storechain
	S.chain = cat(S.chain, zeros(Float64, (k, S.dim, fld(N,thin))); dims = 3)
	S.ln_posterior = cat(S.ln_posterior, zeros(Float64, (k, fld(N,thin))); dims = 2)
    end
    
    first = 1 : halfk
    second = halfk+1 : k
    divisions = [(first, second), (second, first)]
    
    for i in i0+1 : i0+N
	for ensembles in divisions
	    active, passive = ensembles
	    l_pas = size(passive,1)
	    for k in active
            next!(progress_meter)
	        X_active = vec(p[k,:])
	        choice = passive[rand(1:l_pas)]
	        X_passive = vec(p[choice,:])
	        z = randZ(S.a)
	        proposal = X_passive + z*(X_active - X_passive)
	        new_lnprob = call_lnprob(S, proposal)
	        log_ratio = (S.dim - 1) * log(z) + new_lnprob - lnprob[k]

            accept_step_check = (log(rand()) <= log_ratio)
	        if accept_step_check
	            lnprob[k] = new_lnprob
	            p[k,:] .= proposal
	            S.accepted += 1
	        end

	        S.iterations += 1
            if (i - i0) % thin == 0
                flooridx = fld(i,thin)
                if storechain
                    S.ln_posterior[k, flooridx] = lnprob[k]
                    S.chain[k, :, flooridx] .= vec(p[k,:])
                end # storechain
                S.callback(S, i - i0, flooridx, k)
	        end # thin
	    end # k in active
	end # ensemble
    end # main loop
    return p
end

function sample_multithreaded(S::Sampler, p0::Array{Float64,2}, N::Int64, thin::Int64, storechain::Bool)
    println("Starting multi-threaded sampling on ", Threads.nthreads(), " threads")
    k = S.n_walkers
    halfk = fld(k, 2)
    
    progress_meter = Progress(k*N; dt = 1.0, showspeed=true) # update every 5 seconds

    p = copy(p0)
    lnprob = get_lnprob(S, p)
    
    i0 = size(S.chain, 3)
    
    # Add N/thin columns of zeroes to the Sampler's chain and ln_posterior
    if storechain
	S.chain = cat(S.chain, zeros(Float64, (k, S.dim, fld(N,thin))); dims = 3)
	S.ln_posterior = cat(S.ln_posterior, zeros(Float64, (k, fld(N,thin))); dims = 2)
    end
    
    first = 1 : halfk
    second = halfk+1 : k
    divisions = [(first, second), (second, first)]
    
    Threads.@threads for i in i0+1 : i0+N
	for ensembles in divisions
	    active, passive = ensembles
	    l_pas = size(passive,1)
	    for k in active
            next!(progress_meter)
	        X_active = vec(p[k,:])
	        choice = passive[rand(1:l_pas)]
	        X_passive = vec(p[choice,:])
	        z = randZ(S.a)
	        proposal = X_passive + z*(X_active - X_passive)
	        new_lnprob = call_lnprob(S, proposal)
	        log_ratio = (S.dim - 1) * log(z) + new_lnprob - lnprob[k]

            accept_step_check = (log(rand()) <= log_ratio)
	        if accept_step_check
	            lnprob[k] = new_lnprob
	            p[k,:] .= proposal
	            S.accepted += 1
	        end
	        S.iterations += 1
            if (i - i0) % thin == 0
                flooridx = fld(i,thin)
                if storechain
                    S.ln_posterior[k, flooridx] = lnprob[k]
                    S.chain[k, :, flooridx] .= vec(p[k,:])
                end # storechain
                S.callback(S, i - i0, flooridx, k)
	        end # thin
	    end # k in active
	end # ensemble
    end # main loop
    return p
end

function sample(S::Sampler, p0::Array{Float64,2}, N::Int64, thin::Int64, storechain::Bool, multithreaded::Bool = Threads.nthreads() > 1)
    if multithreaded
        sample_multithreaded(S, p0, N, thin, storechain)
    else
        sample_serial(S, p0, N, thin, storechain)
    end
end

function sample(S::Sampler, N::Int64, thin::Int64, storechain::Bool)
    N = size(S.chain, 3)
    if N == 0
	error("No initial position for chain!")
    end
    p0 = S.chain[:,:,N]
    sample(S, p0, N, thin, storechain)
end

sample(S::Sampler, N::Int64) = sample(S, N, 1, true)
sample(S::Sampler, N::Int64, storechain::Bool) = sample(S, N, 1, storechain)


# Reset a Sampler to state after construction.
function reset(S::Sampler)
    k = S.n_walkers
    S.chain = zeros(Float64, (k, S.dim, 0))
    S.ln_posterior = zeros(Float64, (k, 0))
    S.accepted = 0
    S.iterations = 0
    return S
end

# Flatten the chain along the walker axis
function flat_chain(S::Sampler)
    walkers,dimensions,steps = size(S.chain)
    flatchain = zeros((dimensions, walkers*steps))
    for step = 1:steps
	k = (step-1)*walkers + 1
	for dim = 1:dimensions
	    flatchain[dim, k:(k+walkers-1)] .= S.chain[:,dim,step]
	end
    end
    return flatchain
end

# Squash the chains and save them in a csv file
function save_chain(S::Sampler, filename::AbstractString)
    #save(filename, "chain", S.chain, "ln_posterior", S.ln_posterior)
    
    # Flatten and save output
    ln_posterior_flat = reduce(vcat,S.ln_posterior)

    npzwrite(filename * "_chain.npy", flat_chain(S))
    npzwrite(filename * "_lnprob.npy", ln_posterior_flat) # save it to a separate file so we dont mess with old functions

end


end # module ends
