
function solve_admm(prob_load, probs, opts::AugmentedLagrangianSolverOptions)
    prob_load = copy(prob_load)
    probs = copy_probs(probs)
    X_cache, U_cache, X_lift, U_lift = init_cache(probs)
    solve_admm!(prob_load, probs, X_cache, U_cache, X_lift, U_lift, opts)
    combine_problems(prob_load, probs)
end

function solve_init!(prob_load, probs::DArray, X_cache, U_cache, X_lift, U_lift, opts)
    # for i in workers()
    #     @spawnat i solve!(probs[:L], opts)
    # end
    futures = [@spawnat w solve!(probs[:L], opts_al) for w in workers()]
    solve!(prob_load, opts)
    wait.(futures)

    # Get trajectories
    X_lift0 = fetch.([@spawnat w probs[:L].X for w in workers()])
    U_lift0 = fetch.([@spawnat w probs[:L].U for w in workers()])
    for i = 1:num_lift
        X_lift[i] .= X_lift0[i]
        U_lift[i] .= U_lift0[i]
    end
    update_load_problem(prob_load, X_lift, U_lift, d)

    # Send trajectories
    @sync for w in workers()
        for i = 2:4
            @spawnat w begin
                X_cache[:L][i] .= X_lift0[i-1]
                U_cache[:L][i] .= U_lift0[i-1]
            end
        end
        @spawnat w begin
            X_cache[:L][1] .= prob_load.X
            U_cache[:L][1] .= prob_load.U
        end
    end

    # Update lift problems
    @sync for w in workers()
        agent = w - 1
        @spawnat w update_lift_problem(probs[:L], X_cache[:L], U_cache[:L], agent, d[agent], r_lift)
    end
end

function solve_init!(prob_load, probs::Vector{<:Problem}, X_cache, U_cache, X_lift, U_lift, opts)
    num_lift = length(probs)
    for i = 1:num_lift
        solve!(probs[i], opts)
    end
    solve!(prob_load, opts)

    # Get trajectories
    X_lift0 = [prob.X for prob in probs]
    U_lift0 = [prob.U for prob in probs]
    for i = 1:num_lift
        X_lift[i] .= X_lift0[i]
        U_lift[i] .= U_lift0[i]
    end
    update_load_problem(prob_load, X_lift, U_lift, d)

    # Send trajectories
    for w = 2:4
        for i = 2:4
            X_cache[w-1][i] .= X_lift0[i-1]
            U_cache[w-1][i] .= U_lift0[i-1]
        end
        X_cache[w-1][1] .= prob_load.X
        U_cache[w-1][1] .= prob_load.U
    end

    # Update lift problems
    for w = 2:4
        agent = w - 1
        update_lift_problem(probs[agent], X_cache[agent], U_cache[agent], agent, d[agent], r_lift)
    end
end

function solve_admm!(prob_load, probs::Vector{<:Problem}, X_cache, U_cache, X_lift, U_lift, opts)
    num_left = length(probs) - 1

    # Solve the initial problems
    solve_init!(prob_load, probs, X_cache, U_cache, X_lift, U_lift, opts_al)

    # create augmented Lagrangian problems, solvers
    solvers_al = AugmentedLagrangianSolver{Float64}[]
    for i = 1:num_lift
        solver = AugmentedLagrangianSolver(probs[i],opts)
        probs[i] = AugmentedLagrangianProblem(probs[i],solver)
        push!(solvers_al, solver)
    end
    solver_load = AugmentedLagrangianSolver(prob_load, opts)
    prob_load = AugmentedLagrangianProblem(prob_load, solver_load)

    for ii = 1:opts.iterations
        # Solve each AL problem
        for i = 1:num_lift
            TO.solve_aula!(probs[i], solvers_al[i])
        end

        # Get trajectories
        for i = 1:num_lift
            X_lift[i] .= probs[i].X
            U_lift[i] .= probs[i].U
        end

        # Solve load with updated lift trajectories
        TO.solve_aula!(prob_load, solver_load)

        # Send trajectories
        for i = 1:num_lift  # loop over agents
            for j = 1:num_lift
                i != j || continue
                X_cache[i][j+1] .= X_lift[j]
            end
            X_cache[i][1] .= prob_load.X
        end

        max_c = maximum(max_violation.(solvers_al))
        max_c = max(max_c, max_violation(solver_load))
        println(max_c)
        if max_c < opts.constraint_tolerance
            break
        end
    end
