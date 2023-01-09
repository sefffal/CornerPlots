module PairPlots

export pairplot

using Makie: Makie
using Tables
using Printf
using KernelDensity: KernelDensity
using Contour: Contour as ContourLib
using OrderedCollections: OrderedDict
using Latexify: latexify
using StatsBase: fit, quantile, Histogram
using Distributions: pdf
using StaticArrays
using PolygonOps

"""
    AstractSeries

Represents some kind of series in PairPlots.
"""
abstract type AbstractSeries end


struct Series{T,K} <: AbstractSeries where {T,K}
    label::Union{Nothing,String,Makie.RichText,Makie.LaTeXString}
    table::T
    kwargs::K
end
"""
    Series(data; label=nothing, kwargs=...)

A data series in PairPlots. Wraps a Tables.jl compatible table.
You can optionally pass a label for this series to use in the plot legend.
Keyword arguments are forwarded to every plot call for this series.

Examples:
```julia
ser = Series(table; label="series 1", color=:red)
```
"""
function Series(data; label=nothing, kwargs...)
    if !Tables.istable(data)
        error("PairPlots expects a matrix or Tables.jl compatible table for each series.")
    end
    Series(label, data, kwargs)
end
"""
    Series(matrix::AbstractMatrix; label=nothing, kwargs...)

Convenience constructor to build a Series from an abstract matrix.
The columns are named accordingly to the axes of the Matrix (usually :1 though N).
"""
function Series(data::AbstractMatrix; label=nothing, kwargs...)
    column_labels = [Symbol(i) for i in axes(data,1)] 
    table = NamedTuple([
        collabel => col
        for (collabel, col) in zip(column_labels, eachcol(data))
    ])
    Series(label, table, kwargs)
end

""""
A type of PairPlots vizualization.
"""
abstract type VizType end

""""
A type of PairPlots vizualization that compares two variables.
"""
abstract type VizTypeBody <: VizType end

## Note: these are deliberately not concretely typed. They just store keyword arguments
## that will vary as the user is modifying plots. No point in specializing on them.

"""
    HexBin(;kwargs...)

Plot two variables against eachother using a Makie Hex Bin series.
`kwargs` are forwarded to the plot function and can be used to control
the number of bins and the appearance.
"""
struct HexBin <: VizTypeBody
    kwargs
    HexBin(;kwargs...) = new(kwargs)
end

"""
    Hist(;kwargs...)
    Hist(histprep_function; kwargs...)

Plot two variables against eachother using a 2D histogram heatmap.
`kwargs` are forwarded to the plot function and can be used to control
the number of bins and the appearance.

!!! note
    You can optionally pass a function to override how the histogram is calculated.
    It should have the signature: `prepare_hist(xs, ys, nbins)` and return
    a vector of horizontal bin centers, vertical bin centers, and a matrix of weights.

    !!! tip
        Your `prepare_hist` function it does not have to obey `nbins`
"""
struct Hist{T} <: VizTypeBody where T
    prepare_hist::T
    kwargs
    Hist(prepare_hist=prepare_hist;kwargs...) = new{typeof(prepare_hist)}(prepare_hist, kwargs)
end


"""
    Contour(;sigmas=1:2, kwargs...)

Plot two variables against eachother using a contour plot. The contours cover the area under a Gaussian
given by `sigmas`, which must be `<: AbstractVector`. `kwargs` are forwarded to the plot function and can
be used to control the appearance.

KernelDensity.jl is used to produce smoother contours.

!!! note
    Contours are calculated using Contour.jl and plotted as a Makie line series.

See also: Contourf
"""
struct Contour <: VizTypeBody
    sigmas
    kwargs
    Contour(;sigmas=1:2, kwargs...) = new(sigmas, kwargs)
end

"""
    Contourf(;sigmas=1:2, kwargs...)

Plot two variables against eachother using a filled contour plot. The contours cover the area under a Gaussian
given by `sigmas`, which must be `<: AbstractVector`. `kwargs` are forwarded to the plot function and can
be used to control the appearance.

KernelDensity.jl is used to produce smoother contours.

See also: Contour
"""
struct Contourf <: VizTypeBody
    sigmas
    kwargs
    Contourf(;sigmas=1:2, kwargs...) = new(sigmas, kwargs)
end

"""
    Scatter(;kwargs...)

Plot two variables against eachother using a scatter plot.`kwargs` are forwarded to the plot function and can
be used to control the appearance.
"""
struct Scatter <: VizTypeBody
    kwargs
    filtersigma
    Scatter(;filtersigma=nothing, kwargs...) = new(kwargs, filtersigma)
