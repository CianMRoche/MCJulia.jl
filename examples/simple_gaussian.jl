# A Simple MC Julia test case with detailed explanation

# Load the module and import its public names
using MCJulia

# In this simple test case we'll estimate the one-dimensional
# probability distribution N(1, 1). We need to give the logarithm
# of a function proportional to the actual density.
# The position is given to the function as a vector.
@everywhere function log_probability(X)
    return -(X[1] - 1.0)^2
end
# Set up the sampler with minimal options. We'll use 100 walkers
# and the dimension of our probability space is 1.
srand(0)
walkers = 100
S = Sampler(walkers, 1, log_probability)

# Generate random starting positions for all walkers with a uniform
# distribution in the [-5, 5] interval.
p0 = rand((walkers,1)) * 10 - 5

# Do a 20-step burn-in without saving the results.  Since we have
# 100 walkers, we are throwing away 2000 samples. The return value
# p is the position of the walkers at the last step.
p = sample(S, p0, 20, 1, false, false)

# Now the actual sampling run.
# Run the sampler for 100 steps using p as a starting position, 
# generating a total of 10000 samples.
@time sample(S, p, 100, 5, true, false)

# Flatten and save the chain into a file.
save_chain(S, "chain.jld")

# Uncomment the following to automatically run the simple Python
# plotting program:
# run(`python plot_chains.py chain.txt`)


# Repeat everything for a slow function using parallel processing
@everywhere function log_probability_slow(X)
    A = randn(100000).^2
    return -(X[1] - 1.0)^2
end

srand(0)
walkers = 100
S = Sampler(walkers, 1, log_probability_slow)
p0 = rand((walkers,1)) * 10 - 5
p = sample(S, p0, 20, 1, false, true)
@time sample(S, p, 100, 5, true, true)
save_chain(S, "chain.jld")