end

function solve_admm!(prob_load, prob::DArray, X_cache, U_cache, X_lift, U_lift, opts)
    solve_init!(prob_load, probs, X_cache, U_cache, X_lift, U_lift, opts_al)

    # create augmented Lagrangian problems, solvers
    solvers_al = ddata(T=AugmentedLagrangianSolver{Float64});
    @sync for w in workers()
        @spawnat w begin
            solvers_al[:L] = AugmentedLagrangianSolver(probs[:L], opts)
            probs[:L] = AugmentedLagrangianProblem(probs[:L],solvers_al[:L])
        end
    end
    solver_load = AugmentedLagrangianSolver(prob_load, opts)
    prob_load = AugmentedLagrangianProblem(prob_load, solver_load)

    for ii = 1:opts.iterations
        # Solve each AL lift problem
        future = [@spawnat w TO.solve_aula!(probs[:L], solvers_al[:L]) for w in workers()]
        wait.(future)

        # Get trajectories
        X_lift0 = fetch.([@spawnat w probs[:L].X for w in workers()])
        U_lift0 = fetch.([@spawnat w probs[:L].U for w in workers()])
        for i = 1:num_lift
            X_lift[i] .= X_lift0[i]
            U_lift[i] .= U_lift0[i]
        end
        TO.solve_aula!(prob_load, solver_load)

        # Send trajectories
        @sync for w in workers()
            for i = 2:4
                @spawnat w begin
                    X_cache[:L][i] .= X_lift0[i-1]
                    U_cache[:L][i] .= U_lift0[i-1]
                end
            end
            @spawnat w begin
                X_cache[:L][1] .= prob_load.X
                U_cache[:L][1] .= prob_load.U
            end
        end
        max_c = maximum(fetch.([@spawnat w max_violation(solvers_al[:L]) for w in workers()]))
        max_c = max(max_c, max_violation(solver_load))
        println(max_c)
        if max_c < opts.constraint_tolerance
            break
        end
    end
end

copy_probs(probs::Vector{<:Problem}) = copy.(probs)
function copy_probs(probs::DArray)
    probs2 = ddata(T=eltype(probs))
    @sync for w in workers()
        @spawnat w probs2[:L] = copy(probs[:L])
    end
    return probs2
end


combine_problems(prob_load, probs::Vector{<:Problem}) = [[prob_load]; probs]
function combine_problems(prob_load, probs::DArray)
    problems = fetch.([@spawnat w probs[:L] for w in workers()])
    combine_problems(prob_load, problems)
end

function init_cache(probs::Vector{<:Problem})
    num_lift = length(probs)
    X_lift = [deepcopy(prob.X) for prob in probs]
    U_lift = [deepcopy(prob.U) for prob in probs]
    X_traj = [[prob_load.X]; X_lift]
    U_traj = [[prob_load.U]; U_lift]
    X_cache = [deepcopy(X_traj) for i=1:num_lift]
    U_cache = [deepcopy(U_traj) for i=1:num_lift]
    return X_cache, U_cache, X_lift, U_lift
end

function init_cache(probs::DArray)
    # Initialize state and control caches
    X_lift = fetch.([@spawnat w deepcopy(probs[:L].X) for w in workers()])
    U_lift = fetch.([@spawnat w deepcopy(probs[:L].U) for w in workers()])
    X_traj = [[prob_load.X]; X_lift]
    U_traj = [[prob_load.U]; U_lift]

    X_cache = ddata(T=Vector{Vector{Vector{Float64}}});
    U_cache = ddata(T=Vector{Vector{Vector{Float64}}});
    @sync for w in workers()
        @spawnat w begin
            X_cache[:L] = X_traj
            U_cache[:L] = U_traj
        end
    end
    return X_cache, U_cache, X_lift, U_lift
end