end


## Diagonals
""""
    VizTypeBody

A type of PairPlots vizualization that only shows one variable. Used 
for the plots along the diagonal.
"""
abstract type VizTypeDiag <: VizType end


"""
    MarginConfidenceLimits(;titlefmt="\$\\mathrm{%.2f^{+%.2f}_{-%.2f}}\$", kwargs...)
"""
struct MarginConfidenceLimits <: VizTypeDiag
    titlefmt::String
    kwargs
    function MarginConfidenceLimits(titlefmt="\$\\mathrm{%.2f^{+%.2f}_{-%.2f}}\$"; kwargs...)
        return new(titlefmt, kwargs)
    end
end

"""
    MarginHist(;kwargs...)
    MarginHist(histprep_function; kwargs...)

Plot a marginal histogram of a single variable along the diagonal of the grid.
`kwargs` are forwarded to the plot function and can be used to control
the number of bins and the appearance.

!!! tip
    You can optionally pass a function to override how the histogram is calculated.
    It should have the signature: `prepare_hist(xs, nbins)` and return
    a vector of bin centers and a vector of weights.

    !!! note
        Your `prepare_hist` function it does not have to obey `nbins`
"""
struct MarginHist{T} <: VizTypeDiag where T
    prepare_hist::T
    kwargs
    MarginHist(prepare_hist=prepare_hist;kwargs...) = new{typeof(prepare_hist)}(prepare_hist, kwargs)
end

"""
    MarginDensity(;kwargs...)

Plot the smoothed marginal density of a variable along the diagonal of the grid, using Makie's `density` 
function. `kwargs` are forwarded to the plot function and can be used to control
the appearance.
"""
struct MarginDensity <: VizTypeDiag
    kwargs
    MarginDensity(;kwargs...) = new(kwargs)
end


colnames(t::Series) = Tables.columnnames(t.table)


GridPosTypes = Union{Makie.Figure, Makie.GridPosition, Makie.GridSubposition}

"""
    pairplot(inputs...; figure=(;), kwargs...)

Convenience method to generate a new Makie figure with resolution (800,800)
and then call `pairplot` as usual. Returns the figure.

Example:
```julia
fig = pairplot(table)
```
"""
function pairplot(
    @nospecialize input...;
    figure=(;),
    kwargs...,
)

    # TODO: auto size figure based on the number of columns.
    # We need to resolve all the inputs first, so this fix will 
    # require inverting the pairplot method cascade to do inputs, 
    # then the grid/gridpos/figure argument last.
    fig = Makie.Figure(;
        resolution=(800, 800),
        figure...
    )
    pairplot(fig.layout, input...; kwargs...)
    return fig
end


"""
    pairplot(gridpos::Makie.GridPosition, inputs...; kwargs...)

Create a pair plot at a given grid position of a Makie figure.

Example
```julia
fig = Figure()
pairplot(fig[2,3], table)
fig
```
"""
function pairplot(
    gridpos::Makie.GridPosition,
    @nospecialize datapairs::Any...;
    kwargs...,
)
    grid = Makie.GridLayout(gridpos)
    pairplot(grid, datapairs...; kwargs...)
    return grid
end

