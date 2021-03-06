{- |
Module     : Persistence.Filtration
Copyright  : (c) Eben Kadile, 2018
License    : BSD 3 Clause
Maintainer : eben.cowley42@gmail.com
Stability  : experimental

This module contains functions for V.constructing filtrations and computing persistent homology, persistence landscapes, and computing bottleneck distance between barcode diagrams.

A filtration is a finite sequence of simplicial complexes where each complex is a subset of the next. This means that a filtration can be thought of as a single simplicial complex where each of the simplices is labeled with a "filtration index" that represents the index in the sequence where that simplex enters the filtration.

One way to create a filtration, given a simplicial complex, a metric for the vertices, and a list of distances, is to loop through the distances from greatest to least: create a simplicial complex each iteration which excludes simplices that contain pairs of vertices which are further than the current distance apart. This method will produce a filtration of Vietoris-Rips complexes - each filtration index will correspond to a Rips complex whose scale is the corresponding distance. This filtration represents the topology of the data at each of the scales with which it was V.constructed.

NOTE: It's important that, even though the smallest filtration index represents the smallest scale at which the data is being anaylzed, all functions in this library receive your list of scales sorted in *decreasing* order.

An essential thing to note in this library is the distinction between "fast" and "light" functions. Light functions call the metric every time distance between two points is required, which is a lot. Fast functions store the distances between points and access them in V.constant time, BUT this means they use O(n^2) memory with respect to the number of data points, so it's a really bad idea to use this optimization on substantially large data if you don't have a lot of RAM.

Persistent homology is the main event of topological data analysis. It allows one to identify clusters, tunnels, cavities, and higher dimensional holes that persist in the data throughout many scales. The output of the persistence algorithm is a barcode diagram. A single barcode represents the filtration index where a feature appears and the index where it disappears (if it does). Alternatively, a barcode can represent the scale at which a feature and the scale at which it ends. Thus, short barcodes are typically interpretted as sampling irregularities and long barcodes are interpretted as actual features of whatever the underlying data set represents. In this context, what a feature *is* depends on which dimension the barcode diagram is; 0-dimensional features are connected components, 1-dimensional features are loops or tunnels, 2-dimensional features are hollow volumes, and higher dimensional features correspond to heigher-dimensional cavities.

After you've got the barcodes of a data set, you might want to compare it with that of a different data set. This is the purpose of bottleneck distance, which corresponds to the Hausdorff distance between barcode diagrams.

Another way to compare barcode diagrams is by using persistence landscapes. The peristence landscape of a barcode diagram is a finite sequence of piecewise-linear, real-valued functions. This means they can be used to take averages and compute distances between barcode diagrams. See "A Persistence Landscapes Toolbox For Topological Statistics" by Bubenik and Dlotko for more information.

WARNING: The persistence landscape functions have not been fully tested. Use them with caution. If you get any errors or unexpected output, please don't hesitate to email me.

-}

module Persistence.Filtration (
  -- * Types
    FilterSimplex
  , SimpleFiltration
  , Filtration
  , BarCode
  , Landscape
  -- * Utilities
  , sim2String
  , filtr2String
  , getComplex
  , getDimension
  , simple2Filtr
  -- * Construction
  , filterByWeightsFast
  , ripsFiltrationFast
  , ripsFiltrationFastPar
  , filterByWeightsLight
  , ripsFiltrationLight
  , ripsFiltrationLightPar
  -- * Persistent homology
  , indexBarCodes
  , indexBarCodesSimple
  , scaleBarCodes
  , scaleBarCodesSimple
  -- * Comparing barcode diagrams
  , indexMetric
  , bottleNeckDistance
  , bottleNeckDistances
  , calcLandscape
  , evalLandscape
  , evalLandscapeAll
  , linearComboLandscapes
  , avgLandscapes
  , diffLandscapes
  , normLp
  , metricLp
  ) where

import Persistence.Util
import Persistence.Graph
import Persistence.SimplicialComplex

import Data.Maybe
import Data.List       as L
import Data.Vector     as V
import Data.ByteString as B
import Data.IntSet
import Data.Bits

import qualified Data.Vector.Unboxed as UV

import Data.Algorithm.MaximalCliques

import Control.Parallel.Strategies

-- * Types

{- |
  This type synonym exists to make other synonyms more concise.
  Each simplex in a filtration is represented as a triple: its filtration index,
  the indices of its vertices in the original data, and the indices of its faces in the next lowest dimension.
  Edges do not have reference to their faces, as it would be redundant with their vertices.
  All simplices are sorted according to filtration index upon V.construction of the filtration.
  In each dimension, all simplices are sorted in increasing order of filtration index,
  and every simplices face indices are sorted in decreasing order;
  both of these facts are critical to the computation of persistent homology.
-}
type FilterSimplex = (Int, Vector Int, Vector Int)

{- |
  A type representing a filtration whose vertices all have filtration index 0.
  Slightly faster and slightly less memory usage. The first component is simply the number of vertices.
  The second component is a vector with an entry for each dimension of simplices, starting at dimension 1 for edges.
-}
type SimpleFiltration = (Int, Vector (Vector FilterSimplex))

{- |
  Representation of a filtration which, unlike SimpleFiltration, can cope with vertices that have a non-zero filtration index. Vertices of the filtration are represented like all other simplices except that they don't their own have vertices or faces.

  Note that, since this library currently only deals with static pointcloud data, all of the filtration V.construction functions produce vertices whose filtration index is 0. Thus, if you want to use this type you will have to V.construct the instances yourself.
-}
type Filtration = Vector (Vector FilterSimplex)

