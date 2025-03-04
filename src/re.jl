# Regular Expression
# ==================

module RegExp

using Automa: ByteSet

# Head: What kind of regex, like cat, or rep, or opt etc.
# args: the content of the regex itself. Maybe should be type stable?
# actions: Julia code to be executed when matching the regex. See Automa docs
# when: a Precondition that is checked when every byte in the regex is matched.
# See comments on Precondition struct
"""
    RE(s::AbstractString)

Automa regular expression (regex) that is used to match a sequence of input bytes.
Regex should preferentially be constructed using the `@re_str` macro: `re"ab+c?"`.
Regex can be combined with other regex, strings or chars with `*`, `|`, `&` and `\\`:
* `a * b` matches inputs that matches first `a`, then `b`
* `a | b` matches inputs that matches `a` or `b`
* `a & b` matches inputs that matches `a` and `b`
* `a \\ b` matches input that mathes `a` but not `b`
* `!a` matches all inputs that does not match `a`.

Set actions to regex with [`onenter!`](@ref), [`onexit!`](@ref), [`onall!`](@ref)
and [`onfinal!`](@ref), and preconditions with [`precond!`](@ref).

# Example
```julia
julia> regex = (re"a*b?" | opt('c')) * re"[a-z]+";

julia> regex = rep1((regex \\ "aba") & !re"ca");

julia> regex isa RE
true

julia> compile(regex) isa Automa.Machine
true
```

See also: `[@re_str](@ref)`, `[@compile](@ref)`
"""
mutable struct RE
    head::Symbol
    args::Vector
    actions::Union{Nothing, Dict{Symbol, Vector{Symbol}}}
    precond_all::Union{Tuple{Symbol, Bool}, Nothing}
    precond_enter::Union{Tuple{Symbol, Bool}, Nothing}
end

function RE(head::Symbol, args::Vector)
    return RE(head, args, nothing, nothing, nothing)
end

RE(s::AbstractString) = parse(string(s))
RE(c::AbstractChar) = primitive(Char(c))

function actions!(re::RE)
    x = re.actions
    if x === nothing
        x = Dict{Symbol, Vector{Symbol}}()
        re.actions = x
    end
    x
end

"""
    onenter!(re::RE, a::Union{Symbol, Vector{Symbol}}) -> re

Set action(s) `a` to occur when reading the first byte of regex `re`.
If multiple actions are set by passing a vector, execute the actions in order.

See also: [`onexit!`](@ref), [`onall!`](@ref), [`onfinal!`](@ref)

# Example
```julia
julia> regex = re"ab?c*";

julia> regex2 = onenter!(regex, :entering_regex);

julia> regex === regex2
true
```
"""
onenter!(re::RE, v::Vector{Symbol}) = (actions!(re)[:enter] = v; re)
onenter!(re::RE, s::Symbol) = onenter!(re, [s])

"""
    onexit!(re::RE, a::Union{Symbol, Vector{Symbol}}) -> re

Set action(s) `a` to occur when reading the first byte no longer part of regex
`re`, or if experiencing an expected end-of-file.
If multiple actions are set by passing a vector, execute the actions in order.

See also: [`onenter!`](@ref), [`onall!`](@ref), [`onfinal!`](@ref)

# Example
```julia
julia> regex = re"ab?c*";

julia> regex2 = onexit!(regex, :exiting_regex);

julia> regex === regex2
true
```
"""
onexit!(re::RE, v::Vector{Symbol}) = (actions!(re)[:exit] = v; re)
onexit!(re::RE, s::Symbol) = onexit!(re, [s])

"""
    onfinal!(re::RE, a::Union{Symbol, Vector{Symbol}}) -> re

Set action(s) `a` to occur when the last byte of regex `re`.
If `re` does not have a definite final byte, e.g. `re"a(bc)*"`, where more "bc"
can always be added, compiling the regex will error after setting a final action.
If multiple actions are set by passing a vector, execute the actions in order.

See also: [`onenter!`](@ref), [`onall!`](@ref), [`onexit!`](@ref)

# Example
```julia
julia> regex = re"ab?c";

julia> regex2 = onfinal!(regex, :entering_last_byte);

julia> regex === regex2
true

julia> compile(onfinal!(re"ab?c*", :does_not_work))
ERROR: [...]
```
"""
onfinal!(re::RE, v::Vector{Symbol}) = (actions!(re)[:final] = v; re)
onfinal!(re::RE, s::Symbol) = onfinal!(re, [s])