"""
    pairplot(gridpos::Makie.GridLayout, inputs...; kwargs...)

Convenience function to create a reasonable pair plot given 
one or more inputs that aren't full specified.
Wraps input tables in PairPlots.Series() with a distinct color specified
for each series.

Here are the defaults applied for a single data table:
```julia
pairplot(fig[1,1], table) == # approximately the following:
pairplot(
    PairPlots.Series(table, color=Makie.RGBA(0., 0., 0., 0.5)) => (
        PairPlots.HexBin(colormap=Makie.cgrad([:transparent, :black]),bins=32),
        PairPlots.Scatter(filtersigma=2), 
        PairPlots.Contour(),
        PairPlots.MarginDensity(
            color=:transparent,
            strokecolor=:black,
            strokewidth=1.5f0
        ),
        PairPlots.MarginConfidenceLimits()
    )
)
```

Here are the defaults applied for 2 to 5 data tables:
```julia
pairplot(fig[1,1], table1, table2) == # approximately the following:
pairplot(
    PairPlots.Series(table1, color=Makie.wong_colors(0.5)[1]) => (
        PairPlots.Scatter(filtersigma=2), 
        PairPlots.Contourf(),
        PairPlots.MarginDensity(
            color=:transparent,
            strokewidth=2.5f0
        )
    ),
    PairPlots.Series(table2, color=Makie.wong_colors(0.5)[2]) => (
        PairPlots.Scatter(filtersigma=2), 
        PairPlots.Contourf(),
        PairPlots.MarginDensity(
            color=:transparent,
            strokewidth=2.5f0
        )
    ),
)
```
    
For 6 or more tables, the defaults are approximately:
```julia
PairPlots.Series(table1, color=Makie.wong_colors(0.5)[series_i]) => (
    PairPlots.Contour(sigmas=[1]),
    PairPlots.MarginDensity(
        color=:transparent,
        strokewidth=2.5f0
    )
)
```
"""
function pairplot(
    grid::Makie.GridLayout,
    @nospecialize datapairs::Any...;
    kwargs...,
)
    # Default to grayscale for a single series.
    # Otherwise fall back to cycling the colours ourselves.
    # The Makie color cycle functionality isn't quite flexible enough (but almost!).

    single_series_color = Makie.RGBA(0., 0., 0., 0.5)
    single_series_default_viz = (
        PairPlots.HexBin(colormap=Makie.cgrad([:transparent, :black]),bins=32),
        PairPlots.Scatter(filtersigma=2), 
        PairPlots.Contour(),
        PairPlots.MarginDensity(
            color=:transparent,
            strokecolor=:black,
            strokewidth=1.5f0
        ),
        PairPlots.MarginConfidenceLimits()
    )

    series_i = 0
    function SeriesDefaults(dat)
        series_i += 1
        wc = Makie.wong_colors(0.5)
        color = wc[mod1(series_i, length(wc))]
        return Series(dat; color, strokecolor=color)
    end
    multi_series_default_viz = (
        PairPlots.Scatter(filtersigma=2), 
        PairPlots.Contourf(),
        PairPlots.MarginDensity(
            color=:transparent,
            strokewidth=2.5f0
        )
    )
    many_series_default_viz = (
        PairPlots.Contour(sigmas=[1]),
        PairPlots.MarginDensity(
            color=:transparent,
            strokewidth=2.5f0
        )
    )

    if length(datapairs) == 1

        defaults1((data,vizlayers)::Pair) = Series(data; color=single_series_color) => vizlayers
        defaults1(series::Series) = series => single_series_default_viz
        defaults1(data::Any) = Series(data; color=single_series_color) => single_series_default_viz
        pairplot(grid, defaults1(first(datapairs)); kwargs...)
    elseif length(datapairs) <= 5
        defaults_upto5((data,vizlayers)::Pair) = SeriesDefaults(data) => vizlayers
        defaults_upto5(series::Series) = series => multi_series_default_viz
        defaults_upto5(data::Any) = SeriesDefaults(data) => multi_series_default_viz
        pairplot(grid, map(defaults_upto5, datapairs)...; kwargs...)
    else # More than 5 series
        defaults_morethan5((data,vizlayers)::Pair) = SeriesDefaults(data) => vizlayers
        defaults_morethan5(series::Series) = series => many_series_default_viz
        defaults_morethan5(data::Any) = SeriesDefaults(data) => many_series_default_viz
        pairplot(grid, map(defaults_morethan5, datapairs)...; kwargs...)
    end

    return
end

# Create a pairplot by plotting into a grid position of a figure.