-- | (x, Finite y) is a topological feature that appears at the index or scale x and disappears at the index or scale y. (x, Infinity) begins at x and doesn't disappear.
type BarCode a = (a, Extended a)

{- |
  A Persistence landscape is a certain type of piecewise linear function based on a barcode diagram.
  It can be represented as a list of critical points paired with critical values.
  Useful for taking averages and differences between barcode diagrams.
-}
type Landscape = Vector (Vector (Extended Double, Extended Double))

-- * Utilities

-- | Shows all the information in a simplex.
sim2String :: FilterSimplex -> String
sim2String (index, vertices, faces) =
  "Filtration index: " L.++ (show index) L.++
    "; Vertex indices: " L.++ (show vertices) L.++
      "; Boundary indices: " L.++ (show faces) L.++ "\n"

-- | Shows all the information in a filtration.
filtr2String :: Either SimpleFiltration Filtration -> String
filtr2String (Left f)  =
  "Simple filtration:\n" L.++ ((L.intercalate "\n") $ V.toList
    $ V.map (L.concat . V.toList . (V.map sim2String)) $ snd f)
filtr2String (Right f) =
  (L.intercalate "\n") $ V.toList $ V.map (L.concat . V.toList . (V.map sim2String)) f

{- |
  Gets the simplicial complex specified by the filtration index.
  This is O(n) with respect to the number of simplices.
-}
getComplex :: Int -> Either SimpleFiltration Filtration -> SimplicialComplex
getComplex index (Left (n, simplices)) =
  (n, dropRightWhile V.null
    $ V.map (V.map not1 . V.filter (\(i, _, _) ->
      i <= index) . V.map (\(a, b, c) -> (a, UV.convert b, UV.convert c))) simplices)
getComplex index (Right simplices)     =
  (V.length $ V.filter (\v ->
    one v <= index) (V.head simplices), dropRightWhile V.null
      $ V.map (V.map not1 . V.filter (\(i, _, _) -> i <= index)
        . V.map (\(a, b, c) -> (a, UV.convert b, UV.convert c))) (V.tail simplices))

-- | Return the dimension of the highest dimensional simplex in the filtration (V.constant time).
getDimension :: Either SimpleFiltration Filtration -> Int
getDimension (Left sf) = V.length $ snd sf
getDimension (Right f) = V.length f - 1

-- | Convert a simple filtration into an ordinary filtration.
simple2Filtr :: SimpleFiltration -> Filtration
simple2Filtr (n, x) =
  let x' = (V.map (\(i, v, _) -> (i, v, V.reverse v)) $ V.head x) `V.cons` (V.tail x)
  in (mapWithIndex (\i (a,b,c) ->
       (a,i `V.cons` V.empty,c)) $ V.replicate n (0, V.empty, V.empty)) `V.cons` x'

-- * Construction

{- |
  This function creates a filtration out of a simplicial complex by removing simplices
  that contain edges that are too long for each scale in the list.
  This is really a helper function to be called by makeRipsFiltrationFast,
  but I decided to expose it in case you have a simplicial complex and weighted graph lying around.
  The scales MUST be in decreasing order.
-}
filterByWeightsFast :: UV.Unbox a
                    => Ord a
                    => Either (Vector a) [a] -- ^Scales in decreasing order
                    -> (SimplicialComplex, Graph a) -- ^Simplicial complex and a graph encoding the distance between every data point as well as whether or not they are within the largest scale of each other.
                    -> SimpleFiltration
filterByWeightsFast scales' ((numVerts, simplices'), graph) =
  let simplices                  =
        V.map (V.map (\(b, c) -> (UV.convert b, UV.convert c))) simplices'
      scales                     = case scales' of Left v -> V.toList v; Right l -> l
      edgeInSimplex edge simplex = (V.any (\x -> V.head edge == x) simplex)
                                     && (V.any (\x -> V.last edge == x) simplex)
      edgeTooLong scale edge     = scale <= (fst $ graph `indexGraph` (edge ! 0, edge ! 1))
      maxIndex                   = (L.length scales) - 1

      calcIndices 0 [] sc         = sc
      calcIndices i (scl:scls) sc =
        --find edges excluded by this scale
        let longEdges = V.filter (edgeTooLong scl) $ V.map (\(i, v, f) -> v) $ V.head sc
        in calcIndices (i - 1) scls $ V.map (V.map (\(j, v, f) ->
          --if the simplex has not yet been assigned a fitration index
          if j == 0 then
            --if a long edge is in the simplex, assign it the current index
            if V.any (\edge -> edgeInSimplex edge v) longEdges then (i, v, f)
            --otherwise wait until next iteration
            else (0, v, f)
          --otherwise leave it alone
          else (j, v, f))) sc

      sortFiltration simplices =
        let sortedSimplices =
              --sorted in reverse order
              V.map (quickSort (\((i, _, _), _) ((j, _, _), _) -> i > j)) $
                V.map (mapWithIndex (\i s -> (s, i))) simplices
            newFaces dim (i, v, f) =
              let findNew j =
                    case V.findIndex (\x -> snd x == j) $ sortedSimplices ! (dim - 1) of
                      Just k  -> k
                      Nothing -> error "Persistence.Filtration.sortFiltration.newFaces.findNew. This is a bug. Please email the Persistence maintainers."
              in (i, v, (V.map findNew f))
        in
          if V.null simplices then simplices
          else mapWithIndex (\i ss -> V.map ((newFaces i) . fst) ss) sortedSimplices

      sortBoundaries = V.map (V.map (\(i, v, f) -> (i, v, quickSort (\a b -> a <= b) f)))

  --sort the simplices by filtration index,
  --then sort boundaries so that the boundary chains can be acquired easily
  in (numVerts, sortBoundaries $ sortFiltration $
      calcIndices maxIndex (L.tail scales) $
        V.map (V.map (\(v, f) -> (0, v, f))) $ simplices)

