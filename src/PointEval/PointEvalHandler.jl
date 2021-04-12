struct PointEvalHandler{dim, C, T, U}
    dh::Union{MixedDofHandler{dim, C, T}, DofHandler{dim, C, T}}
    cells::Vector{Int}
    cellvalues::Vector{U}
end

# TODO rewrite this like below
function PointEvalHandler(dh::DofHandler{dim, C, T}, interpolation::Interpolation{dim, S}, points::AbstractVector{Vec{dim, T}}) where {dim, C, S, T<:Real}
    grid = dh.grid
    dummy_cell_itp_qr = QuadratureRule{dim, S}(1)
    dummy_face_qr = QuadratureRule{dim-1, S}(1)
    cellvalues = CellScalarValues(dummy_cell_itp_qr, interpolation)
    facevalues = FaceScalarValues(dummy_face_qr, interpolation)
    points_array = [(i, p) for (i, p) in enumerate(points)]
    cells_of_points = Vector{Int}(undef, length(points))
    cellvalues_of_points = Vector{typeof(cellvalues)}(undef, length(points))

    for cell in 1:length(grid.cells)
        cell_coords = getcoordinates(grid, cell)
        face_nodes = faces(grid.cells[cell])
        nodes_on_faces = [grid.nodes[fn[1]] for fn in face_nodes]
        deletions = []
        for (j, ipoint) in enumerate(points_array)
            i, point = ipoint
            if is_point_inside_cell(cell_coords, point, facevalues, nodes_on_faces)
                push!(deletions, j)
                local_coordinate = find_local_coordinate(interpolation, cell_coords, point)
                point_qr = QuadratureRule{2, S, T}([1], [local_coordinate])
                cells_of_points[i] = cell
                # since these are unique for each point to evaluate, we need to create a cellvalue for each point anyway, so we might as well do it all at once
                cellvalues = CellScalarValues(point_qr, interpolation)
                reinit!(cellvalues, cell_coords)
                cellvalues_of_points[i] = cellvalues
            end
        end
        deleteat!(points_array, deletions)
    end
    if length(points_array) > 0
        println(points_array)
        error("Did not find cells for all points")
    end
    return PointEvalHandler(dh, cells_of_points, cellvalues_of_points)
end

function PointEvalHandler(dh::MixedDofHandler{dim, T}, func_interpolations::Vector{<:Interpolation{dim, S}},
    points::AbstractVector{Vec{dim, T}}, geom_interpolations::Vector{<:Interpolation{dim, S}}=func_interpolations) where {dim, S, T<:Real}

    grid = dh.grid
    # set up tree structure for finding nearest nodes to points
    kdtree = KDTree([node.x for node in grid.nodes])
    nearest_nodes, dists = knn(kdtree, points, 3, true) #TODO 3 is a random value, it shouldn't matter because likely the nearest node is the one we want

    cells = Vector{Int}(undef, length(points))
    pvs = Vector{PointScalarValues{dim, T}}(undef, length(points))
    node_cell_dicts = [_get_node_cell_map(grid, fh.cellset) for fh in dh.fieldhandlers]

    for point_idx in 1:length(points)
        cell_found = false
        for (fh_idx, fh) in enumerate(dh.fieldhandlers)
            node_cell_dict = node_cell_dicts[fh_idx]
            func_interpol = func_interpolations[fh_idx]
            geom_interpol = geom_interpolations[fh_idx]
            # loop over points
            for node in nearest_nodes[point_idx], cell in get(node_cell_dict, node, [0])
                # if node is not part of the fieldhandler, try the next node
                cell == 0 ? continue : nothing

                cell_coords = getcoordinates(grid, cell)
                if point_in_cell(geom_interpol, cell_coords, points[point_idx])
                    cell_found = true
                    conv, local_coordinate = find_local_coordinate(geom_interpol, cell_coords, points[point_idx])
                    point_qr = QuadratureRule{dim, S, T}([1], [local_coordinate])
                    cells[point_idx] = cell
                    # since these are unique for each point to evaluate, we need to create a cellvalue for each point anyway, so we might as well do it all at once
                    pv = PointScalarValues(point_qr, func_interpol)
                    pvs[point_idx] = pv
                    break
                end
            end
        end
        cell_found == false && error("No cell found for point $(points[point_idx]), index $point_idx.")
    end
    return PointEvalHandler(dh, cells, pvs)
end

# check if point is inside a cell based on physical coordinate
function point_in_cell(geom_interpol::Interpolation{dim,shape,order}, cell_coordinates, global_coordinate) where {dim, shape, order}
    converged, x_local = find_local_coordinate(geom_interpol, cell_coordinates, global_coordinate)
    if converged
        return _check_isoparametric_boundaries(shape, x_local)
    else
        return false
    end
end