"""
    pairplot(gridpos::Makie.GridLayout, inputs...; kwargs...)

Main PairPlots function. Create a pair plot by plotting into a grid
layout within a Makie figure.

Inputs should be one or more `Pair` of PairPlots.AbstractSeries => tuple of VizType.

Additional arguments:
* labels: customize the axes labels with a Dict of column name (symbol) to string, Makie rich text, or LaTeX string.
* diagaxis: customize the Makie.Axis of plots along the diagonal with a named tuple of keyword arguments.
* bodyaxis: customize the Makie.Axis of plots under the diagonal with a named tuple of keyword arguments.
* legend:  additional keyword arguments to the Legend constructor, used if one or more series are labelled.

You can of course also create your own Legend and inset it into the Figure for complete control. 
"""
function pairplot(
    grid::Makie.GridLayout,
    @nospecialize pairs::Pair{<:AbstractSeries}...;
    labels::AbstractDict{Symbol} = Dict{Symbol,Any}(),
    diagaxis=(;),
    bodyaxis=(;),
    legend=(;),
)
    # We support multiple series that may have disjoint columns
    # Get the ordered union of all table columns.
    columns = unique(Iterators.flatten(Iterators.map(colnames∘first, pairs)))

    # Map of column key to label text. 
    # By default, just latexify the column key but allow override.
    label_map = Dict(
        name => Makie.latexstring("\\mathrm{", latexify(name, env=:raw), "}")
        for name in columns
    )
    label_map = merge(label_map, Dict(labels))
   

    # Rather than computing limits in this version, let's try to rely on 
    # Makie doing a good job of linking axes.

    N = length(columns)

    # Keep lists of axes by row number and by column number.
    # We'll use these afterwards to link axes together.
    axes_by_row = Dict{Int,Vector{Makie.Axis}}()
    axes_by_col = Dict{Int,Vector{Makie.Axis}}()
    sizehint!(axes_by_col, N)
    sizehint!(axes_by_row, N)

    # Check if there are any diagonal vizualization layers
    anydiag_viz = mapreduce((|), pairs, init=false) do (series, vizlayers)
        any(v->isa(v, VizTypeDiag), vizlayers)
    end
    
    # Build grid of nxn plots
    for row_ind in 1:N, col_ind in 1:N

        # TODO: make this first condition optional to enable a full grid
        # Also skip diagonals if no diagonal viz layers
        if row_ind < col_ind || (row_ind==col_ind && !anydiag_viz)
            continue
        end
        
        colname_row = columns[row_ind]
        colname_col = columns[col_ind]

        if row_ind == col_ind
            kw = diagaxis
        else
            kw = bodyaxis
        end

        # Hide first row if no diagonal viz layers
        row_ind_fig = row_ind
        if !anydiag_viz
            row_ind_fig = row_ind - 1
        end

        ax = Makie.Axis(
            grid[row_ind_fig, col_ind];
            ylabel=label_map[colname_row],
            xlabel=label_map[colname_col],
            xgridvisible=false,
            ygridvisible=false,
            # Ensure any axis title that gets added doesn't break the tight layout
            alignmode = row_ind == 1 ? Makie.Inside() : Makie.Mixed(;left=nothing, right=nothing, bottom=nothing, top=Makie.Protrusion(0.0)),
            xautolimitmargin=(0f0,0f0),
            yautolimitmargin= row_ind == col_ind ? (0f0, 0.05f0) : (0f0,0f0),
            # User options
            kw...,
        )

        axes_by_col[col_ind]= push!(get(axes_by_col, col_ind, Makie.Axis[]), ax)
        if row_ind != col_ind
            axes_by_row[row_ind]= push!(get(axes_by_row, row_ind, Makie.Axis[]), ax)
        end

        # For each slot, loop through all series and fill it in accordingly.
        # We have two slot types: bodyplot, like a 3D histogram, and diagplot, along the diagonal
        for (series, vizlayers) in pairs
            cn = colnames(series)
            if colname_row in cn && colname_col in cn
                for vizlayer in vizlayers    
                    if row_ind == col_ind && vizlayer isa VizTypeDiag
                        diagplot(ax, vizlayer, series, colname_row)
                    elseif row_ind != col_ind && vizlayer isa VizTypeBody
                        bodyplot(ax, vizlayer, series, colname_row, colname_col)
                    else
                        # skip
                    end
                end
            end
        end

        # Hide labels etc. as needed for a compact view
        if row_ind < N
            Makie.hidexdecorations!(ax, grid=false)
        end
        if col_ind > 1 || row_ind == 1
            Makie.hideydecorations!(ax, grid=false)
        end

    end

    # Link all axes
    for axes in values(axes_by_row)
        Makie.linkyaxes!(axes...)
    end
    for axes in values(axes_by_col)
        Makie.linkxaxes!(axes...)
    end
    # Wishlist: link x axis of bottom right diagonal plot with y axis of bottom row.

    # Ensure labels are spaced nicely
    if N > 1
        yspace = maximum(Makie.tight_yticklabel_spacing!, axes_by_row[N])
        xspace = maximum(Makie.tight_xticklabel_spacing!, axes_by_col[1])
        for ax in axes_by_row[N]
            ax.xticklabelspace = xspace
        end
        for ax in axes_by_col[1]
            ax.yticklabelspace = yspace + 10
        end
    end

    # Add legend if needed (any series has a non-nothing label)
    if any(((ser,_),)->!isnothing(ser.label), pairs)

        legend_strings = map(((ser,_),)->isnothing(ser.label) ? "" : ser.label, pairs)
        legend_entries = map(pairs) do (ser, _)
            Makie.LineElement(;ser.kwargs...)
        end
        Makie.Legend(
            grid[N == 1 ? 1 : end-1, N <= 2 ? 2 : N ],
            collect(legend_entries),
            collect(legend_strings);
            tellwidth=false,
            tellheight=false,
            valign = :bottom,
            halign = :left,
            legend...
        )
    end

    return

