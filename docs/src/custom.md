```@meta
CurrentModule = Automa
DocTestSetup = quote
    using TranscodingStreams
    using Automa
end
```

# Customizing Automa's code generation
Automa offers a few ways of customising the created code.
Note that the precise code generated by automa is considered an implementation detail,
and as such is subject to change without warning.
Only the overall behavior, i.e. the "DFA simulation" can be considered stable.

Nonetheless, it is instructive to look at the code generated for the machine in the "parsing from a buffer" section.
I present it here cleaned up and with comments for human inspection.

```julia
# Initialize variables used in the code below
byte::UInt8 = 0x00
p::Int = 1
p_end::Int = sizeof(data)
p_eof::Int = p_end
cs::Int = 1

# Turn the input buffer into SizedMemory, to load data from pointer
GC.@preserve data begin
mem::Automa.SizedMemory = (Automa.SizedMemory)(data)

# For every input byte:
while p ≤ p_end && cs > 0
    # Load byte
    byte = mem[p]

    # Load the action, to execute, if any, by looking up in a table
    # using the current state (cs) and byte
    @inbounds var"##292" = Int((Int8[0 0 … 0 0; 0 0 … 0 0; … ; 0 0 … 0 0; 0 0 … 0 0])[(cs - 1) << 8 + byte + 1])

    # Look up next state. If invalid input, next state is negative current state
    @inbounds cs = Int((Int8[-1 -2 … -5 -6; -1 -2 … -5 -6; … ; -1 -2 … -5 -6; -1 -2 … -5 -6])[(cs - 1) << 8 + byte + 1])

    # Check each possible action looked up above, and execute it
    # if it is not zero
    if var"##292" == 1
        pos = p
    elseif var"##292" == 2
        header = String(data[pos:p - 1])
    elseif if var"##292" == 3
        append!(buffer, data[pos:p - 1])
    elseif var"##292" == 4
        seq = Seq(header, String(buffer))
        push!(seqs, seq)
    end

    # Increment position by 1
    p += 1

    # If we're at end of input, and the current state in in an accept state:
    if p > p_eof ≥ 0 && cs > 0 && (cs < 65) & isodd(0x0000000000000021 >>> ((cs - 1) & 63))
        # What follows is a list of all possible EOF actions.

        # If state is state 6, execute the appropriate action
        # tied to reaching end of input at this state
        if cs == 6
            seq = Seq(header, String(buffer))
            push!(seqs, seq)
            cs = 0

    # Else, if the state is < 0, we have taken a bad input (see where cs was updated)
    # move position back by one to leave it stuck where it found bad input
    elseif cs < 0
        p -= 1
    end

    # If cs is not 0, the machine is in an error state.
    # Gather some information about machine state, then throw an error
    if cs != 0
        cs = -(abs(cs))
        var"##291" = if p_eof > -1 && p > p_eof
            nothing
        else
            byte
        end
        Automa.throw_input_error($machine, -cs, var"##291", mem, p)
    end
end
end # GC.@preserve
```

## Using `CodeGenContext`
The `CodeGenContext` (or ctx, for short) struct is a collection of settings used to customize code creation.
If not passed to the code generator functions, a default `CodeGenContext` is used.

### Variable names
One obvious place to customize is variable names.
In the code above, for example, the input bytes are named `byte`.
What if you have another variable with that name?

The ctx contains a `.vars` field with a `Variables` object, which is just a collection of names used in generated code.
For example, to rename `byte` to `u8` in the generated code, you first create the appropriate ctx,
then use the ctx to make the code.

```julia
ctx = CodeGenContext(vars=Automa.Variables(byte=:u8))
code = generate_code(ctx, machine, actions)
```

### Other options
* The `clean` option strips most linenumber information from the generated code, if set to true.
* `getbyte` is a function that is called like this `getbyte(data, p)` to obtain `byte` in the main loop.
  This is usually just `Base.getindex`, but can be customised to be an arbitrary function.

### Code generator
The code showed at the top of this page is code made with the table code generator.
Automa also supports creating code using the goto code generator instead of the default table generator.
The goto generator creates code with the following properties:
* It is much harder to read than table code
* The code is much larger
* It does not use boundschecking
* It does not allow customizing `getbyte`
* It is much faster than the table generator

Normally, the table generator is good enough, but for performance sensitive applications,
the goto generator can be used.

## Optimising the previous example
Let's try optimising the previous FASTA parsing example.
My original code did 300 MB/s.

To recap, the `Machine` was:

```jldoctest custom1; output = false
machine = let
    header = onexit!(onenter!(re"[a-z]+", :mark_pos), :header)
    seqline = onexit!(onenter!(re"[ACGT]+", :mark_pos), :seqline)
    record = onexit!(re">" * header * '\n' * rep1(seqline * '\n'), :record)
    compile(rep(record))
end
@assert machine isa Automa.Machine

# output

```

The first improvement is to the algorithm itself: Instead of of parsing to a vector of `Seq`,
I'm simply going to index the input data, filling up an existing vector of:

```jldoctest custom1; output = false
struct SeqPos
    offset::Int
    hlen::Int32
    slen::Int32
end

# output

```

The idea here is to remove as many allocations as possible.
This will more accurately show the speed of the DFA simulation, which is now the bottleneck.
The actions will therefore be 

```jldoctest custom1; output = false
actions = Dict(
    :mark_pos => :(pos = p),
    :header => :(hlen = p - pos),
    :seqline => :(slen += p - pos),
    :record => quote
        seqpos = SeqPos(offset, hlen, slen)
        nseqs += 1
        seqs[nseqs] = seqpos
        offset += hlen + slen
        slen = 0
    end
);

@assert actions isa Dict

# output

```

With the new variables such as `slen`, we need to update the function code as well:
```jldoctest custom1; output = false
@eval function parse_fasta(data)
    pos = slen = hlen = offset = nseqs = 0
    seqs = Vector{SeqPos}(undef, 400000)
    $(generate_code(machine, actions))
    return seqs
end

# output
parse_fasta (generic function with 1 method)
```

This parses a 45 MB file in about 100 ms in my laptop, that's 450 MB/s.
Now let's try the exact same, except with the code being generated by:

`$(generate_code(CodeGenContext(generator=:goto), machine, actions))`

Now the code parses the same 45 MB FASTA file in 11.14 miliseconds, parsing at about 4 GB/s.

## Reference

```@docs
Automa.CodeGenContext
Automa.Variables
```