{- |
  This function V.constructs a filtration of the Vietoris-Rips complexes associated with the scales.
  Note that this a fast function, meaning it uses O(n^2) memory to quickly access distances where n is the number of data points.
-}
ripsFiltrationFast :: UV.Unbox a
                   => Ord a
                   => Eq b
                   => Either (Vector a) [a] -- ^Scales in decreasing order
                   -> (b -> b -> a) -- ^Metric
                   -> Either (Vector b) [b] -- ^Data set
                   -> SimpleFiltration
ripsFiltrationFast scales metric =
  let scale = case scales of Left v -> V.head v; Right l -> L.head l
  in (filterByWeightsFast scales) . (ripsComplexFast scale metric)

{- |
  Same as above except it uses parallelism when computing the Vietoris-Rips complex of the largest scale.
-}
ripsFiltrationFastPar :: UV.Unbox a
                      => Ord a
                      => Eq b
                      => Either (Vector a) [a] -- ^Scales in decreasing order
                      -> (b -> b -> a) -- ^Metric
                      -> Either (Vector b) [b] -- ^Data set
                      -> SimpleFiltration
ripsFiltrationFastPar scales metric =
  let scale = case scales of Left v -> V.head v; Right l -> L.head l
  in (filterByWeightsFast scales) . (ripsComplexFastPar scale metric)

{- |
  The same as filterbyWeightsFast except it uses far less memory at the cost of speed.
  Note that the scales must be in decreasing order.
-}
filterByWeightsLight :: Ord a
                     => Either (Vector a) [a] -- ^Scales in decreasing order
                     -> (b -> b -> a) -- ^Metric
                     -> Either (Vector b) [b] -- ^Data set
                     -> SimplicialComplex -- ^Vietoris-Rips complex of the data at the largest scale.
                     -> SimpleFiltration
filterByWeightsLight scales' metric dataSet (numVerts, simplices') =
  let simplices                  =
        V.map (V.map (\(b, c) -> (UV.convert b, UV.convert c))) simplices'
      scales                     = case scales' of Left v -> V.toList v; Right l -> l
      edgeInSimplex edge simplex = (V.any (\x -> V.head edge == x) simplex)
                                     && (V.any (\x -> V.last edge == x) simplex)
      vector                     = case dataSet of Left v -> v; Right l -> V.fromList l
      edgeTooLong scale edge     = scale <= (metric (vector ! (edge ! 0)) (vector ! (edge ! 1)))
      maxIndex                   = (L.length scales) - 1

      calcIndices 0 [] sc         = sc
      calcIndices i (scl:scls) sc =
        --find edges excluded by this scale
        let longEdges = V.filter (edgeTooLong scl) $ V.map (\(i, v, f) -> v) $ V.head sc
        in calcIndices (i - 1) scls $ V.map (V.map (\(j, v, f) ->
          --if the simplex has not yet been assigned a fitration index
          if j == 0 then
            --if a long edge is in the simplex, assign it the current index
            if V.any (\edge -> edgeInSimplex edge v) longEdges then (i, v, f)
            --otherwise wait until next iteration
            else (0, v, f)
          --otherwise leave it alone
          else (j, v, f))) sc

      --sortFiltration :: Vector (Int, Vector Int, Vector Int) -> SimpleFiltration
      sortFiltration simplxs =
        let
            --sortedSimplices :: Vector (Vector (((Int, Vector Int, Vector Int), Int)))
            sortedSimplices =
              --sorted in increasing order
              V.map (quickSort (\((i, _, _), _) ((j, _, _), _) -> i > j)) $
                V.map (mapWithIndex (\i s -> (s, i))) simplxs
            newFaces dim (i, v, f) =
              let findNew j =
                    case V.findIndex (\x -> snd x == j) $ sortedSimplices ! (dim - 1) of
                      Just k  -> k
                      Nothing -> error "Persistence.Filtration.filterByWeightsLight.sortFiltration.newFaces.findNew. This is a bug. Please email the Persistence maintainers."
              in (i, v, (V.map findNew f))
        in
          if V.null simplxs then simplxs
          else mapWithIndex (\i ss -> V.map ((newFaces i) . fst) ss) sortedSimplices

  in (numVerts, sortFiltration $ --sort the simplices by filtration index
      calcIndices maxIndex (L.tail scales) $
        V.map (V.map (\(v, f) -> (0, v, f))) $ simplices)

{- |
  Constructs the filtration of Vietoris-Rips complexes corresponding to each of the scales.
-}
ripsFiltrationLight :: (Ord a, Eq b)
                    => Either (Vector a) [a] -- ^List of scales in decreasing order
                    -> (b -> b -> a) -- ^Metric
                    -> Either (Vector b) [b] -- ^Data set
                    -> SimpleFiltration
ripsFiltrationLight scales metric dataSet =
  let scale = case scales of Left v -> V.head v; Right l -> L.head l
  in filterByWeightsLight scales metric dataSet $ ripsComplexLight scale metric dataSet