end

# Note: stephist coming soon in a Makie PR

function diagplot(ax::Makie.Axis, viz::MarginHist, series::Series, colname)
    dat = getproperty(series.table, colname)

    bins = get(series.kwargs, :bins, 32)
    bins = get(viz.kwargs, :bins, bins)

    # h = fit(Histogram, vec(dat); nbins=bins)
    # x = range(first(h.edges[1])+step(h.edges[1])/2, step=step(h.edges[1]), length=size(h.weights,1))
   
    x, weights = viz.prepare_hist(dat,  bins)


    Makie.stairs!(
        ax, x, weights;
        gap = 0,
        series.kwargs...,
        viz.kwargs...,
    )
    Makie.ylims!(ax,low=0)
end

function diagplot(ax::Makie.Axis, viz::MarginDensity, series::Series, colname)
    dat = getproperty(series.table, colname)

     Makie.density!(
        ax,
        dat;
        series.kwargs...,
        viz.kwargs...,
    )
    Makie.ylims!(ax,low=0)
end


function diagplot(ax::Makie.Axis, viz::MarginConfidenceLimits, series::Series, colname)

    percentiles = quantile(vec(getproperty(series.table, colname)), (0.16, 0.5, 0.84))
    mid = percentiles[2]
    low = mid - percentiles[1]
    high = percentiles[3] - mid

    title = @eval (@sprintf($(viz.titlefmt), $mid, $high, $low))
    ax.title = Makie.latexstring(ax.title[], title)

    Makie.vlines!(
        ax,
        [mid-low, mid, mid+high];
        linestyle=:dash,
        depth_shift=-10f0,
        series.kwargs...,
        viz.kwargs...,
    )
end

function bodyplot(ax::Makie.Axis, viz::HexBin, series::Series, colname_row, colname_col)
    Makie.hexbin!(
        ax,
        getproperty(series.table, colname_col),
        getproperty(series.table, colname_row);
        bins=32,
        colormap=Makie.cgrad([:transparent, :black]),
        series.kwargs...,
        viz.kwargs...,
    )
end

function bodyplot(ax::Makie.Axis, viz::Hist, series::Series, colname_row, colname_col)

    xdat = getproperty(series.table, colname_col)
    ydat = getproperty(series.table, colname_row)

    
    bins = get(series.kwargs, :bins, 32)
    bins = get(viz.kwargs, :bins, bins)

    # h = fit(Histogram, (vec(xdat),vec(ydat)); nbins=bins)
    # x = range(first(h.edges[1])+step(h.edges[1])/2, step=step(h.edges[1]), length=size(h.weights,1))
    # y = range(first(h.edges[2])+step(h.edges[2])/2, step=step(h.edges[2]), length=size(h.weights,2))

    x, y, weights = viz.prepare_hist(xdat, ydat, bins)

    Makie.heatmap!(
        ax,
        x,
        y,
        weights;
        colormap=Makie.cgrad([:transparent, :black]),
        series.kwargs...,
        viz.kwargs...,
    )
end

