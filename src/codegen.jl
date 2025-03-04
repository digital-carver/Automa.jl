# Code Generator
# ==============

"""
Struct used to store variable names used in generated code.
Contained in a `CodeGenContext`.
Create a custom `Variables` for your `CodeGenContext` if you
want to customize the variables used in Automa codegen, typically
if you have conflicting variables with the same name.

Automa generates code with the following variables, shown below
with their default names:
- `p::Int`: current position of data
- `p_end::Int`: end position of data
- `is_eof::Bool`: Whether `p_end` marks end file stream
- `cs::Int`: current state
- `data::Any`: input data
- `mem::SizedMemory`: Memory wrapping `data`
- `byte::UInt8`: current byte being read from `data`
- `buffer::TranscodingStreams.Buffer`: (`generate_reader` only)

# Example
```julia
julia> ctx = CodeGenContext(vars=Variables(byte=:u8));

julia> ctx.vars.byte
:u8
```
"""
struct Variables
    p::Symbol
    p_end::Symbol
    is_eof::Symbol
    cs::Symbol
    data::Symbol
    mem::Symbol
    byte::Symbol
    buffer::Symbol
end

function Variables(
    ;p=:p,
    p_end=:p_end,
    is_eof=:is_eof,
    cs=:cs,
    data=:data,
    mem=:mem,
    byte=:byte,
    buffer=:buffer
)
    Variables(p, p_end, is_eof, cs, data, mem, byte, buffer)
end

struct CodeGenContext
    vars::Variables
    generator::Function
    getbyte::Function
    clean::Bool
end

# Add these here so they can be used in CodeGenContext below
function generate_table_code end
function generate_goto_code end

"""
    CodeGenContext(;
        vars=Variables(:p, :p_end, :is_eof, :cs, :data, :mem, :byte, :buffer),
        generator=:table,
        getbyte=Base.getindex,
        clean=false
    )

Create a `CodeGenContext` (ctx), a struct that stores options for Automa code generation.
Ctxs are used for Automa's various code generator functions.
They currently take the following options (more may be added in future versions)

- `vars::Variables`: variable names used in generated code. See the `Variables` struct.
- `generator::Symbol`: code generator mechanism (`:table` or `:goto`).
  The table generator creates smaller, simpler code that uses a vector of integers to
  determine state transitions. The goto-generator uses a maze of `@goto`-statements,
  and create larger, more complex code, that is faster.
- `getbyte::Function` (table generator only): function `f(data, p)` to access byte from data.
  Default: `Base.getindex`.
- `clean`: Whether to remove some `QuoteNode`s (line information) from the generated code

# Example
```julia
julia> ctx = CodeGenContext(generator=:goto, vars=Variables(buffer=:tbuffer));

julia> generate_code(ctx, compile(re"a+")) isa Expr
true
```
"""
function CodeGenContext(;
        vars::Variables=Variables(:p, :p_end, :is_eof, :cs, :data, :mem, :byte, :buffer),
        generator::Symbol=:table,
        getbyte::Function=Base.getindex,
        clean::Bool=false)
    # special conditions for simd generator
    if generator == :goto && getbyte != Base.getindex
        throw(ArgumentError("GOTO generator only support Base.getindex"))
    end
    # check generator
    if generator == :table
        generator = generate_table_code
    elseif generator == :goto
        generator = generate_goto_code
    else
        throw(ArgumentError("invalid code generator: $(generator)"))
    end
    return CodeGenContext(vars, generator, getbyte, clean)
end

const DefaultCodeGenContext = CodeGenContext()