# check if point is inside a cell based on isoparametric coordinate
function _check_isoparametric_boundaries(::Type{RefCube}, x_local::Vec{dim}) where {dim}
    inside = true
    for x in x_local
        x >= -1.0 && x<= 1.0 ? nothing : inside = false
    end
    return inside
end

# check if point is inside a cell based on isoparametric coordinate
function _check_isoparametric_boundaries(::RefTetrahedron, x_local::Vec{dim}) where {dim}
    inside = true
    for x in x_local
        x >= 0.0 && x<= 1.0 ? nothing : inside = false
    end
    return inside
end

function find_local_coordinate(interpolation, cell_coordinates, global_coordinate)
    """
    currently copied verbatim from https://discourse.julialang.org/t/finding-the-value-of-a-field-at-a-spatial-location-in-juafem/38975/2
    other than to make J dim x dim rather than 2x2
    """
    dim = length(global_coordinate)
    local_guess = zero(Vec{dim})
    n_basefuncs = getnbasefunctions(interpolation)
    max_iters = 10
    tol_norm = 1e-10
    converged = false
    for iter in 1:10
        N = Ferrite.value(interpolation, local_guess)

        global_guess = zero(Vec{dim})
        for j in 1:n_basefuncs
            global_guess += N[j] * cell_coordinates[j]
        end
        residual = global_guess - global_coordinate
        if norm(residual) <= tol_norm
            converged = true
            break
        end
        dNdξ = Ferrite.derivative(interpolation, local_guess)
        J = zero(Tensor{dim, dim})
        for j in 1:n_basefuncs
            J += cell_coordinates[j] ⊗ dNdξ[j]
        end
        local_guess -= inv(J) ⋅ residual
    end
    return converged, local_guess
end

function _get_node_cell_map(grid::Grid, cellset::Set{Int}=Set{Int64}(1:getncells(grid)))
    cell_dict = Dict{Int, Vector{Int}}()
    for cellidx in cellset
        for node in grid.cells[cellidx].nodes
            if haskey(cell_dict, node)
                push!(cell_dict[node], cellidx)
            else
                cell_dict[node] = [cellidx]
            end
        end
    end
    return cell_dict
end

# values in nodal order
# should be used when interpolating a field that lives only on a subdomain
# shouldn't be used for sub/superparametric approximations
function get_point_values(ph::PointEvalHandler, nodal_values::Vector{T}) where {T<:Union{Real, AbstractTensor}}
    # TODO check for sub/superparametric approximations
    # if interpolation !== default_interpolation(typeof(ch.dh.grid.cells[first(cellset)]))
    #     @warn("adding constraint to nodeset is not recommended for sub/super-parametric approximations.")
    # end
    length(nodal_values) == getnnodes(ph.dh.grid) || error("You must supply nodal values for all nodes of the Grid.")

    npoints = length(ph.cells)
    vals = Vector{T}(undef, npoints)
    for i in eachindex(ph.cells)
        node_idxs = getnodes(ph.dh.grid, ph.cells[i])
        vals[i] = function_value(ph.cellvalues, 1, nodal_values[node_idxs])
    end
    return vals
end

# can only be used if points are in cells that are part of dh (might be problematic when using L2Projection on a subset of cells)
function get_point_values(ph::PointEvalHandler, dof_values::Vector{T}, fieldname::Symbol)

    length(dof_values) == dh.ndofs || error("You must supply nodal values for all $(dh.ndofs) dofs in $dh.")
    _check_cellset_pointevaluation(ph, dh)

    npoints = length(ph.cells)
    vals = Vector{T}(undef, npoints)
    for i in eachindex(ph.cells)
        cell_dofs = celldofs(dh, ph.cells[i])
        #TODO damn, now we need to find the fieldhandler again. Should be stored!
        # want to be able to use this no matter if dof_values are coming from L2Projector or from simulation
        for fh in ph.dh
            if ph.cells[i] ∈ fh.cellset
                dofrange = dof_range(fh, fieldname)
            end
        end
        field_dofs = cell_dofs[dofrange]
        vals[i] = function_value(ph.cellvalues, 1, dof_values[field_dofs])
    end
    return vals
end

get_point_values(ph::PointEvalHandler, dof_values::Vector{T}, ::L2Projector) = get_point_values(ph, dof_values, :_)


# probably won't need this. Would error anyways on construction of ph
function _check_cellset_pointevaluation(ph::PointEvalHandler, dh::MixedDofHandler)
    cellset = Set{Int}{}
    for fh in dh.fieldhandlers
        union!(cellset, fh.cellset)
    end
    unique!(cellset)
    # check that all cells in ph exist in dh
    all_exist = !any(i->(i ∉ cellset), ph.cells)
    all_exist && error("All cells in the PointEvalHandler must be part of the MixedDofHandler. If you are working with a field on a subset of the cells, consider interpolating data based on nodal values instead of dof values.")
    return all_exist
end

# no need to check for DofHandler. It doesn't allow a field on a subset of its cells