{- |
  Same as above except it uses parallelism when computing the Vietoris-Rips complex of the largest scale.
-}
ripsFiltrationLightPar :: UV.Unbox a
                       => Ord a
                       => Eq b
                       => Either (Vector a) [a] -- ^List of scales in decreasing order
                       -> (b -> b -> a) -- ^Metric
                       -> Either (Vector b) [b] -- ^Data set
                       -> SimpleFiltration
ripsFiltrationLightPar scales metric dataSet =
  let scale = case scales of Left v -> V.head v; Right l -> L.head l
  in filterByWeightsLight scales metric dataSet $ ripsComplexLightPar scale metric dataSet

-- * Persistent Homology

--indices of the simplices in the sum are 1
type Chain = ByteString

--addition of chains
(+++) :: Chain -> Chain -> Chain
a +++ b = L.foldl (\acc w -> B.snoc acc w) B.empty $ B.zipWith xor a b

--intersection
(-^-) :: Chain -> Chain -> Chain
a -^- b = L.foldl (\acc w -> B.snoc acc w) B.empty $ B.zipWith (.&.) a b

--return the list of simplex indices.
chain2indxs :: Chain -> Vector Int
chain2indxs bits = V.filter (testBBit bits) $ 0 `range` (8*(B.length bits))

--first simplex in the chain
headChain :: Chain -> Int
headChain = V.head . chain2indxs

--given the number of simplices of a certain dimension rounded up to the nearest multiple of 8
--create the zero chain for that number of simplices
makeEmpty :: Int -> Chain
makeEmpty num = B.replicate (num `shiftR` 3) $ fromIntegral 0

--convert indices of simplices to a chain
--given total number of simplices of that dimension founded up to the nearest multiple of 8
indxs2chain :: Int -> Vector Int -> Chain
indxs2chain num = V.foldl (\acc i -> setBBit acc i) (makeEmpty num)


--BROKEN!!!
{--}
{- |
  The nth entry in the list will describe the n-dimensional topology of the filtration.
  That is, the first list will represent clusters, the second list will represent tunnels or punctures, the third will represent hollow volumes,
  and the nth index list will represent n-dimensional holes in the data.
  Features are encoded by the filtration indices where they appear and disappear.
-}
indexBarCodes :: Filtration -> Vector (Vector (BarCode Int))
indexBarCodes filtration =
  let maxdim = getDimension (Right filtration)

      --given a chain of simplices which are marked
      --and a vector of boundary chains paired with the indices of their parent simplices
      --remove the unmarked simplices from the chain
      removeUnmarked :: Chain -> Vector (Int, Chain) -> Vector (Int, Chain)
      removeUnmarked marked = V.map (\(i, c) -> (i, marked -^- c))

      --eliminate monomials in the boundary chain until it is no longer
      --or there is a monomial which can't be eliminated
      removePivotRows :: Vector (Maybe Chain) -> Chain -> Chain
      removePivotRows slots chain =
        if B.null chain then B.empty
        else
          case slots ! (headChain chain) of
            Nothing -> chain
            Just c  -> removePivotRows slots (chain +++ c)

      --given the indices of the marked simplices from the last iteration,
      --slots from the last iteration,and boundary chains
      --mark the appropriate simplices, fill in the appropriate slots, and identify bar codes
      --boundary chains are paired with the index of their coresponding simplex
      makeFiniteBarCodes :: Int
                         -> Chain
                         -> Vector (Maybe Chain)
                         -> Vector (Int, Chain)
                         -> Vector (BarCode Int)
                         -> (Chain, Vector (Maybe Chain), Vector (BarCode Int))
      makeFiniteBarCodes dim newMarked slots boundaries barcodes =
        if V.null boundaries then (newMarked, slots, barcodes)
        else
          let boundary = V.head boundaries
              reduced  = removePivotRows slots $ snd boundary
          in
            --mark the simplex if its boundary chain is reduced to null
            if B.null reduced then
              makeFiniteBarCodes dim
                (setBBit newMarked (fst boundary)) slots (V.tail boundaries) barcodes
            else
              let pivot = headChain reduced
              --put the pivot chain in the pivot's slot, add the new barcode to the list
              in makeFiniteBarCodes dim newMarked
                   (replaceElem pivot (Just reduced) slots)
                     (V.tail boundaries) ((one $ filtration ! (dim - 1) ! pivot,
                       Finite $ one $ filtration ! dim ! (fst boundary)) `V.cons` barcodes)

      --get the finite bar codes for each dimension
      loopFiniteBarCodes :: Int
                         -> Vector Chain
                         -> Vector (Vector (Maybe Chain))
                         -> Vector (Vector (BarCode Int))
                         -> ( Vector Chain
                            , Vector (Vector (Maybe Chain))
                            , Vector (Vector (BarCode Int))
                            )
      loopFiniteBarCodes dim marked slots barcodes =
        --the slots vector made when looping over the vertices will be null
        if dim > maxdim
        then (marked, V.tail slots, (V.tail barcodes) V.++ (V.empty `V.cons` V.empty))
        else
          let numSlots   = if dim == 0 then 0 else V.length $ filtration ! (dim - 1) --see above
              numSlots8  = numSlots + 8 - (numSlots .&. 7)
              boundaries =
                removeUnmarked (V.last marked)
                  $ mapWithIndex (\i (_, _, f) -> (i, indxs2chain numSlots8 f)) $ filtration ! dim
              (newMarked, newSlots, newCodes) =
                makeFiniteBarCodes dim (makeEmpty numSlots8)
                  (V.replicate numSlots Nothing) boundaries V.empty
          in loopFiniteBarCodes (dim + 1) (marked `V.snoc` newMarked)
               (slots `V.snoc` newSlots) (barcodes V.++ (newCodes `V.cons` V.empty))

      --if a simplex isn't marked and has an empty slot,
      --an infinite bar code begins at it's filtration index
      makeInfiniteBarCodes :: Int -> Chain -> Vector (Maybe Chain) -> Vector (BarCode Int)
      makeInfiniteBarCodes dim marked slots =
        V.map (\i -> (one $ filtration ! dim ! i, Infinity))
          $ V.filter (\i -> slots ! i == Nothing) $ chain2indxs marked

      --add the infinite bar codes to the list of bar codes in each dimension
      loopInfiniteBarCodes :: Int
                           -> ( Vector Chain, Vector (Vector (Maybe Chain))
                              , Vector (Vector (BarCode Int)))
                           -> Vector (Vector (BarCode Int))
      loopInfiniteBarCodes dim (marked, slots, barcodes) =
        if dim > maxdim then barcodes
        else
          loopInfiniteBarCodes (dim + 1) (marked, slots, replaceElem dim ((barcodes ! dim)
            V.++ (makeInfiniteBarCodes dim (marked ! dim) (slots ! dim))) barcodes)

      finiteBCs = loopFiniteBarCodes 0 V.empty V.empty V.empty

  in V.map (V.filter (\(a, b) -> b /= Finite a)) $ loopInfiniteBarCodes 0 finiteBCs