"""
    generate_buffer_validator(name::Symbol, regexp::RE; goto=true; docstring=true)

Generate code that, when evaluated, defines a function named `name`, which takes a
single argument `data`, interpreted as a sequence of bytes.
The function returns `nothing` if `data` matches `Machine`, else the index of the first
invalid byte. If the machine reached unexpected EOF, returns `0`.
If `goto`, the function uses the faster but more complicated `:goto` code.
If `docstring`, automatically create a docstring for the generated function.
"""
function generate_buffer_validator(
    name::Symbol,
    regex::RegExp.RE;
    goto::Bool=true,
    docstring::Bool=true
)
    ctx = goto ? CodeGenContext(generator=:goto) : DefaultCodeGenContext
    machine = compile(RegExp.strip_actions(regex))
    code = quote
        function $(name)(data)
            $(generate_init_code(ctx, machine))
            $(generate_exec_code(ctx, machine))
            # By convention, Automa lets cs be 0 if machine executed correctly.
            return if iszero($(ctx.vars.cs))
                nothing
            # Else if EOF
            elseif $(ctx.vars.p) > $(ctx.vars.p_end)
                0
            else
                p
            end
        end
    end
    if docstring
        code = quote
            """
                $($(name))(data)::Union{Int, Nothing}

            Checks if `data`, interpreted as a bytearray, conforms to the given `Automa.Machine`.
            Returns `nothing` if it does, else the byte index of the first invalid byte.
            If the machine reached unexpected EOF, returns `0`.
            """
            $code
        end
    end
    code
end

"""
    generate_code([::CodeGenContext], machine::Machine, actions=nothing)::Expr

Generate init and exec code for `machine`.
The default code generator function for creating functions, preferentially use
this over generating init and exec code directly, due to its convenience. 
Shorthand for producing the concatenated code of:

* `generate_init_code(ctx, machine)`
* `generate_action_code(ctx, machine, actions)`
* `generate_input_error_code(ctx, machine)` [elided if actions == :debug]

# Examples
```
@eval function foo(data)
    # Initialize variables used in actions
    data_buffer = UInt8[]
    \$(generate_code(machine, actions))
    return data_buffer
end
```

See also: [`generate_init_code`](@ref), [`generate_exec_code`](@ref)
"""
function generate_code(ctx::CodeGenContext, machine::Machine, actions=nothing)
    # If actions are :debug, the user presumably wants to programatically
    # check what happens to the machine, which is not made easier by
    # throwing an error.
    error_code = if actions != :debug
        generate_input_error_code(ctx, machine)
    else
        quote nothing end
    end
    code = quote
        $(generate_init_code(ctx, machine))
        $(generate_exec_code(ctx, machine, actions))
        $(error_code)
    end
    ctx.clean && Base.remove_linenums!(code)
    return code
end
generate_code(machine::Machine, actions=nothing) = generate_code(DefaultCodeGenContext, machine, actions)

"""
    generate_init_code([::CodeGenContext], machine::Machine)::Expr

Generate variable initialization code, initializing variables such as `p`,
and `p_end`. The names of these variables are set by the `CodeGenContext`.
If not passed, the context defaults to `DefaultCodeGenContext`

Prefer using the more generic `generate_code` over this function where possible.
This function should be used if the initialized data should be modified before
the execution code.

# Example
```julia
@eval function foo(data)
    \$(generate_init_code(machine))
    p = 2 # maybe I want to start from position 2, not 1
    \$(generate_exec_code(machine, actions))
    return cs
end
```

See also: [`generate_code`](@ref), [`generate_exec_code`](@ref)
"""
function generate_init_code(ctx::CodeGenContext, machine::Machine)
    vars = ctx.vars
    code = quote
        $(vars.byte)::UInt8 = 0x00
        $(vars.p)::Int = 1
        $(vars.p_end)::Int = sizeof($(vars.data))
        $(vars.is_eof)::Bool = true
        $(vars.cs)::Int = 1
    end
    ctx.clean && Base.remove_linenums!(code)
    return code
end
generate_init_code(machine::Machine) = generate_init_code(DefaultCodeGenContext, machine)



"""
    generate_exec_code([::CodeGenContext], machine::Machine, actions=nothing)::Expr

Generate machine execution code with actions. This code should be run after the
machine has been initialized with `generate_init_code`.
If not passed, the context defaults to `DefaultCodeGenContext`

Prefer using the more generic `generate_code` over this function where possible.
This function should be used if the initialized data should be modified before
the execution code.

# Examples
```
@eval function foo(data)
    \$(generate_init_code(machine))
    p = 2 # maybe I want to start from position 2, not 1
    \$(generate_exec_code(machine, actions))
    return cs
end
```

See also: [`generate_init_code`](@ref), [`generate_exec_code`](@ref)
"""
function generate_exec_code(ctx::CodeGenContext, machine::Machine, actions=nothing)
    # make actions
    actions_dict::Dict{Symbol, Expr} = if actions === nothing
        Dict{Symbol,Expr}(a => quote nothing end for a in machine_names(machine))
    elseif actions == :debug
        debug_actions(machine)
    elseif isa(actions, AbstractDict{Symbol,Expr})
        d = Dict{Symbol,Expr}(collect(actions))

        # check the set of actions is same as that of machine's
        machine_acts = machine_names(machine)
        dict_actions = Set(k for (k,v) in d)
        for act in machine_acts
            if act ∈ dict_actions
                delete!(dict_actions, act)
            else
                error("Action \"$act\" of machine not present in input action Dict")
            end
        end
        if length(dict_actions) > 0
            error("Action \"$(first(dict_actions))\" not present in machine")
        end
        d
    else
        throw(ArgumentError("invalid actions argument"))
    end

    # generate code
    code = ctx.generator(ctx, machine, actions_dict)
    ctx.clean && Base.remove_linenums!(code)
    return code
