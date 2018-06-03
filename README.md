# Persistence
A topological data analysis library for Haskell.

The objective of the library is to provide users with the ability to deduce the topological features of metric spaces and graphs. If you have a function (a metric, for example) that takes two points in your data to an element of an ordered set, you can use Persistence to analyze the topology of your data.

Visit https://hackage.haskell.org/package/Persistence to see the documentation for the stable version. There is also documentation in each module.

GitHub: https://github.com/Ebanflo42/Persistence

Relevant files for development: Util.hs, Matrix.hs, SimplicialComplex.hs, HasseDiagram.hs, Persistence.hs, Testing.hs

Compile Testing.hs with `ghc --make Testing.hs -threaded -rtsopts` and run with 

    ./Testing +RTS -s -N<number of threads>

# Learning about Topological Data Analysis

Simplicial homology:

https://jeremykun.com/2013/04/10/computing-homology/

The Vietoris-Rips complex:

https://pdfs.semanticscholar.org/e503/c24dcc7a8110a001ae653913ccd064c1044b.pdf

Persistent homology:

http://geometry.stanford.edu/papers/zc-cph-05/zc-cph-05.pdf

The algorithm for finding the directed clique complex is inspired by the pseudocode in the supplementary materials of this paper:

https://www.frontiersin.org/articles/10.3389/fncom.2017.00048/full

# Major TODOs:

`Matrix.hs`:

1) Fix Gauss-Jordan elimnation over the integers.

`SimplicialComplex.hs`:

1) Fix simplicial homology over the integers (this is almost certainly being caused by a malfunction of Gauss-Jordan elimnation in `Matrix.hs`

`Persistence.hs`:

Many of these are breaking API changes and so will be included in Persistence-2.0.

1) Rename to `Filtration.hs` (Persistent homology isn't the only thing that it does).

2) Change the type synonym for barcodes to `(a, Extended a)` so that bar codes can encode the scales at which features exist, not just the filtration indices. Bottleneck distance functions that account for these types of bar codes also need to be made.

3) Persistent homology functions which identify the vertices where features occur also need to be implemented.

4) Start implementing persistent homology and filtration construction with parallelism.

`Testing.hs`:

1) Test the bottleneck distance.

General:

1) Revise the way modules are organized in the release.

2) A more consistent, well-motivated, and concise philosophy for parallelism needs to be implemented.

See each of the files for an overview of its inner-workings.
