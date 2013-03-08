# Gurobi model

type Model
    env::Env
    ptr_model::Ptr{Void}
    
    function Model(env::Env, p::Ptr{Void})
        model = new(env, p)
        finalizer(model, free_model)
        model
    end
end

function free_model(model::Model)
    if model.ptr_model != C_NULL
        ccall(GRBfreemodel(), Void, (Ptr{Void},), model.ptr_model)
        model.ptr_model = C_NULL
    end
end

function copy(model::Model)
    pm::Ptr{Void} = C_NULL
    if model.ptr_model != C_NULL
        pm = ccall(GRBcopymodel(), Ptr{Void}, (Ptr{Void},), model.ptr_model)
        if pm == C_NULL
            error("Failed to copy a Gurobi model.")
        end
    end
    Model(model.env, pm)
end

function update_model!(model::Model)
    @assert model.ptr_model != C_NULL
    ret = ccall(GRBupdatemodel(), Cint, (Ptr{Void},), model.ptr_model)
    if ret != 0
        throw(GurobiError(model.env, ret))
    end
    nothing
end

convert(ty::Type{Ptr{Void}}, model::Model) = model.ptr_model::Ptr{Void}

#################################################
#
#  model attributes
#
#################################################

function get_int_attr(model::Model, name::ASCIIString)
    a = Array(Cint, 1)
    ret = ccall(GRBgetintattr(), Cint, 
        (Ptr{Void}, Ptr{Uint8}, Ptr{Cint}),
        model, name, a);
    if ret != 0
        throw(GurobiError(model.env, ret))
    end
    convert(Int, a[1])
end

function get_dbl_attr(model::Model, name::ASCIIString)
    a = Array(Float64, 1)
    ret = ccall(GRBgetdblattr(), Cint, 
        (Ptr{Void}, Ptr{Uint8}, Ptr{Float64}),
        model, name, a);
    if ret != 0
        throw(GurobiError(model.env, ret))
    end
    a[1]::Float64
end

function get_str_attr(model::Model, name::ASCIIString)
    a = Array(Ptr{Uint8}, 1)
    ret = ccall(GRBgetstrattr(), Cint, 
        (Ptr{Void}, Ptr{Uint8}, Ptr{Ptr{Uint8}}), 
        model, name, a)
    if ret != 0
        throw(GurobiError(model.env, ret))
    end
    bytestring(a[1])
end

function get_dbl_attrarray(model::Model, name::ASCIIString, start::Integer, len::Integer)
    # start is one-based
    
    r = Array(Float64, len)
    ret = ccall(GRBgetdblattrarray(), Cint, 
        (Ptr{Void}, Ptr{Uint8}, Cint, Cint, Ptr{Float64}), 
        model, name, start - 1, len, pointer(r))
    if ret != 0
        throw(GurobiError(model.env, ret))
    end
    r
end


macro grb_int_attr(fun, attrname)
    @eval $(fun)(model::Model) = get_int_attr(model, $(attrname))
end

macro grb_dbl_attr(fun, attrname)
    @eval $(fun)(model::Model) = get_dbl_attr(model, $(attrname))
end

macro grb_str_attr(fun, attrname)
    @eval $(fun)(model::Model) = get_str_attr(model, $(attrname))
end

@grb_int_attr num_vars     "NumVars"
@grb_int_attr num_constrs  "NumConstrs"
@grb_int_attr num_sos      "NumSOS"
@grb_int_attr num_qconstrs "NumQConstrs"
@grb_int_attr num_cnzs     "NumNZs"
@grb_int_attr num_qnzs     "NumQNZs"
@grb_int_attr num_qcnzs    "NumCQNZs"

@grb_str_attr model_name  "ModelName"

name(model::Model) = model_name(model)
sense(model::Model) = get_int_attr(model, "ModelSense") > 0 ? (:minimize) : (:maximize)

is_mip(model::Model) = get_int_attr(model, "IsMIP") != 0
is_qp(model::Model)  = get_int_attr(model, "IsQP") != 0
is_qcp(model::Model) = get_int_attr(model, "IsQCP") != 0

function model_type(model::Model) 
    is_qp(model)  ? (:QP)  :
    is_qcp(model) ? (:QCP) : (:LP)
end


# Show

function show(io::IO, model::Model)
    if model.ptr_model != C_NULL
        println(io, "Gurobi Model: $(name(model))")
        if is_mip(model)
            println(io, "    type   : $(model_type(model)) (MIP)")
        else
            println(io, "    type   : $(model_type(model))")
        end
        println(io, "    sense  : $(sense(model))")
        println(io, "    number of variables             = $(num_vars(model))")
        println(io, "    number of linear constraints    = $(num_constrs(model))")
        println(io, "    number of quadratic constraints = $(num_qconstrs(model))")
        println(io, "    number of sos constraints       = $(num_sos(model))")
    else
        println(io, "Gurobi Model: NULL")
    end