end

function generate_exec_code(machine::Machine, actions=nothing)
    generate_exec_code(DefaultCodeGenContext, machine, actions)
end

function generate_table_code(ctx::CodeGenContext, machine::Machine, actions::Dict{Symbol,Expr})
    action_dispatch_code, set_act_code = generate_action_dispatch_code(ctx, machine, actions)
    trans_table = generate_transition_table(machine)
    getbyte_code = generate_getbyte_code(ctx)
    set_cs_code = :(@inbounds $(ctx.vars.cs) = Int($(trans_table)[($(ctx.vars.cs) - 1) << 8 + $(ctx.vars.byte) + 1]))
    eof_action_code = generate_eof_action_code(ctx, machine, actions)
    final_state_code = generate_final_state_mem_code(ctx, machine)
    return quote
        # Preserve data because SizedMemory is just a pointer
        GC.@preserve $(ctx.vars.data) begin
        $(ctx.vars.mem)::Automa.SizedMemory = $(SizedMemory)($(ctx.vars.data))
        # For each input byte...
        while $(ctx.vars.p) ≤ $(ctx.vars.p_end) && $(ctx.vars.cs) > 0
            # Load byte
            $(getbyte_code)
            # Get an integer corresponding to the set of actions that will be taken
            # for this particular input at this stage (possibly nothing)
            $(set_act_code)
            # Update state by a simple lookup in a table based on current state and input
            $(set_cs_code)
            # Go through an if-else list of all actions to match the action integet obtained
            # above, and execute the matching set of actions
            $(action_dispatch_code)
            $(ctx.vars.p) += 1
        end
        # If we're out of bytes and in an accept state, find the correct EOF action
        # and execute it, then set cs to 0 to signify correct execution
        if is_eof && $(ctx.vars.p) > $(ctx.vars.p_end) && $(final_state_code)
            $(eof_action_code)
            $(ctx.vars.cs) = 0
        elseif $(ctx.vars.cs) < 0
            # If cs < 0, the machine errored. The code above incremented p regardless,
            # but on error, we want p to be where the machine errored, so we reset it.
            $(ctx.vars.p) -= 1
        end
        end # GC.@preserve block
    end
end

# Smallest int type that n fits in
function smallest_int(n::Integer)
    for T in [Int8, Int16, Int32, Int64]
        n <= typemax(T) && return T
    end
    @assert false
end

# The table is a 256xnstates byte lookup table, such that table[input,cs] will give
# the next state.
function generate_transition_table(machine::Machine)
    nstates = machine.n_states
    trans_table = Matrix{smallest_int(nstates)}(undef, 256, nstates)
    for j in 1:size(trans_table, 2)
        trans_table[:,j] .= -j
    end
    for s in traverse(machine.start), (e, t) in s.edges
        # Preconditions work by inserting if/else statements into the code.
        # It's hard to see how we could fit it into the table-based generator
        if !isempty(e.precond)
            error("precondition is not supported in the table-based code generator; try code=:goto")
        end
        for l in e.labels
            trans_table[l+1,s.state] = t.state
        end
    end
    return trans_table
end