-- | Same as above except this function acts on filtrations whose vertices all have filtration index zero (for a very slight speedup).
indexBarCodesSimple :: SimpleFiltration -> Vector (Vector (BarCode Int))
indexBarCodesSimple (numVerts, allSimplices) =
  let maxdim        = getDimension (Right allSimplices)
      verts8        = numVerts + 8 - (numVerts .&. 7)
      edges         = V.map (\(i, v, f) -> (i, v, (V.reverse v))) $ V.head allSimplices
      numEdges      = V.length edges
      numEdges8     = numEdges + 8 - (numEdges .&. 7)
      numSimplices  = V.map V.length $ V.tail allSimplices
      numSimplices8 = V.map (\x -> x + 8 - (numEdges .&. 7)) numSimplices

      --remove marked simplices from the given chain
      removeUnmarked :: Chain -> Chain -> Chain
      removeUnmarked marked chain = marked -^- chain

      --eliminate monomials in the boundary chain until it is no longer
      --or there is a monomial which can't be eliminated
      removePivotRows :: Vector (Maybe Chain) -> Chain -> Chain
      removePivotRows slots chain =
        if B.null chain then B.empty
        else
          case slots ! (headChain chain) of
            Nothing -> chain
            Just c  -> removePivotRows slots (chain +++ c)

      makeEdgeCodes :: Int
                    -> Vector (Maybe Chain)
                    -> Vector (Int, Vector Int, Vector Int)
                    -> (Vector (BarCode Int), Chain)
                    -> (Vector (BarCode Int), Chain, Vector Int)
      makeEdgeCodes index reduced edges (codes, marked)
        | V.null edges = (codes, marked, V.findIndices (\x -> x == Nothing) reduced)
        | B.null d     =
          makeEdgeCodes (index + 1) reduced (V.tail edges) (codes, setBBit marked index)
        | otherwise    =
          makeEdgeCodes (index + 1) (replaceElem (headChain d)
            (Just d) reduced) (V.tail edges) ((0, Finite i) `V.cons` codes, marked)
        where (i, v, f) = V.head edges
              d         = removePivotRows reduced $ indxs2chain numEdges v --should be f?

      makeBarCodesAndMark :: Int
                          -> Int
                          -> Chain
                          -> Vector (Maybe Chain)
                          -> Vector (Int, Vector Int, Vector Int)
                          -> (Vector (BarCode Int), Chain)
                          -> (Vector (BarCode Int), Chain, Vector Int)
      makeBarCodesAndMark dim index marked reduced simplices (codes, newMarked)
        | V.null simplices = (codes, newMarked, V.findIndices (\x -> x == Nothing) reduced)
        | B.null d         =
          makeBarCodesAndMark dim (index + 1) marked reduced
            (V.tail simplices) (codes, setBBit newMarked index)
        | otherwise        =
          let maxindex = headChain d
              begin    = one $ allSimplices ! (dim - 1) ! maxindex
          in makeBarCodesAndMark dim (index + 1) marked
            (replaceElem maxindex (Just d) reduced) (V.tail simplices)
              ((begin, Finite i) `V.cons` codes, newMarked)
        where (i, v, f) = V.head simplices
              d         = removePivotRows reduced
                            $ removeUnmarked marked $ indxs2chain (numSimplices8 ! (dim - 2)) f

      makeFiniteBarCodes :: Int
                         -> Int
                         -> Vector (Vector (BarCode Int))
                         -> Vector Chain
                         -> Vector (Vector Int)
                         -> ( Vector (Vector (BarCode Int))
                            , Vector Chain
                            , Vector (Vector Int)
                            )
      makeFiniteBarCodes dim maxdim barcodes marked slots =
        if dim == maxdim then (barcodes, marked, slots)
        else
          let (newCodes, newMarked, unusedSlots) =
                makeBarCodesAndMark dim 0 (V.last marked)
                  (V.replicate (V.length $ allSimplices ! (dim - 1)) Nothing)
                    (allSimplices ! dim) (V.empty, makeEmpty $ numSimplices8 ! (dim - 2))
          in makeFiniteBarCodes (dim + 1) maxdim
            (barcodes V.++ (newCodes `V.cons` V.empty))
              (marked `V.snoc` newMarked) (slots `V.snoc` unusedSlots)

      makeInfiniteBarCodes :: ( Vector (Vector (BarCode Int))
                              , Vector Chain
                              , Vector (Vector Int)
                              )
                           -> Vector (Vector (BarCode Int))
      makeInfiniteBarCodes (barcodes, marked', unusedSlots) =
        let marked = V.map chain2indxs marked'
            makeCodes :: Int -> Vector (BarCode Int) -> Vector (BarCode Int)
            makeCodes i codes =
              let slots = unusedSlots ! i; marks = marked ! i
              in codes V.++ (V.map (\j -> (one
                   $ allSimplices ! (i - 1) ! j, Infinity)) $ slots |^| marks)
            loop :: Int -> Vector (Vector (BarCode Int)) -> Vector (Vector (BarCode Int))
            loop i v
              | V.null v  = V.empty
              | i == 0    =
                ((V.head v) V.++ (V.map (\j -> (0, Infinity))
                  $ (unusedSlots ! 0) |^| (marked ! 0))) `V.cons` (loop 1 $ V.tail v)
              | otherwise = (makeCodes i $ V.head v) `V.cons` (loop (i + 1) $ V.tail v)
        in loop 0 barcodes

      (fstCodes, fstMarked, fstSlots) = makeEdgeCodes 0
                                          (V.replicate numVerts Nothing)
                                            edges (V.empty, makeEmpty numEdges)

      verts = 0 `range` (numVerts - 1)

  in
    V.map (V.filter (\(a, b) ->
      b /= Finite a)) $ makeInfiniteBarCodes
        $ makeFiniteBarCodes 1 (V.length allSimplices)
          (fstCodes `V.cons` V.empty) ((indxs2chain verts8 verts)
            `V.cons` (fstMarked `V.cons` V.empty)) (fstSlots `V.cons` V.empty)
--}