function prep_contours(series::Series, sigmas, colname_row, colname_col)

    xdat = getproperty(series.table, colname_col)
    ydat = getproperty(series.table, colname_row)
    k  = KernelDensity.kde((xdat, ydat))
    ik = KernelDensity.InterpKDE(k)

    exx = extrema(xdat)
    exy = extrema(ydat)
    N = 100
    x = range(first(exx), last(exx), length=N)
    y = range(first(exy), last(exy), length=N)
    h = pdf.(Ref(ik), x, y')
    
    # Calculate levels for contours
    levels = 1 .- exp.(-0.5 .* (1 ./sigmas).^2)
    ii = sortperm(reshape(h,:))
    h2flat = h[ii]
    sm = cumsum(h2flat)
    sm /= sm[end]
    if all(isnan, sm) || length(h) <= 1
        @warn "Could not compute valid contours"
        V = [0]
    else
        V = sort(map(v0 -> h2flat[sm .≤ v0][end], levels))
        if any(==(0), diff(V))
            @warn "Too few points to create valid contours"
        end
    end

    # Place a row and column of zeros around all sides of the data grid
    # to ensure the contours link up nicely.
    pad_x = [first(x)-step(x); x; last(x)+step(x)]
    pad_y = [first(y)-step(y); y; last(y)+step(y)]
    pad_h = [
        zeros(size(h,2))' 0 0
        zeros(size(h,1)) h zeros(size(h,1))
        zeros(size(h,2))' 0 0
    ]
    c = ContourLib.contours(pad_x,pad_y,pad_h, V)
    return c
end


function bodyplot(ax::Makie.Axis, viz::Contour, series, colname_row, colname_col)

    c = prep_contours(series::Series, viz.sigmas, colname_row, colname_col)
   
    levels = ContourLib.levels(c)
    for (i,level) in enumerate(levels), poly in ContourLib.lines(level)
        xs, ys = ContourLib.coordinates(poly)
        # Makie.poly!(ax, Makie.Point2f.(zip(xs,ys)); strokewidth=2, series.kwargs...,  viz.kwargs..., color=:transparent, strokecolor=color)#(color, i/length(levels)))
        Makie.lines!(ax, xs, ys; strokewidth=1.5, series.kwargs...,  viz.kwargs...)
    end
end

function bodyplot(ax::Makie.Axis, viz::Contourf, series::Series, colname_row, colname_col)

    c = prep_contours(series::Series, viz.sigmas, colname_row, colname_col)

    levels = ContourLib.levels(c)
    for (i,level) in enumerate(levels), poly in ContourLib.lines(level)
        xs, ys = ContourLib.coordinates(poly)
        Makie.poly!(ax, Makie.Point2f.(zip(xs,ys)); series.kwargs..., viz.kwargs...)#(color, 1/length(levels)))
    end
end


function bodyplot(ax::Makie.Axis, viz::Scatter, series::Series, colname_row, colname_col)

    xall = getproperty(series.table, colname_col)
    yall = getproperty(series.table, colname_row)

    if isnothing(viz.filtersigma)
        Makie.scatter!(ax, xall, yall; markersize=1f0, series.kwargs..., viz.kwargs...)
        return
    end

    c = prep_contours(series, [viz.filtersigma], colname_row, colname_col)
    levels = ContourLib.levels(c)
    xfilt, yfilt = scatter_filtering(xall, yall, first(levels))
    Makie.scatter!(ax, xfilt, yfilt; markersize=1f0, series.kwargs..., viz.kwargs...)

end


# Default histogram calculations
"""
    prepare_hist(vector, nbins)

Use the StatsBase function to return a centered histogram from `vector` with `nbins`.
Must return a tuple of bin centres, followed by bin weights (of the same length).
"""
function prepare_hist(a, nbins)
    h = fit(Histogram, vec(a); nbins)
    x = range(first(h.edges[1])+step(h.edges[1])/2, step=step(h.edges[1]), length=size(h.weights,1))
    return x, h.weights
end
"""
    prepare_hist(vector, nbins)

Use the StatsBase function to return a centered histogram from `vector` with `nbins`x`nbins`.
Must return a tuple of bin centres along the horizontal, bin centres along the vertical,
and a matrix of bin weights (of matching dimensions).
"""
function prepare_hist(a, b, nbins)
    h = fit(Histogram, (vec(a),vec(b)); nbins)
    x = range(first(h.edges[1])+step(h.edges[1])/2, step=step(h.edges[1]), length=size(h.weights,1))
    y = range(first(h.edges[2])+step(h.edges[2])/2, step=step(h.edges[2]), length=size(h.weights,2))
    return x, y, h.weights
end



# Filter the scatter plot to remove points inside the first contour
# for performance and better display
function scatter_filtering(x,y, level)

    inds = eachindex(x,y)
    outside = trues(size(inds))

    # calculate the outer contour manually
    for poly in ContourLib.lines(level)
        xs, ys = ContourLib.coordinates(poly)
        poly = SVector.(xs,ys)
        push!(poly, SVector(xs[begin], ys[begin]))
        # Could benchmark threading this
        for i in inds
            point = SVector(x[i],y[i])
            # This logic does not seem to be 100% right
            ins = inpolygon(point, poly, in=false, on=true, out=true)
            outside[i] &= ins
        end
    end
    return view(x, outside), view(y, outside)

end

include("precompile.jl")

end