function generate_action_dispatch_code(ctx::CodeGenContext, machine::Machine, actions::Dict{Symbol,Expr})
    nactions = length(actions)
    T = smallest_int(nactions)
    action_table = fill(zero(T), (256, machine.n_states))
    # Each edge with actions is a Vector{Symbol} with action names.
    # Enumerate them, by mapping the vector to an integer.
    # This way, each set of actions is mapped to an integer (call it: action int)
    action_ids = Dict{Vector{Symbol},T}()
    for s in traverse(machine.start)
        for (e, t) in s.edges
            if isempty(e.actions)
                continue
            end
            id = get!(action_ids, action_names(e.actions), length(action_ids) + 1)
            # In the action table, the current state as well as the input byte gives the
            # action int (see above) to execute on this transition
            for l in e.labels
                action_table[l+1,s.state] = id
            end
        end
    end
    act = gensym()
    default = :()
    # This creates code of the form: If act == 1 (actions in action int == 1)
    # else if act == 2 (... etc)
    action_dispatch_code = foldr(default, action_ids) do names_id, els
        names, id = names_id
        action_code = rewrite_special_macros(;
            ctx=ctx,
            ex=generate_action_code(names, actions),
            at_eof=false,
            cs=nothing
        )
        return Expr(:if, :($(act) == $(id)), action_code, els)
    end
    # Action code is: Get the action int from the state and current input byte
    # Action dispatch code: The thing made above
    action_code = :(@inbounds $(act) = Int($(action_table)[($(ctx.vars.cs) - 1) << 8 + $(ctx.vars.byte) + 1]))
    return action_dispatch_code, action_code
end

function generate_goto_code(ctx::CodeGenContext, machine::Machine, actions::Dict{Symbol,Expr})
    # All the sets of actions (each set being a vector) on edges leading to a
    # given machine node.
    actions_in = Dict{Node,Set{Vector{Symbol}}}()
    for s in traverse(machine.start), (e, t) in s.edges
        push!(get!(actions_in, t, Set{Vector{Symbol}}()), action_names(e.actions))
    end
    # Assign each action a unique name based on the destination node the edge is on,
    # and an integer, e.g. state_2_action_5
    action_label = Dict{Node,Dict{Vector{Symbol},Symbol}}()
    for s in traverse(machine.start)
        action_label[s] = Dict()
        if haskey(actions_in, s)
            for (i, names) in enumerate(actions_in[s])
                action_label[s][names] = Symbol("state_", s.state, "_action_", i)
            end
        end
    end

    # Main loop expression blocks
    blocks = Expr[]
    for s in traverse(machine.start)
        block = Expr(:block)
        for (names, label) in action_label[s]
            # These blocks are goto'd directly, when encountering the right edge. Their content
            # if of the form execute action, then go to the state the edge was pointing to
            if isempty(names)
                continue
            end
            append_code!(block, quote
                @label $(label)
                $(rewrite_special_macros(;
                    ctx=ctx,
                    ex=generate_action_code(names, actions),
                    at_eof=false,
                    cs=s.state)
                )
                @goto $(Symbol("state_", s.state))
            end)
        end

        # This is the code of each state. The pointer is incremented, you @goto the exit
        # if EOF, else continue to the code created below
        append_code!(block, quote
            @label $(Symbol("state_", s.state))
            $(ctx.vars.p) += 1
            if $(ctx.vars.p) > $(ctx.vars.p_end)
                $(ctx.vars.cs) = $(s.state)
                @goto exit
            end
        end)

        # SIMD code is special: If a node has a self-edge with no preconditions or actions,
        # then the machine can skip ahead until the input is no longer in that edge's byteset.
        # This can be effectively SIMDd
        # If such an edge is detected, we treat it specially with code here, and leave the
        # non-SIMDable edges for below

        # SIMD code temporarily disabled.
        simd, non_simd = peel_simd_edge(s)
        if simd !== nothing
            push!(non_simd, (simd, s))
        end
        simd = nothing
        simd_code = :()

        #=
        simd_code = if simd !== nothing
            quote
                $(generate_simd_loop(ctx, simd.labels))
                if $(ctx.vars.p) > $(ctx.vars.p_end)
                    $(ctx.vars.cs) = $(s.state)
                    @goto exit
                end
            end
        else
            :()
        end
        =#
        
        # If no inputs match, then we set cs = -cs to signal error, and go to exit
        default = :($(ctx.vars.cs) = $(-s.state); @goto exit)

        # For each edge in optimized order, check if the conditions for taking that edge
        # is met. If so, go to the edge's actions if it has any actions, else go directly
        # to the destination state
        dispatch_code = foldr(default, optimize_edge_order(non_simd)) do edge, els
            e, t = edge
            if isempty(e.actions)
                then = :(@goto $(Symbol("state_", t.state)))
            else
                then = :(@goto $(action_label[t][action_names(e.actions)]))
            end
            return Expr(:if, generate_condition_code(ctx, e, actions), then, els)
        end

        # Here we simply add the code created above to the list of expressions
        append_code!(block, quote
            @label $(Symbol("state_case_", s.state))
            $(simd_code)
            $(ctx.vars.byte) = @inbounds getindex($(ctx.vars.mem), $(ctx.vars.p))
            $(dispatch_code)
        end)
        push!(blocks, block)
    end

    # In the beginning of the code generated here, the machine may not be in start state 1.
    # E.g. it may be resuming. So, we generate a list of if-else statements that simply check
    # the starting state, then directly goto that state.
    # In cases where the starting state is hardcoded as a constant, (which is quite often!)
    # hopefully the Julia compiler will optimize this block away.
    enter_code = foldr(:(@goto exit), 1:machine.n_states) do s, els
        return Expr(:if, :($(ctx.vars.cs) == $(s)), :(@goto $(Symbol("state_case_", s))), els)
    end

    # When EOF, go through a list of if/else statements: If cs == 1, do this, elseif
    # cs == 2 do that etc
    eof_action_code = rewrite_special_macros(;
        ctx=ctx,
        ex=generate_eof_action_code(ctx, machine, actions),
        at_eof=true,
        cs=nothing
    )

    # Check the final state is an accept state, in an efficient manner
    final_state_code = generate_final_state_mem_code(ctx, machine)

    # This is an overview of the final code structure
    return quote
        $(ctx.vars.mem) = $(SizedMemory)($(ctx.vars.data))
        if $(ctx.vars.p) > $(ctx.vars.p_end)
            @goto exit
        end
        $(enter_code)
        $(Expr(:block, blocks...))
        @label exit
        if is_eof && $(ctx.vars.p) > $(ctx.vars.p_end) && $(final_state_code)
            $(eof_action_code)
            $(ctx.vars.cs) = 0
        end
    end