"""
    onall!(re::RE, a::Union{Symbol, Vector{Symbol}}) -> re

Set action(s) `a` to occur when reading any byte part of the regex `re`.
If multiple actions are set by passing a vector, execute the actions in order.

See also: [`onenter!`](@ref), [`onexit!`](@ref), [`onfinal!`](@ref)

# Example
```julia
julia> regex = re"ab?c*";

julia> regex2 = onall!(regex, :reading_re_byte);

julia> regex === regex2
true
```
"""
onall!(re::RE, v::Vector{Symbol}) = (actions!(re)[:all] = v; re)
onall!(re::RE, s::Symbol) = onall!(re, [s])

"""
    precond!(re::RE, s::Symbol; [when=:enter], [bool=true]) -> re

Set `re`'s precondition to `s`. Before any state transitions to `re`, or inside
`re`, the precondition code `s` is checked to be `bool` before the transition is taken.

`when` controls if the condition is checked when the regex is entered (if `:enter`),
or at every state transition inside the regex (if `:all`)

# Example
```julia
julia> regex = re"ab?c*";

julia> regex2 = precond!(regex, :some_condition);

julia> regex === regex2
true
```
"""
function precond!(re::RE, s::Symbol; when::Symbol=:enter, bool::Bool=true)
    if when === :enter
        re.precond_enter = (s, bool)
    elseif when === :all
        re.precond_all = (s, bool)
    else
        error("`precond!` only takes :enter or :all in third position")
    end
    re
end

const Primitive = Union{RE, ByteSet, UInt8, UnitRange{UInt8}, Char, String, Vector{UInt8}}

function primitive(re::RE)
    return re
end

function primitive(set::ByteSet)
    return RE(:set, [set])
end

function primitive(byte::UInt8)
    return RE(:byte, [byte])
end

function primitive(range::UnitRange{UInt8})
    return RE(:range, [range])
end

function primitive(char::Char)
    return RE(:char, [char])
end

function primitive(str::String)
    return RE(:str, [str])
end

function primitive(bs::AbstractVector{UInt8})
    return RE(:bytes, collect(bs))
end

function cat(xs::Primitive...)
    return RE(:cat, [map(primitive, xs)...])
end

function alt(x::Primitive, xs::Primitive...)
    return RE(:alt, [primitive(x), map(primitive, xs)...])
end

function rep(x::Primitive)
    return RE(:rep, [primitive(x)])
end

function rep1(x::Primitive)
    return RE(:rep1, [primitive(x)])
end

function opt(x::Primitive)
    return RE(:opt, [primitive(x)])
end

function isec(x::Primitive, y::Primitive)
    return RE(:isec, [primitive(x), primitive(y)])
end

function diff(x::Primitive, y::Primitive)
    return RE(:diff, [primitive(x), primitive(y)])
end

function neg(x::Primitive)
    return RE(:neg, [primitive(x)])
end

function any()
    return primitive(0x00:0xff)
end

function ascii()
    return primitive(0x00:0x7f)
end

function space()
    return primitive(ByteSet([UInt8(c) for c in "\t\v\f\n\r "]))
end

Base.:*(re1::RE, re2::RE) = cat(re1, re2)
Base.:|(re1::RE, re2::RE) = alt(re1, re2)
Base.:&(re1::RE, re2::RE) = isec(re1, re2)
Base.:\(re1::RE, re2::RE) = diff(re1, re2)

for f in (:*, :|, :&, :\)
    @eval Base.$(f)(x::Union{AbstractString, AbstractChar}, re::RE) = $(f)(RE(x), re)
    @eval Base.$(f)(re::RE, x::Union{AbstractString, AbstractChar}) = $(f)(re, RE(x)) 
end

Base.:!(re::RE) = neg(re)

"""
    @re_str -> RE

Construct an Automa regex of type `RE` from a string.
Note that due to Julia's raw string escaping rules, `re"\\\\"` means a single backslash, and so does `re"\\\\\\\\"`, while `re"\\\\\\\\\\""` means a backslash, then a quote character.

Examples:
```julia
julia> re"ab?c*[def][^ghi]+" isa RE
true 
```

See also: [`RE`](@ref)
"""
macro re_str(str::String)
    parse(str)
end

const METACHAR = raw".*+?()[]\|-^"