end


#################################################
#
#  model construction
#
#################################################

typealias Bounds Union(Nothing, Float64, Vector{Float64})

function gurobi_model(env::Env, name::ASCIIString)
    @assert is_valid(env)
    
    a = Array(Ptr{Void}, 1)
    ret = ccall(GRBnewmodel(), Cint, (
        Ptr{Void},  # env
        Ptr{Ptr{Void}},  # modelp
        Ptr{Uint8},  # name
        Cint,  # numvars
        Ptr{Float64}, # obj coeffs
        Ptr{Float64}, # lbounds
        Ptr{Float64}, # ubounds
        Ptr{Uint8},   # var types,
        Ptr{Ptr{Uint8}} # varnames
        ), 
        env, a, name, 0, 
        C_NULL, C_NULL, C_NULL, C_NULL, C_NULL
    )
    
    if ret != 0
        throw(GurobiError(env, ret))
    end
    
    Model(env, a[1])
end

# add variables

const GRB_CONTINUOUS = convert(Cchar, 'C')
const GRB_BINARY     = convert(Cchar, 'B')
const GRB_INTEGER    = convert(Cchar, 'I')

# add_var!

function add_var!(model::Model, vtype::Cchar, c::Float64, lb::Float64, ub::Float64)
    
    ret = ccall(GRBaddvar(), Cint, (
        Ptr{Void},    # model
        Cint,         # numnz
        Ptr{Cint},    # vind
        Ptr{Float64}, # vval
        Float64,      # obj
        Float64,      # lb
        Float64,      # ub
        Uint8,        # vtype
        Ptr{Uint8}    # name
        ), 
        model, 0, C_NULL, C_NULL, c, lb, ub, vtype, C_NULL)
        
    if ret != 0
        throw(GurobiError(model.env, ret))
    end
    nothing
end

add_var!(model::Model, vtype::Cchar, c::Float64) = add_var!(model, vtype, c, -Inf, Inf)

add_cvar!(model::Model, c::Float64, lb::Float64, ub::Float64) = add_var!(model, GRB_CONTINUOUS, c, lb, ub)
add_cvar!(model::Model, c::Float64) = add_cvar!(model, c, -Inf, Inf)


function add_vars!(model::Model, vtypes::Union(Cchar, Vector{Cchar}), c::Vector{Float64}, lb::Bounds, ub::Bounds)
    
    # check dimensions
    
    n = length(c)    
    dims_ok::Bool = true
    
    if isa(vtypes, Vector) && length(vtypes) != n
        dims_ok = false
    end

    if isa(lb, Vector) && length(lb) != n
        dims_ok = false
    end
    
    if isa(ub, Vector) && length(lb) != n
        dims_ok = false
    end
    
    if !dims_ok
        throw(ArgumentError("Inconsistent dimensions."))
    end

    # prepare vtypes
    
    vtypes_ptr::Ptr{Cchar} = C_NULL
    
    if isa(vtypes, Cchar)
        if vtypes != GRB_CONTINUOUS
            vtypes = fill(vtypes, n)
            vtypes_ptr = pointer(vtypes)
        end
    else
        vtypes_ptr = pointer(vtypes)
    end

    # prepare bounds
    
    lb_ptr::Ptr{Float64} = C_NULL
    ub_ptr::Ptr{Float64} = C_NULL
    
    if lb == nothing
        lb = fill(-Inf, n)
        lb_ptr = pointer(lb)
    elseif isa(lb, Float64)
        if lb != 0.
            lb = fill(lb, n)
        end
        lb_ptr = pointer(lb)
    else
        lb_ptr = pointer(lb)
    end
    
    if isa(ub, Float64)
        if !(ub == Inf)
            ub = fill(ub, n)
        end
        ub_ptr = pointer(ub)
    elseif isa(ub, Vector)
        ub_ptr = pointer(ub)
    end

    # main call

    ret = ccall(GRBaddvars(), Cint, (
        Ptr{Void},  # model
        Cint,       # numvars
        Cint,       # numnz
        Ptr{Cint},  # vbeg
        Ptr{Cint},  # vind
        Ptr{Float64}, # vval
        Ptr{Float64}, # obj
        Ptr{Float64}, # lb
        Ptr{Float64}, # ub
        Ptr{Cchar},   # vtypes
        Ptr{Ptr{Uint8}}, # varnames
        ), 
        model, n, 0, C_NULL, C_NULL, C_NULL, 
        c, lb_ptr, ub_ptr, vtypes_ptr, C_NULL)
        
    if ret != 0
        throw(GurobiError(model.env, ret))
    end
    nothing
end

add_cvars!(model::Model, c::Vector{Float64}, lb::Bounds, ub::Bounds) = add_vars!(model, GRB_CONTINUOUS, c, lb, ub)
add_cvars!(model::Model, c::Vector{Float64}) = add_cvars!(model, c, lb, ub)