end


function append_code!(block::Expr, code::Expr)
    @assert block.head == :block
    @assert code.head == :block
    append!(block.args, code.args)
    return block
end

# Note: This function has been carefully crafted to produce (nearly) optimal
# assembly code for AVX2-capable CPUs. Change with great care.

# Temporarily disabled because I've come to the realization that Julia does not
# yet make it possible to robustly check what CPU instructions the user has available
# See related issue
#=
function generate_simd_loop(ctx::CodeGenContext, bs::ByteSet)
    # ScanByte finds first byte in a byteset. We want to find first
    # byte NOT in this byteset, as this is where we can no longer skip ahead to
    byteset = ~ScanByte.ByteSet(bs)
    bsym = gensym()
    quote
        # We wrap this in an Automa function, because otherwise the generated code
        # would have a reference to ScanByte, which the user may not have imported.
        # But they surely have imported Automa.
        $bsym = Automa.loop_simd(
            $(ctx.vars.mem).ptr + $(ctx.vars.p) - 1,
            ($(ctx.vars.p_end) - $(ctx.vars.p) + 1) % UInt,
            Val($byteset)
        )
        $(ctx.vars.p) = if $bsym === nothing
            $(ctx.vars.p_end) + 1
        else
            $(ctx.vars.p) + $bsym - 1
        end
    end
end

# Necessary wrapper function, see comment in `generate_simd_loop`
@inline function loop_simd(ptr::Ptr, len::UInt, valbs::Val)
    ScanByte.memchr(ptr, len, valbs)
end
=#

# Make if/else statements for each state that is an acceptable end state, and execute
# the actions attached with ending in this state.
function generate_eof_action_code(ctx::CodeGenContext, machine::Machine, actions::Dict{Symbol,Expr})
    return foldr(:(), machine.eof_actions) do s_as, els
        s, as = s_as
        action_code = rewrite_special_macros(;
            ctx=ctx,
            ex=generate_action_code(action_names(as), actions),
            at_eof=true,
            cs=nothing
        )
        Expr(:if, state_condition(ctx, s), action_code, els)
    end
end