{--
translate :: F.Extended a -> Extended a
translate F.Infinity   = Infinity
translate (F.Finite x) = Finite x
translate F.MinusInfty = MinusInfty

indexBarCodes =
  (V.map (V.map (\(i, j) -> (i, translate j)))) . F.indexBarCodes

indexBarCodesSimple =
  (V.map (V.map (\(i, j) -> (i, translate j)))) . F.indexBarCodesSimple
--}

{- |
  The nth entry in the list will describe the n-dimensional topology of the filtration.
  However, features are encoded by the scales where they appear and disappear. For V.consistency,
  scales must be in decreasing order.
-}
scaleBarCodes :: Either (Vector a) [a] -> Filtration -> Vector (Vector (BarCode a))
scaleBarCodes scales filtration =
  let s = V.reverse $ (\a -> case a of Left v -> v; Right l -> V.fromList l) scales

      translateBarCode (i, Infinity) = (s ! i, Infinity)
      translateBarCode (i, Finite j) = (s ! i, Finite $ s ! j)

  in V.map (V.map translateBarCode) $ indexBarCodes filtration

{- |
  Same as above except acts only on filtrations whose vertices all have filtration index 0.
  Note that scales must be in decreasing order.
-}
scaleBarCodesSimple :: Either (Vector a) [a] -> SimpleFiltration -> Vector (Vector (BarCode a))
scaleBarCodesSimple scales filtration =
  let s = V.reverse $ (\a -> case a of Left v -> v; Right l -> V.fromList l) scales

      translateBarCode (i, Infinity) = (s ! i, Infinity)
      translateBarCode (i, Finite j) = (s ! i, Finite $ s ! j)

  in V.map (V.map translateBarCode) $ indexBarCodesSimple filtration

-- * Comparing barcode diagrams

{- |
  The standard (Euclidean) metric between index barcodes.
  The distance between infinite and finite barcodes is infinite,
  and the distance between two infinite barcodes is the absolute value of the
  difference of their fst component.
-}
indexMetric :: BarCode Int -> BarCode Int -> Extended Double
indexMetric (_, Finite _) (_, Infinity) = Infinity
indexMetric (_, Infinity) (_, Finite _) = Infinity
indexMetric (i, Infinity) (j, Infinity) =
  Finite $ fromIntegral $ abs $ i - j
indexMetric (i, Finite j) (k, Finite l) =
  let x = i - k; y = j - l
  in Finite $ sqrt $ fromIntegral $ x*x + y*y

{- |
  Given a metric, return the Hausdorff distance
  (referred to as bottleneck distance in TDA) between the two sets.
  Returns nothing if either list of barcodes is empty.
-}
bottleNeckDistance :: Ord b
                   => (BarCode a -> BarCode a -> Extended b)
                   -> Vector (BarCode a)
                   -> Vector (BarCode a)
                   -> Maybe (Extended b)
bottleNeckDistance metric diagram1 diagram2
  | V.null diagram1 = Nothing
  | V.null diagram2 = Nothing
  | otherwise       =
    let first  = V.maximum $ V.map (\p -> V.minimum $ V.map (metric p) diagram2) diagram1
        second = V.maximum $ V.map (\p -> V.minimum $ V.map (metric p) diagram1) diagram2
    in Just $ max first second