# Parse a regular expression string using the shunting-yard algorithm.
function parse(str_::AbstractString)
    str = String(str_)
    # stacks
    operands = RE[]
    operators = Symbol[]

    function pop_and_apply!()
        op = pop!(operators)
        if op == :rep || op == :rep1 || op == :opt
            arg = pop!(operands)
            push!(operands, RE(op, [arg]))
        elseif op == :alt
            arg2 = pop!(operands)
            arg1 = pop!(operands)
            push!(operands, RE(:alt, [arg1, arg2]))
        elseif op == :cat
            arg2 = pop!(operands)
            arg1 = pop!(operands)
            push!(operands, RE(:cat, [arg1, arg2]))
        else
            error(op)
        end
    end

    cs = iterate(str)
    if cs === nothing
        return RE(:cat, [])
    end
    need_cat = false
    while cs !== nothing
        c, s = cs
        # @show c operands operators
        if need_cat && c ∉ ('*', '+', '?', '|', ')')
            while !isempty(operators) && prec(:cat) ≤ prec(last(operators))
                pop_and_apply!()
            end
            push!(operators, :cat)
        end
        need_cat = c ∉ ('|', '(')
        if c == '*'
            while !isempty(operators) && prec(:rep) ≤ prec(last(operators))
                pop_and_apply!()
            end
            push!(operators, :rep)
        elseif c == '+'
            while !isempty(operators) && prec(:rep1) ≤ prec(last(operators))
                pop_and_apply!()
            end
            push!(operators, :rep1)
        elseif c == '?'
            while !isempty(operators) && prec(:opt) ≤ prec(last(operators))
                pop_and_apply!()
            end
            push!(operators, :opt)
        elseif c == '|'
            while !isempty(operators) && prec(:alt) ≤ prec(last(operators))
                pop_and_apply!()
            end
            push!(operators, :alt)
        elseif c == '('
            push!(operators, :lparen)
        elseif c == ')'
            while !isempty(operators) && last(operators) != :lparen
                pop_and_apply!()
            end
            pop!(operators)
        elseif c == '['
            class, cs = parse_class(str, s)
            push!(operands, class)
            continue
        elseif c == '.'
            push!(operands, any())
        elseif c == '\\'
            if iterate(str, s) === nothing
                c = '\\'
            else
                c, s = unescape(str, s)
            end
            push!(operands, primitive(c))
        else
            push!(operands, primitive(c))
        end
        cs = iterate(str, s)
    end

    while !isempty(operators)
        pop_and_apply!()
    end

    @assert length(operands) == 1
    return first(operands)
end

# Operator's precedence.
function prec(op::Symbol)
    if op == :rep || op == :rep1 || op == :opt
        return 3
    elseif op == :cat
        return 2
    elseif op == :alt
        return 1
    elseif op == :lparen
        return 0
    else
        @assert false
    end
end

# Convert this to ASCII byte.
# Also accepts e.g. '\xff', but not a multi-byte Char
function as_byte(c::Char)
    u = reinterpret(UInt32, c)
    if u & 0x00ffffff != 0
        error("Char '$c' cannot be expressed as a single byte")
    else
        UInt8(u >> 24)
    end
end

# This parses things in square brackets, like [A-Za-z]
# When this function is entered, the initial '[' has already been
# consumed.
function parse_class(str, s)
    # The bool here is whether it's escaped
    chars = Tuple{Bool, Char}[]
    cs = iterate(str, s)
    # Main loop: Get all the characters into the `chars` variable
    while cs !== nothing
        c, s = cs
        if c == ']'
            # We are done with the class. Skip the ] char and break out.
            cs = iterate(str, s)
            break
        # Handle escape character
        elseif c == '\\'
            # If \ is the final char, throw error
            if iterate(str, s) === nothing
                error("missing ]")
            end
            # Else get the next char as escaped
            c, s = unescape(str, s)
            push!(chars, (true, c))
        else
            # Ordinary char: Just add it unescaped
            push!(chars, (false, c))
        end
        cs = iterate(str, s)
    end
    # If the first char is non-escaped ^, set head as cclass, meaning
    # inverted class, and remove the first char.
    if !isempty(chars) && !first(chars)[1] && first(chars)[2] == '^'
        head = :cclass
        popfirst!(chars)
    else
        head = :class
    end
    if isempty(chars)
        error("empty class")
    end

    args = []
    while !isempty(chars)
        c = popfirst!(chars)[2]
        # If the next two chars are "-X" for any X, then this is a range.
        # Create the right range and pop out the "-X"
        if length(chars) ≥ 2 && first(chars) == (false, '-')
            push!(args, as_byte(c):as_byte(chars[2][2]))
            popfirst!(chars)
            popfirst!(chars)
        else
            push!(args, as_byte(c):as_byte(c))
        end
    end
    return RE(head, args), cs