function generate_action_code(list::ActionList, actions::Dict{Symbol,Expr})
    return generate_action_code(action_names(list), actions)
end

function generate_action_code(names::Vector{Symbol}, actions::Dict{Symbol,Expr})
    return Expr(:block, (actions[n] for n in names)...)
end

function generate_getbyte_code(ctx::CodeGenContext)
    return generate_getbyte_code(ctx, ctx.vars.byte, 0)
end

function generate_getbyte_code(ctx::CodeGenContext, varbyte::Symbol, offset::Int)
    :($(varbyte) = $(ctx.getbyte)($(ctx.vars.mem), $(ctx.vars.p) + $(offset)))
end

function state_condition(ctx::CodeGenContext, s::Int)
    return :($(ctx.vars.cs) == $(s))
end

function generate_condition_code(ctx::CodeGenContext, edge::Edge, actions::Dict{Symbol,Expr})
    labelcode = generate_membership_code(ctx.vars.byte, edge.labels)
    precondcode = foldr(:(true), edge.precond) do p, ex
        name, value = p
        if value == BOTH
            ex1 = :(true)
        elseif value == TRUE
            ex1 = :( $(actions[name]))
        elseif value == FALSE
            ex1 = :(!$(actions[name]))
        else
            ex1 = :(false)
        end
        return Expr(:&&, ex1, ex)
    end
    return :($(labelcode) && $(precondcode))
end

# Check whether the final state belongs to `machine.final_states`.
# We simply unroll a bitvector and check for membership in that
function generate_final_state_mem_code(ctx::CodeGenContext, machine::Machine)
    # First create the bitvector, a dense vector of bits that are 1 for being
    # an accept state, and 0 for not. It's offset by `offset` bits.
    offset = minimum(machine.final_states)
    NBITS = 8*sizeof(UInt)
    len = length(offset:maximum(machine.final_states))
    uints = zeros(UInt, cld(len, NBITS))
    for state in machine.final_states
        arr_off, bit_off = divrem(state - offset, 8*sizeof(UInt))
        uints[arr_off + 1] = uints[arr_off + 1] | (1 << bit_off)
    end
    # For each uint in the vector, we check if CS in in the corresponding state
    ors = foldr(:(false), enumerate(uints)) do (i, u), oldx
        newx = quote
            (&)(
                $(ctx.vars.cs) < $(i * NBITS + offset),
                isodd($u >>> (($(ctx.vars.cs) - $offset) & $(NBITS-1)))
            )
        end
        Expr(:||, newx, oldx)
    end
    # Current state is at least minimum final state
    return Expr(:&&, :($(ctx.vars.cs) > $(offset - 1)), ors)
end

# Be careful trying to optimize this, LLVM creates insanely efficient code
# using this. Be sure to benchmark any improvements
function generate_membership_code(var::Symbol, set::ByteSet)
    min, max = minimum(set), maximum(set)
    @assert min isa UInt8 && max isa UInt8
    if max - min + 1 == length(set)
        # contiguous
        if min == max
            return :($(var) == $(min))
        else
            return :($(var) in $(min:max))
        end
    else
        return foldr((range, cond) -> Expr(:||, :($(var) in $(range)), cond),
                     :(false),
                     sort(range_encode(set), by=length, rev=true))
    end
end

# Create a user-friendly informative error if a bad input is seen.
# Defined in machine.jl, see that file.
function generate_input_error_code(ctx::CodeGenContext, machine::Machine)
    byte_symbol = gensym()
    vars = ctx.vars
    return quote
        if $(vars.cs) != 0
            $(vars.cs) = -abs($(vars.cs)) 
            $byte_symbol = $(vars.p) > $(vars.p_end) ? nothing : $(vars.byte)
            Automa.throw_input_error($(machine), -$(vars.cs), $byte_symbol, $(vars.mem), $(vars.p))
        end
    end
end

# Add a warning if users go down a rabbit hole trying to figure out what these macros
# expand to.
# See the function `rewrite_special_macros` below, where the expansion happens
const WARNING_STRING = """This string comes from the expansion of a fake macro in Automa.jl.
It is intercepted and expanded by Automa's own compiler, not by the Julia compiler.
Search for this string in the Automa source code to learn more."""