{- |
  Get's all the bottleneck distances;
  a good way to determine the similarity of the topology of two filtrations.
-}
bottleNeckDistances :: Ord b => (BarCode a -> BarCode a -> Extended b)
                    -> Vector (Vector (BarCode a))
                    -> Vector (Vector (BarCode a))
                    -> Vector (Maybe (Extended b))
bottleNeckDistances metric diagrams1 diagrams2 =
  let d = (V.length diagrams1) - (V.length diagrams2)
  in
    if d >= 0
    then (V.zipWith (bottleNeckDistance metric) diagrams1 diagrams2) V.++ (V.replicate d Nothing)
    else (V.zipWith (bottleNeckDistance metric) diagrams1 diagrams2) V.++ (V.replicate (-d) Nothing)

-- | Compute the persistence landscape of the barcodes for a single dimension.
calcLandscape :: Vector (BarCode Int) -> Landscape
calcLandscape brcds =
  let half = Finite 0.5

      (i,j) `leq` (k,l) = i > k || j <= l

      innerLoop :: (Extended Double, Extended Double)
                -> Vector (Extended Double, Extended Double)
                -> Landscape
                -> Landscape
      innerLoop (b, d) barcodes result =
        case V.findIndex (\(b', d') -> d' > d) barcodes of
          Nothing ->
            outerLoop barcodes (((V.fromList [(0, b), (Infinity, 0)])
              V.++ (V.head result)) `V.cons` (V.tail result))
          Just i  -> let (b', d') = barcodes ! i in
            if b' >= d then
              if b == d then
                let new = [(Finite 0.0, b')]
                in
                  if d' == Infinity then
                    outerLoop (rmIndex i barcodes) (((V.fromList ((Infinity, Infinity):new))
                      V.++ (V.head result)) `V.cons` (V.tail result))
                  else
                    innerLoop (b', d') (rmIndex i barcodes)
                      ((V.fromList ((half*(b' + d'), half*(d' - b')):new)
                        V.++ (V.head result)) `V.cons` (V.tail result))
              else
                let new = [(Finite 0.0, d), (Finite 0.0, b')]
                in
                  if d' == Infinity then
                    outerLoop (rmIndex i barcodes) (((V.fromList ((Infinity, Infinity):new))
                      V.++ (V.head result)) `V.cons` (V.tail result))
                  else
                    innerLoop (b', d') (rmIndex i barcodes)
                      (((V.fromList ((half*(b' + d'), half*(d' - b')):new))
                        V.++ (V.head result)) `V.cons` (V.tail result))
            else
              let newbr = (half*(b' + d), half*(d - b'))
              in
                if d' == Infinity then
                  outerLoop (orderedInsert leq newbr barcodes)
                    (((V.fromList [(Infinity, Infinity), newbr])
                      V.++ (V.head result)) `V.cons` (V.tail result))
                else
                  innerLoop (b', d') (orderedInsert leq newbr barcodes)
                    (((V.fromList [(half*(b' + d'), half*(d' - b')), newbr])
                      V.++ (V.head result)) `V.cons` (V.tail result))

      outerLoop :: Vector (Extended Double, Extended Double) -> Landscape -> Landscape
      outerLoop barcodes result =
        if not $ V.null barcodes then
          let (b, d) = V.head barcodes
          in
            if (b, d) == (MinusInfty, Infinity)
            then
              outerLoop (V.tail barcodes)
                ((V.fromList [(MinusInfty, Infinity),
                  (Infinity, Infinity)]) `V.cons` result)
            else if d == Infinity
            then
              outerLoop (V.tail barcodes) ((V.fromList
                [(MinusInfty, Finite 0.0),(b, Finite 0.0),(Infinity,Infinity)]) `V.cons` result)
            else
              let newCritPoints =
                    if b == Infinity
                    then [(MinusInfty, Infinity)]
                    else [(MinusInfty, Finite 0.0), (half*(b + d), half*(d - b))]
              in innerLoop (b, d) (V.tail barcodes) ((V.fromList newCritPoints) `V.cons` result)
        else result

  in V.map (quickSort (\(x1, _) (x2, _) -> x1 > x2))
       $ outerLoop (quickSort leq $ V.map (\(i, j) ->
         (fromInt $ Finite i, fromInt j)) brcds) V.empty

-- | Evaluate the nth function in the landscape for the given point.
evalLandscape :: Landscape -> Int -> Extended Double -> Extended Double
evalLandscape landscape i arg =
  let fcn = landscape ! i

      findPointNeighbors :: Ord a => Int -> a -> Vector a -> (Int, Int)
      findPointNeighbors helper x vector =
        let len = V.length vector
            i   = len `div` 2
            y   = vector ! i
        in
          if x == y
          then (helper + i, helper + i)
          else if x > y
          then
            case vector !? (i + 1) of
              Nothing -> (helper + i, helper + i)
              Just z  ->
                if x < z
                then (helper + i, helper + i + 1)
                else findPointNeighbors (helper + i) x $ V.drop i vector
          else
            case vector !? (i - 1) of
              Nothing -> (helper + i, helper + i)
              Just z  ->
                if x > z
                then (helper + i - 1, helper + i)
                else findPointNeighbors helper x $ V.take i vector

      (i1, i2) = findPointNeighbors 0 arg $ V.map fst fcn
      (x1, x2) = (fst $ fcn ! i1, fst $ fcn ! i2)
      (y1, y2) = (snd $ fromMaybe (error "Persistence.Filtration.evalLandscape. This is a bug. Please email the Persistence mainstainers.") $ V.find (\a -> x1 == fst a) fcn, snd $ fromMaybe (error "Persistence.Filtration.evalLandscape. This is a bug. Please email the Persistence mainstainers.") $ V.find (\a -> x2 == fst a) fcn)

  in
    if x1 == x2
    then y1
    else
      case (x1, x2) of
        (MinusInfty, Infinity)   -> arg
        (MinusInfty, Finite _)   -> y1
        (Finite a, Finite b)     ->
          case arg of
            Finite c   ->
              let t = Finite $ (c - a)/(b - a)
              in t*y2 + ((Finite 1.0) - t)*y1
            _          -> error "Persistence.Filtration.evalLandscape.findPointNeighbors. This is a bug. Please email the Persistence maintainers."
        (Finite a, Infinity)     ->
          case arg of
            Infinity   -> y2
            Finite c   ->
              case y2 of
                Infinity   -> Finite $ c - a
                Finite 0.0 -> Finite 0.0
                _          -> error $ "Persistence.Filtration.evalLandscape: y2 = " L.++ (show y2) L.++ ". This is a bug. Please email the Persistence maintainers."
            _          -> error "Persistence.Filtration.evalLandscape.findPointNeighbors: bad argument. This is a bug. Please email the Persistence maintainers."
        anything                 -> error $ "Persistence.Filtration.evalLandscape.findPointNeighbors: " L.++ (show anything) L.++ ". This is a bug. Please email the Persistence maintainers."

-- | Evaluate all the real-valued functions in the landscape.
evalLandscapeAll :: Landscape -> Extended Double -> Vector (Extended Double)
evalLandscapeAll landscape arg =
  if V.null landscape then V.empty
  else (evalLandscape landscape 0 arg) `V.cons` (evalLandscapeAll (V.tail landscape) arg)

{- |
  Compute a linear combination of the landscapes.
  If the coefficient list is too short, the rest of the coefficients are assumed to be zero.
  If it is too long, the extra coefficients are discarded.
-}
linearComboLandscapes :: [Double] -> [Landscape] -> Landscape
linearComboLandscapes coeffs landscapes =
  let maxlen      = L.maximum $ L.map V.length landscapes
      emptylayer  = V.fromList [(MinusInfty, Finite 0.0), (Infinity, Finite 0.0)]
      landscapes' = L.map (\l -> l V.++ (V.replicate (maxlen - V.length l) emptylayer)) landscapes

      myconcat v1 v2
        | V.null v1 = v2
        | V.null v2 = v1
        | otherwise = ((V.head v1) V.++ (V.head v2)) `V.cons` (myconcat (V.tail v1) (V.tail v2))

      xs        = L.map (V.map (V.map fst)) landscapes'
      concatted = L.foldl myconcat V.empty xs
      unionXs   = V.map ((quickSort (>)) . V.fromList . L.nub . V.toList) concatted
      yVals     = L.map (\landscape ->
                    mapWithIndex (\i v -> V.map (evalLandscape landscape i) v) unionXs) landscapes'
      yVals'    = L.zipWith (\coeff yvals ->
                    V.map (V.map ((Finite coeff)*)) yvals) coeffs yVals
      finalY    = L.foldl1 (\acc new -> V.zipWith (V.zipWith (+)) acc new) yVals'
  in V.zipWith V.zip unionXs finalY

-- | Average the persistence landscapes.
avgLandscapes :: [Landscape] -> Landscape
avgLandscapes landscapes =
  let numscapes = L.length landscapes
      coeffs    = L.replicate numscapes (1.0/(fromIntegral numscapes))
  in linearComboLandscapes coeffs landscapes

-- | Subtract the second landscape from the first.
diffLandscapes :: Landscape -> Landscape -> Landscape
diffLandscapes scape1 scape2 = linearComboLandscapes [1, -1] [scape1, scape2]

{- |
  If p>=1 then it will compute the L^p norm on the given interval.
  Uses trapezoidal approximation.
  You should ensure that the stepsize partitions the interval evenly.
-}
normLp :: Extended Double -- ^p, the power of the norm
       -> (Double, Double) -- ^Interval to compute the integral over
       -> Double -- ^Step size
       -> Landscape -- ^Persistence landscape whose norm is to be computed
       -> Maybe Double
normLp p interval step landscape =
  let len = V.length landscape
      a   = fst interval
      b   = snd interval

      fcn x =
        let vals = V.map (\n ->
                     abs $ unExtend $ evalLandscape landscape n (Finite x)) $ 0 `range` (len - 1)
        in
          case p of
            Infinity    -> V.maximum vals
            Finite 1.0  -> V.sum vals
            Finite 2.0  -> sqrt $ V.sum $ V.map (\a -> a*a) vals
            Finite p'   -> (**(1.0/p')) $ V.sum $ V.map (**p') vals

      computeSum :: Double -> Double -> Double
      computeSum currentX result =
        let nextX = currentX + step
        in
          if nextX > b then result + (fcn nextX)
          else computeSum nextX (result + 2.0*(fcn nextX))

  in
    if p < (Finite 1.0) then Nothing
    else Just $ 0.5*step*(computeSum a $ fcn a)

{- |
  Given the same information as above, computes the L^p distance between the two landscapes.
  One way to compare the topologies of two filtrations.
-}
metricLp :: Extended Double -- ^p, power of the metric
         -> (Double, Double) -- ^Interval on which the integral will be computed
         -> Double -- ^Step size
         -> Landscape -- ^First landscape
         -> Landscape -- ^Second landscape
         -> Maybe Double
metricLp p interval step scape1 scape2 = normLp p interval step $ diffLandscapes scape1 scape2