end

function unescape(str::String, s::Int)
    invalid() = throw(ArgumentError("invalid escape sequence"))
    ishex(b) = '0' ≤ b ≤ '9' || 'A' ≤ b ≤ 'F' || 'a' ≤ b ≤ 'f'
    cs = iterate(str, s)
    cs === nothing && invalid()
    c, s = cs
    if c == 'a'
        return '\a', s
    elseif c == 'b'
        return '\b', s
    elseif c == 't'
        return '\t', s
    elseif c == 'n'
        return '\n', s
    elseif c == 'v'
        return '\v', s
    elseif c == 'r'
        return '\r', s
    elseif c == 'f'
        return '\f', s
    elseif c == '0'
        return '\0', s
    elseif c ∈ METACHAR
        return c, s
    elseif c == 'x'
        cs1 = iterate(str, s)
        (cs1 === nothing || !ishex(cs1[1])) && invalid()
        cs2 = iterate(str, cs1[2])
        (cs2 === nothing || !ishex(cs2[1])) && invalid()
        c1, c2 = cs1[1], cs2[1]
        return first(unescape_string("\\x$(c1)$(c2)")), cs2[2]
    elseif c == 'u' || c == 'U'
        throw(ArgumentError("escaped Unicode sequence is not supported"))
    else
        throw(ArgumentError("invalid escape sequence: \\$(c)"))
    end
end

# This converts from compound regex to foundational regex.
# For example, rep1(x) is equivalent to x * rep(x).
function shallow_desugar(re::RE)
    head = re.head
    args = re.args
    if head == :rep1
        return RE(:cat, [args[1], rep(args[1])])
    elseif head == :opt
        return RE(:alt, [args[1], RE(:cat, [])])
    elseif head == :neg
        return RE(:diff, [rep(any()), args[1]])
    elseif head == :byte
        return RE(:set, [ByteSet(args[1])])
    elseif head == :range
        return RE(:set, [ByteSet(args[1])])
    elseif head == :class
        return RE(:set, [foldl(union, map(ByteSet, args), init=ByteSet())])
    elseif head == :cclass
        return RE(:set, [foldl(setdiff, map(ByteSet, args), init=ByteSet(0x00:0xff))])
    elseif head == :char
        bytes = convert(Vector{UInt8}, codeunits(string(args[1])))
        return RE(:cat, [RE(:set, [ByteSet(b)]) for b in bytes])
    elseif head == :str
        bytes = convert(Vector{UInt8}, codeunits(args[1]))
        return RE(:cat, [RE(:set, [ByteSet(b)]) for b in bytes])
    elseif head == :bytes
        return RE(:cat, [RE(:set, [ByteSet(b)]) for b in args])
    else
        if head ∉ (:set, :cat, :alt, :rep, :isec, :diff)
            error("cannot desugar ':$(head)'")
        end
        return RE(head, args)
    end
end

# Create a deep copy of the regex without any actions
function strip_actions(re::RE)
    args = [arg isa RE ? strip_actions(arg) : arg for arg in re.args]
    RE(re.head, args, Dict{Symbol, Vector{Symbol}}(), re.precond_enter, re.precond_all)
end

# Create a deep copy with the only actions being a :newline action
# on the \n chars
function set_newline_actions(re::RE)::RE
    # Normalise the regex first to make it simpler to work with
    if re.head ∈ (:rep1, :opt, :neg, :byte, :range, :class, :cclass, :char, :str, :bytes)
        re = shallow_desugar(re)
    end
    # After desugaring, the only type of regex that can directly contain a newline is the :set type
    # if it has that, we add a :newline action
    if re.head == :set
        set = only(re.args)::ByteSet
        if UInt8('\n') ∈ set
            re1 = RE(:set, [ByteSet(UInt8('\n'))], Dict(:enter => [:newline]), re.precond_enter, re.precond_all)
            if length(set) == 1
                re1
            else
                re2 = RE(:set, [setdiff(set, ByteSet(UInt8('\n')))], Dict{Symbol, Vector{Symbol}}(), re.precond_enter, re.precond_all)
                re1 | re2
            end
        else
            re
        end
    else
        args = [arg isa RE ? set_newline_actions(arg) : arg for arg in re.args]
        RE(re.head, args, Dict{Symbol, Vector{Symbol}}(), re.precond_enter, re.precond_all)
    end
end


end