"""
    @escape()

Pseudomacro. When encountered during `Machine` execution, the machine will stop executing.
This is useful to interrupt the parsing process, for example to emit a record during parsing
of a larger file.
`p` will be advanced as normally, so if `@escape` is hit on `B` during parsing of `"ABC"`,
the next byte will be `C`.
"""
macro escape()
    :($WARNING_STRING)
end

"""
    @mark()

Pseudomacro, to be used with IO-parsing Automa functions.
This macro will "mark" the position of `p` in the current buffer.
The marked position will not be flushed from the buffer after being consumed.
For example, Automa code can call `@mark()` at the beginning of a large string,
then when the string is exited at position `p`,
it is guaranteed that the whole string resides in the buffer at positions `markpos():p-1`.
"""
macro mark()
    :($WARNING_STRING)
end

"""
    unmark()

Pseudomacro. Removes the mark from the buffer. This allows all previous data to
be cleared from the buffer.

See also: [`@mark`](@ref), [`@markpos`](@ref)
"""
macro unmark()
    :($WARNING_STRING)
end

"""
    markpos()

Pseudomacro. Get the position of the mark in the buffer.

See also: [`@mark`](@ref), [`@markpos`](@ref)
"""
macro markpos()
    :($WARNING_STRING)
end

"""
    bufferpos()

Pseudomacro. Returns the integer position of the current `TranscodingStreams`
buffer (only used with the `generate_reader` function).

# Example
```
# Inside some Automa action code
@setbuffer()
description = sub_parser(stream)
p = @bufferpos()
```

See also: [`@setbuffer`](@ref)
"""
macro bufferpos()
    :($WARNING_STRING)
end

"""
    relpos(p)

Automa pseudomacro. Return the position of `p` relative to `@markpos()`.
Equivalent to `p - @markpos() + 1`.
This can be used to mark additional points in the stream when the mark is set,
after which their action position can be retrieved using `abspos(x)`.

Behaviour is undefined if mark has not yet been set.

# Example usage:
```
# In one action
identifier_pos = @relpos(p)

# Later, in a different action
identifier = data[@abspos(identifier_pos):p]
```

See also: [`@abspos`](@ref)
"""
macro relpos(p)
    :($WARNING_STRING)
end

"""
    abspos(p)

Automa pseudomacro. Used to obtain the actual position of a relative position
obtained from `@relpos`. See [`@relpos`](@ref) for more details.

Behaviour is undefined if mark has not yet been set.
"""
macro abspos(p)
    :($WARNING_STRING)
end

"""
    setbuffer()

Updates the buffer position to match `p`.
The buffer position is syncronized with `p` before and after calls to
functions generated by `generate_reader`.
`@setbuffer()` can be used to the buffer before calling another parser.

# Example
```
# Inside some Automa action code
@setbuffer()
description = sub_parser(stream)
p = @bufferpos()
```

See also: [`@bufferpos`](@ref)
"""
macro setbuffer()
    :($WARNING_STRING)
end

# The reason we have this function is because we don't want to expose too deep
# internals of TranscodingStream buffers to the final user, but the user needs to
# inject code that operates on buffers into Automa. So, we need to abstract it.
# Maybe they should have been ordinary functions... (TODO)
# @escape is an exception, this does require code generation that touches into
# the internals of machine execution
function rewrite_special_macros(;
    ctx::CodeGenContext,
    ex::Expr,
    # nothing if code is expanded outside machine execution.
    at_eof::Union{Bool, Nothing},
    # nothing if table generator, else Int
    cs::Union{Int, Nothing}
)
    args = []
    for arg in ex.args
        special_macro = special_macro_type(arg)
        if special_macro isa Symbol
            expr = if special_macro == Symbol("@escape")
                if at_eof === nothing
                    error(
                        "Special macro @escape can only be used in `actions`, ",
                        "and not in e.g. `initcode` or other such user-injected code"
                    )
                # If we're at eof, machine is already stopped. 
                elseif at_eof
                    quote nothing end
                else
                    # If machine is a table generator, cs is already set, and the machine
                    # execution is a while loop we need to break
                    if cs === nothing
                        quote
                            $(ctx.vars.p) += 1
                            break
                        end
                    # If machine is a goto generator, cs is only set when we exit the
                    # machine, and we must exit it by @goto exit
                    else
                        quote
                            $(ctx.vars.cs) = $(cs)
                            $(ctx.vars.p) += 1
                            @goto exit
                        end
                    end
                end
            elseif special_macro == Symbol("@mark")
                quote $(ctx.vars.buffer).markpos = $(ctx.vars.p) end
            elseif special_macro == Symbol("@unmark")
                quote $(ctx.vars.buffer).markpos = 0 end
            elseif special_macro == Symbol("@markpos")
                quote $(ctx.vars.buffer).markpos end
            elseif special_macro == Symbol("@bufferpos")
                quote $(ctx.vars.buffer).bufferpos end
            elseif special_macro == Symbol("@setbuffer")
                quote $(ctx.vars.buffer).bufferpos = $(ctx.vars.p) end
            else
                @assert false
            end
            push!(args, expr)
        elseif special_macro isa Tuple{Symbol, Any}
            (sym, arg) = special_macro
            expr = if sym == Symbol("@relpos")
                quote $(arg) - $(ctx.vars.buffer).markpos + 1 end
            elseif sym == Symbol("@abspos")
                quote $(arg) + $(ctx.vars.buffer).markpos - 1 end
            else
                @assert false
            end
            push!(args, expr)
        elseif isa(arg, Expr)
            push!(args, rewrite_special_macros(;ctx=ctx, ex=arg, at_eof=at_eof, cs=cs))
        else
            push!(args, arg)
        end
    end
    return Expr(ex.head, args...)
end

function special_macro_type(arg)
    (arg isa Expr && arg.head == :macrocall) || return nothing
    sym = arg.args[1]
    if sym == Symbol("@escape") ||
        sym == Symbol("@mark") ||
        sym == Symbol("@unmark") ||
        sym == Symbol("@markpos") ||
        sym == Symbol("@bufferpos") ||
        sym == Symbol("@setbuffer")

        if any(view(arg.args, 2:lastindex(arg.args))) do a
                !(a isa LineNumberNode)
            end
            error("Automa pseudomacro $(sym) used with arguments: Use it like this: `$(sym)()`")
        end
        return sym
    elseif sym == Symbol("@relpos") || sym == Symbol("@abspos")
        non_linenumber_args = filter!(a -> !(a isa LineNumberNode), arg.args[2:end])
        if length(non_linenumber_args) != 1
            error(
                "Automa pseudomacro $(sym) should be used with exactly 1 argument, " *
                "got $(non_linenumber_args)"
            )
        end
        return (sym, only(non_linenumber_args))
    end
    return nothing
end

function isescape(arg)
    return arg isa Expr && arg.head == :macrocall && arg.args[1] == Symbol("@escape")
end

# Debug actions just pushes the action names into a vector called "logger".
# this exists as a convenience method to allow the user to set actions = :debug
# in generate_exec_code
function debug_actions(machine::Machine)
    function log_expr(name)
        return :(push!(logger, $(QuoteNode(name))))
    end
    return Dict{Symbol,Expr}(name => log_expr(name) for name in machine_names(machine))
end

"If possible, remove self-simd edge."
function peel_simd_edge(node)::Tuple{Union{Nothing, Edge}, Vector{Tuple{Edge, Node}}}
    non_simd = Tuple{Edge, Node}[]
    simd = nothing
    # A simd-edge has no actions or preconditions, and its source is same as destination.
    # that means the machine can just skip ahead
    for (e, t) in node.edges
        if t === node && isempty(e.actions) && isempty(e.precond)
            # There should only be 1 SIMD edge possible, if not, the machine
            # was not properly optimized by Automa, since SIMD edges should be
            # collapsable, as they have the same actions, preconditions and target node,
            # namely none, none and self.
            @assert simd === nothing
            simd = e
        else
            push!(non_simd, (e, t))
        end
    end
    return simd, non_simd
end
    
# Sort edges by its size in descending order.
function optimize_edge_order(edges)
    return sort!(copy(edges), by=e->length(e[1].labels), rev=true)
end

# Generic foldr. We have this here because using Base's foldr requires the iterator
# to have a reverse method, whereas this one doesn't (but is much less efficient)
function foldr(op::Function, x0, xs)
    function rec(xs, s)
        if s === nothing
            return x0
        else
            return op(s[1], rec(xs, iterate(xs, s[2])))
        end
    end
    return rec(xs, iterate(xs))
end
