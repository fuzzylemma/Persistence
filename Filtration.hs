{- |
Module     : Persistence.Filtration
Copyright  : (c) Eben Cowley, 2018
License    : BSD 3 Clause
Maintainer : eben.cowley42@gmail.com
Stability  : experimental

This module contains functions for constructing filtrations, computing persistent homology, computing bottleneck distance between barcode diagrams, as well as a few utility functions for working with filtrations.

A filtration is a finite sequence of simplicial complexes where each complex is a subset of the next. This means that a filtration can be thought of as a single simplicial complex where each of the simplices is labeled with a "filtration index" that represents the index in the sequence where that simplex enters the filtration.

One way to create a filtration, given a simplicial complex, a metric for the vertices, and a list of distances, is to loop through the distances from greatest to least: create a simplicial complex each iteration which excludes simplices that contain pairs of vertices which are further than the current distance apart. This method will produce a filtration of Vietoris-Rips complexes - each filtration index will correspond to a VR complex whose scale is the corresponding distance.

NOTE: It's important that, even though the smallest filtration index represents the smallest scale at which the data is being anaylzed, all functions in this library receive your list of scales sorted in *decreasing* order.

An essential thing to note about the way this library is set up is the distinction between "fast" and "light" functions. Light functions call the metric every time distance between two points is required, which is a lot. Fast functions store the distances between points and access them in constant time, BUT this means they use O(n^2) memory with respect to the number of data points, so it's a really bad idea to use this optimization on substantially large data.

Persistent homology is the main event of topological data analysis. It allows one to identify clusters, tunnels, cavities, and higher dimensional holes that persist in the data throughout many scales. The output of the persistence algorithm is a barcode diagram. A single barcode represents the filtration index where a feature appears and the index where it disappears (if it does). Alternatively, a barcode can represent the scale at which a feature and the scale at which it ends. Thus, short barcodes are typically interpretted as sampling irregularities and long barcodes are interpretted as actual features of whatever the underlying data set represents.

After you've got the barcodes of a data set, you might want to compare it with that of a different data set. That's why this release includes two versions of "bottleneck distance," one works only if the number of features in each data set is the same and the other works regardless. If we were working with two point sets in the plane, the bottleneck distance between them would be the maximum of all minimum distance between pairs (one from each set) of points. That's exactly what bottleneck distance does for lists of barcodes, except you're free to decide the metric that determines how different two barcodes are. If that didn't make sense, look up "Hausdorff distance," which is a more widely-known and general concept.

-}

module Filtration
  ( SimpleFiltration
  , Filtration
  , BarCode
  , Extended (Finite, Infinity)
  , sim2String
  , filtr2String
  , getComplex
  , getDimension
  , simple2Filtr
  , filterByWeightsFast
  , makeVRFiltrationFast
  , filterByWeightsLight
  , makeVRFiltrationLight
  , indexBarCodes
  , indexBarCodesSimple
  , scaleBarCodes
  , scaleBarCodesSimple
  , indexMetric
  , bottleNeckDistance
  , bottleNeckDistances
  ) where

import Util
import Matrix
import SimplicialComplex

import Data.List as L
import Data.Vector as V
import Control.Parallel.Strategies
import Data.Algorithm.MaximalCliques

--DATA TYPES--------------------------------------------------------------

{- |
  A type representing a filtration whose vertices all have filtration index 0. Slightly faster and slightly less memory usage.
  The first component is simply the number of vertices.
  The second component is a vector with an entry for each dimension of simplices, starting at dimension 1 for edges.
  Each simplex is represented as a triple: its filtration index, the indices of its vertices in the original data, and the indices of its faces in the next lowest dimension.
  Edges do not have reference to their faces, as it would be redundant with their vertices. All simplices are sorted according to filtration index upon construction of the filtration.
  In each dimension, all simplices are sorted in increasing order of filtration index, and every simplices face indices are sorted in decreasing order; both of these facts are important for the computation of persistent homology.
-}
type SimpleFiltration = (Int, Vector (Vector (Int, Vector Int, Vector Int)))

{- |
  Representation of a filtration which, unlike `SimpleFiltration`, can cope with vertices that have a non-zero
  filtration index. Vertices of the filtration are represented like all other simplices except that they don't their own have vertices or faces.
-}
type Filtration = Vector (Vector (Int, Vector Int, Vector Int))

-- | Type for representing inifinite bottleneck distance and infinite bar codes.
data Extended a = Finite a | Infinity deriving (Eq, Show)

-- | `(x, Finite y)` is a feature that appears at index/scale x and disappears at index/scale y, `(x, Infinity)` begins at x and doesn't disappear.
type BarCode a = (a, Extended a)

-- | The ordering is inherited from the type a, Infinity is greater than everything else.
instance (Ord a, Eq a) => Ord (Extended a) where
  Infinity > Infinity  = False
  Infinity > Finite _  = True
  Finite a > Finite b  = a > b
  Finite _ > Infinity  = False
  Infinity >= Infinity = True
  Infinity >= Finite _ = True
  Finite _ >= Infinity = False
  Finite a >= Finite b = a >= b
  Infinity < Infinity  = False
  Infinity < Finite a  = False
  Finite _ < Infinity  = True
  Finite a < Finite b  = a < b
  Infinity <= Infinity = True
  Infinity <= Finite _ = False
  Finite _ <= Infinity = True
  Finite a <= Finite b = a <= b

-- | Shows all the information in a simplex.
sim2String :: (Int, Vector Int, Vector Int) -> String
sim2String (index, vertices, faces) =
  "Filtration index: " L.++ (show index) L.++
    "; Vertex indices: " L.++ (show vertices) L.++
      "; Boundary indices: " L.++ (show faces) L.++ "\n"

-- | Shows all the information in a filtration.
filtr2String :: Either SimpleFiltration Filtration -> String
filtr2String (Left f)  =
  "Simple filtration:\n" L.++ ((intercalate "\n") $ toList $ V.map (L.concat . toList . (V.map sim2String)) $ snd f)
filtr2String (Right f) =
  (intercalate "\n") $ toList $ V.map (L.concat . toList . (V.map sim2String)) f

-- | Gets the simplicial complex specified by the filtration index. This is O(n) with respect to the number of simplices.
getComplex :: Int -> Either SimpleFiltration Filtration -> SimplicialComplex
getComplex index (Left (n, simplices))  = (n, V.map (V.map not1 . V.filter (\(i, _, _) -> i == index)) simplices)
getComplex index (Right simplices) =
  (V.length $ V.filter (\v -> one v <= index) (V.head simplices), V.map (V.map not1 . V.filter (\(i, _, _) -> i == index)) (V.tail simplices))

-- | Return the dimension of the highest dimensional simplex in the filtration (constant time).
getDimension :: Either SimpleFiltration Filtration -> Int
getDimension (Left sf) = V.length $ snd sf
getDimension (Right f) = V.length f - 1

-- | Convert a simple filtration into an ordinary filtration.
simple2Filtr :: SimpleFiltration -> Filtration
simple2Filtr (n, x) =
  let x' = (V.map (\(i, v, _) -> (i, v, V.reverse v)) $ V.head x) `cons` (V.tail x)
  in (mapWithIndex (\i (a,b,c) -> (a,i `cons` V.empty,c)) $ V.replicate n (0, V.empty, V.empty)) `cons` x'

--FILTRATION CONSTRUCTION-------------------------------------------------

{- |
  Given a list of scales, a simplicial complex, and a weighted graph (see SimplicialComplex) which encodes a metric on the vertices,
  this function creates a filtration out of a simplicial complex by removing simplices that contain edges that are too long for each scale in the list.
  This is really a helper function to be called by makeVRFiltrationFast, but I decided to expose it in case you have a simplicial complex and weighted graph lying around.
  The scales MUST be in decreasing order.
-}
filterByWeightsFast :: Ord a => [a] -> (SimplicialComplex, Graph a) -> SimpleFiltration
filterByWeightsFast scales ((numVerts, simplices), graph) =
  let edgeInSimplex edge simplex = (existsVec (\x -> V.head edge == x) simplex) && (existsVec (\x -> V.last edge == x) simplex)
      edgeTooLong scale edge     = scale <= (fst $ graph ! (edge ! 0) ! (edge ! 1))
      maxIndex                   = (L.length scales) - 1

      calcIndices 0 [] sc         = sc
      calcIndices i (scl:scls) sc =
        let longEdges = V.filter (edgeTooLong scl) $ V.map (\(i, v, f) -> v) $ V.head sc --find edges excluded by this scale
        in calcIndices (i - 1) scls $ V.map (V.map (\(j, v, f) ->
          if j == 0 then --if the simplex has not yet been assigned a fitration index
            if existsVec (\edge -> edgeInSimplex edge v) longEdges then (i, v, f) --if a long edge is in the simplex, assign it the current index
            else (0, v, f) --otherwise wait until next iteration
          else (j, v, f))) sc --otherwise leave it alone

      sortFiltration simplices =
        let sortedSimplices =
              V.map (quicksort (\((i, _, _), _) ((j, _, _), _) -> i > j)) $
                V.map (mapWithIndex (\i s -> (s, i))) simplices
            newFaces dim (i, v, f) =
              let findNew j =
                    case V.findIndex (\x -> snd x == j) $ sortedSimplices ! (dim - 1) of
                      Just k  -> k
                      Nothing -> error "Persistence.sortFiltration.newFaces.findNew"
              in (i, v, (V.map findNew f))
        in
          if V.null simplices then simplices
          else mapWithIndex (\i ss -> V.map ((newFaces i) . fst) ss) sortedSimplices

      sortBoundaries = V.map (V.map (\(i, v, f) -> (i, v, quicksort (\a b -> a < b) f)))

  in (numVerts, sortBoundaries $ sortFiltration $ --sort the simplices by filtration index, then sort boundaries so that the boundary chains can be acquired easily
      calcIndices maxIndex (L.tail scales) $
        V.map (V.map (\(v, f) -> (0, v, f))) $ simplices)

{- |
  Given a list of scales, a metric, and a data set, this function constructs a filtration of the Vietoris-Rips complexes associated with the scales.
  The scales MUST be in decreasing order. Note that this a fast function, meaning it uses O(n^2) memory to quickly access distances where n is the number of data points.
-}
makeVRFiltrationFast :: (Ord a, Eq b) => [a] -> (b -> b -> a) -> [b] -> SimpleFiltration
makeVRFiltrationFast scales metric dataSet = filterByWeightsFast scales $ makeVRComplexFast (L.head scales) metric dataSet

-- | The same as filterbyWeightsFast except it uses far less memory at the cost of speed. Note that the scales must be in decreasing order.
filterByWeightsLight :: Ord a => [a] -> (b -> b -> a) -> [b] -> SimplicialComplex -> SimpleFiltration
filterByWeightsLight scales metric dataSet (numVerts, simplices) =
  let edgeInSimplex edge simplex = (existsVec (\x -> V.head edge == x) simplex) && (existsVec (\x -> V.last edge == x) simplex)
      vector                     = V.fromList dataSet
      edgeTooLong scale edge     = scale <= (metric (vector ! (edge ! 0)) (vector ! (edge ! 1)))
      maxIndex                   = (L.length scales) - 1

      calcIndices 0 [] sc         = sc
      calcIndices i (scl:scls) sc =
        let longEdges = V.filter (edgeTooLong scl) $ V.map (\(i, v, f) -> v) $ V.head sc --find edges excluded by this scale
        in calcIndices (i - 1) scls $ V.map (V.map (\(j, v, f) ->
          if j == 0 then --if the simplex has not yet been assigned a fitration index
            if existsVec (\edge -> edgeInSimplex edge v) longEdges then (i, v, f) --if a long edge is in the simplex, assign it the current index
            else (0, v, f) --otherwise wait until next iteration
          else (j, v, f))) sc --otherwise leave it alone

      sortFiltration simplices =
        let sortedSimplices =
              V.map (quicksort (\((i, _, _), _) ((j, _, _), _) -> i > j)) $
                V.map (mapWithIndex (\i s -> (s, i))) simplices
            newFaces dim (i, v, f) =
              let findNew j =
                    case V.findIndex (\x -> snd x == j) $ sortedSimplices ! (dim - 1) of
                      Just k  -> k
                      Nothing -> error "Persistence.filterByWeightsLight.sortFiltration.newFaces.findNew"
              in (i, v, (V.map findNew f))
        in
          if V.null simplices then simplices
          else mapWithIndex (\i ss -> V.map ((newFaces i) . fst) ss) sortedSimplices

  in (numVerts, sortFiltration $ --sort the simplices by filtration index
      calcIndices maxIndex (L.tail scales) $
        V.map (V.map (\(v, f) -> (0, v, f))) $ simplices)

-- | Given a list of scales in decreasing order, a metric, and a data set, this constructs the filtration of Vietoris-Rips complexes corresponding to the scales.
makeVRFiltrationLight :: (Ord a, Eq b) => [a] -> (b -> b -> a) -> [b] -> SimpleFiltration
makeVRFiltrationLight scales metric dataSet = filterByWeightsLight scales metric dataSet $ makeVRComplexLight (L.head scales) metric dataSet

--PERSISTENT HOMOLOGY-----------------------------------------------------

type Chain   = Vector Int --indices of the simplices in the sum

{- |
  The nth entry in the list will describe the n-dimensional topology of the filtration.
  That is, the first list will represent clusters, the second list will represent tunnels or punctures,
  the third will represent hollow volumes, and the nth index list will represent n-dimensional holes in the data;
  where features are encoded by the filtration indices where they appear and disappear.
-}
indexBarCodes :: Filtration -> [[BarCode Int]]
indexBarCodes filtration =
  let maxdim = getDimension (Right filtration)

      --given a vector of indices of simplices which are marked and a vector of boundary chains paired with the indices of their simplices
      --remove the unmarked simplices from the chain
      removeUnmarked :: Vector Int -> Vector (Int, Chain) -> Vector (Int, Chain)
      removeUnmarked marked = V.map (\(i, c) -> (i, V.filter (\j -> V.elem j marked) c))

      --eliminate monomials in the boundary chain until it is no longer or there is a monomial which can't be eliminated
      removePivotRows :: Vector (Maybe Chain) -> Chain -> Chain
      removePivotRows slots chain =
        if V.null chain then V.empty
        else
          case slots ! (V.head chain) of
            Nothing -> chain
            Just c  -> removePivotRows slots (chain `uin` c)

      --given the indices of the marked simplices from the last iteration, slots from the last iteration, and boundary chains
      --mark the appropriate simplices, fill in the appropriate slots, and identify bar codes
      --boundary chains are paired with the index of their coresponding simplex
      makeFiniteBarCodes :: Int -> Vector Int -> Vector (Maybe Chain) -> Vector (Int, Chain) -> [BarCode Int] -> (Vector Int, Vector (Maybe Chain), [BarCode Int])
      makeFiniteBarCodes dim newMarked slots boundaries barcodes =
        if V.null boundaries then (newMarked, slots, barcodes)
        else
          let boundary = V.head boundaries
              reduced  = removePivotRows slots $ snd boundary
          in
            --mark the simplex if its boundary chain is reduced to null
            if V.null reduced then makeFiniteBarCodes dim (newMarked `snoc` (fst boundary)) slots (V.tail boundaries) barcodes
            else
              let pivot = V.head reduced
              --put the pivot chain in the pivot's slot, add the new barcode to the list
              in makeFiniteBarCodes dim newMarked (replaceElem pivot (Just reduced) slots) (V.tail boundaries) ((one $ filtration ! (dim - 1) ! pivot, Finite $ one $ filtration ! dim ! (fst boundary)):barcodes)

      --get the finite bar codes for each dimension
      loopFiniteBarCodes :: Int -> Vector (Vector Int) -> Vector (Vector (Maybe Chain)) -> [[BarCode Int]] -> (Vector (Vector Int), Vector (Vector (Maybe Chain)), [[BarCode Int]])
      loopFiniteBarCodes dim marked slots barcodes =
        if dim > maxdim then (marked, V.tail slots, (L.tail barcodes) L.++ [[]]) --the slots vector made when looping over the vertices will be null
        else
          let numSlots = if dim == 0 then 0 else V.length $ filtration ! (dim - 1) --see above
              boundaries = removeUnmarked (V.last marked) $ mapWithIndex (\i (_, _, f) -> (i, f)) $ filtration ! dim
              (newMarked, newSlots, newCodes) = makeFiniteBarCodes dim V.empty (V.replicate numSlots Nothing) boundaries []
          in loopFiniteBarCodes (dim + 1) (marked `snoc` newMarked) (slots `snoc` newSlots) (barcodes L.++ [newCodes])

      --if a simplex isn't marked and has an empty slot, an infinite bar code begins at it's filtration index
      makeInfiniteBarCodes :: Int -> Vector Int -> Vector (Maybe Chain) -> [BarCode Int]
      makeInfiniteBarCodes dim marked slots =
        V.toList $ V.map (\i -> (one $ filtration ! dim ! i, Infinity)) $ V.filter (\i -> slots ! i == Nothing) marked

      --add the infinite bar codes to the list of bar codes in each dimension
      loopInfiniteBarCodes :: Int -> (Vector (Vector Int), Vector (Vector (Maybe Chain)), [[BarCode Int]]) -> [[BarCode Int]]
      loopInfiniteBarCodes dim (marked, slots, barcodes) =
        if dim > maxdim then barcodes
        else
          loopInfiniteBarCodes (dim + 1) (marked, slots, replaceElemList dim ((barcodes !! dim) L.++ (makeInfiniteBarCodes dim (marked ! dim) (slots ! dim))) barcodes)

  in L.map (L.filter (\(a, b) -> b /= Finite a)) $ loopInfiniteBarCodes 0 $ loopFiniteBarCodes 0 V.empty V.empty []

-- | Same as above except this function acts on filtrations whose vertices all have filtration index zero (for a ver slight speedup).
indexBarCodesSimple :: SimpleFiltration -> [[BarCode Int]]
indexBarCodesSimple (numVerts, allSimplices) =
  let removeUnmarked marked = V.filter (\x -> V.elem x marked)

      removePivotRows reduced chain =
        if V.null chain then chain
        else
          case reduced ! (V.head chain) of
            Nothing -> chain
            Just t  -> removePivotRows reduced (chain `uin` t) --eliminate the element corresponding to the pivot in a different chain

      makeBarCodesAndMark :: Int -> Int -> Vector Int -> Vector (Maybe (Vector Int)) -> Vector (Int, Vector Int, Vector Int) -> ([BarCode Int], Vector Int) -> ([BarCode Int], Vector Int, Vector Int)
      makeBarCodesAndMark dim index marked reduced simplices (codes, newMarked)
        | V.null simplices = (codes, newMarked, V.findIndices (\x -> x == Nothing) reduced)
        | V.null d         = makeBarCodesAndMark dim (index + 1) marked reduced (V.tail simplices) (codes, newMarked `snoc` index)
        | otherwise        =
          let maxindex = V.head d
              begin    = one $ allSimplices ! (dim - 1) ! maxindex
          in makeBarCodesAndMark dim (index + 1) marked (replaceElem maxindex (Just d) reduced) (V.tail simplices)
              ((begin, Finite i):codes, newMarked)
        where (i, v, f) = V.head simplices
              d         = removePivotRows reduced $ removeUnmarked marked f

      makeEdgeCodes :: Int -> Vector (Maybe (Vector Int)) -> Vector (Int, Vector Int, Vector Int) -> ([BarCode Int], Vector Int) -> ([BarCode Int], Vector Int, Vector Int)
      makeEdgeCodes index reduced edges (codes, marked)
        | V.null edges = (codes, marked, V.findIndices (\x -> x == Nothing) reduced)
        | V.null d     =
          makeEdgeCodes (index + 1) reduced (V.tail edges) (codes, marked `snoc` index)
        | otherwise    =
          makeEdgeCodes (index + 1) (replaceElem (V.head d) (Just d) reduced) (V.tail edges) ((0, Finite i):codes, marked)
        where (i, v, f) = V.head edges
              d         = removePivotRows reduced f

      makeFiniteBarCodes :: Int -> Int -> [[BarCode Int]] -> Vector (Vector Int) -> Vector (Vector Int) -> ([[BarCode Int]], Vector (Vector Int), Vector (Vector Int))
      makeFiniteBarCodes dim maxdim barcodes marked slots =
        if dim == maxdim then (barcodes, marked, slots)
        else
          let (newCodes, newMarked, unusedSlots) = makeBarCodesAndMark dim 0 (V.last marked) (V.replicate (V.length $ allSimplices ! (dim - 1)) Nothing) (allSimplices ! dim) ([], V.empty)
          in makeFiniteBarCodes (dim + 1) maxdim (barcodes L.++ [newCodes]) (marked `snoc` newMarked) (slots `snoc` unusedSlots)

      makeInfiniteBarCodes :: ([[BarCode Int]], Vector (Vector Int), Vector (Vector Int)) -> [[BarCode Int]]
      makeInfiniteBarCodes (barcodes, marked, unusedSlots) =
        let makeCodes i codes =
              let slots = unusedSlots ! i; marks = marked ! i
              in codes L.++ (V.toList $ V.map (\j -> (one $ allSimplices ! (i - 1) ! j, Infinity)) $ slots |^| marks)
            loop _ []     = []
            loop 0 (x:xs) = (x L.++ (V.toList $ V.map (\j -> (0, Infinity)) $ (unusedSlots ! 0) |^| (marked ! 0))):(loop 1 xs)
            loop i (x:xs) = (makeCodes i x):(loop (i + 1) xs)
        in loop 0 barcodes

      edges    = V.map (\(i, v, f) -> (i, v, (V.reverse v))) $ V.head allSimplices
      numEdges = V.length edges

      (fstCodes, fstMarked, fstSlots) = makeEdgeCodes 0 (V.replicate numVerts Nothing) edges ([], V.empty)

      verts = 0 `range` (numVerts - 1)

  in L.map (L.filter (\(a, b) -> b /= Finite a)) $ makeInfiniteBarCodes $ makeFiniteBarCodes 1 (V.length allSimplices) [fstCodes] (verts `cons` (fstMarked `cons` V.empty)) (fstSlots `cons` V.empty)

{- |
  The nth entry in the list will again describe the n-dimensional topology of the filtration.
  However, features are encoded by the scales where they appear and disappear. For consistency,
  scales must be in decreasing order.
-}
scaleBarCodes :: [a] -> Filtration -> [[BarCode a]]
scaleBarCodes scales filtration =
  let maxdim = getDimension (Right filtration)

      --given a vector of indices of simplices which are marked and a vector of boundary chains paired with the indices of their simplices
      --remove the unmarked simplices from the chain
      removeUnmarked :: Vector Int -> Vector (Int, Chain) -> Vector (Int, Chain)
      removeUnmarked marked = V.map (\(i, c) -> (i, V.filter (\j -> V.elem j marked) c))

      --eliminate monomials in the boundary chain until it is no longer or there is a monomial which can't be eliminated
      removePivotRows :: Vector (Maybe Chain) -> Chain -> Chain
      removePivotRows slots chain =
        if V.null chain then V.empty
        else
          case slots ! (V.head chain) of
            Nothing -> chain
            Just c  -> removePivotRows slots (chain `uin` c)

      --given the indices of the marked simplices from the last iteration, slots from the last iteration, and boundary chains
      --mark the appropriate simplices, fill in the appropriate slots, and identify bar codes
      --boundary chains are paired with the index of their coresponding simplex
      makeFiniteBarCodes :: Int -> Vector Int -> Vector (Maybe Chain) -> Vector (Int, Chain) -> [BarCode Int] -> (Vector Int, Vector (Maybe Chain), [BarCode Int])
      makeFiniteBarCodes dim newMarked slots boundaries barcodes =
        if V.null boundaries then (newMarked, slots, barcodes)
        else
          let boundary = V.head boundaries
              reduced  = removePivotRows slots $ snd boundary
          in
            --mark the simplex if its boundary chain is reduced to null
            if V.null reduced then makeFiniteBarCodes dim (newMarked `snoc` (fst boundary)) slots (V.tail boundaries) barcodes
            else
              let pivot = V.head reduced
              --put the pivot chain in the pivot's slot, add the new barcode to the list
              in makeFiniteBarCodes dim newMarked (replaceElem pivot (Just reduced) slots) (V.tail boundaries) ((one $ filtration ! (dim - 1) ! pivot, Finite $ one $ filtration ! dim ! (fst boundary)):barcodes)

      --get the finite bar codes for each dimension
      loopFiniteBarCodes :: Int -> Vector (Vector Int) -> Vector (Vector (Maybe Chain)) -> [[BarCode Int]] -> (Vector (Vector Int), Vector (Vector (Maybe Chain)), [[BarCode Int]])
      loopFiniteBarCodes dim marked slots barcodes =
        if dim > maxdim then (marked, V.tail slots, (L.tail barcodes) L.++ [[]]) --the slots vector made when looping over the vertices will be null
        else
          let numSlots = if dim == 0 then 0 else V.length $ filtration ! (dim - 1) --see above
              boundaries = removeUnmarked (V.last marked) $ mapWithIndex (\i (_, _, f) -> (i, f)) $ filtration ! dim
              (newMarked, newSlots, newCodes) = makeFiniteBarCodes dim V.empty (V.replicate numSlots Nothing) boundaries []
          in loopFiniteBarCodes (dim + 1) (marked `snoc` newMarked) (slots `snoc` newSlots) (barcodes L.++ [newCodes])

      --if a simplex isn't marked and has an empty slot, an infinite bar code begins at it's filtration index
      makeInfiniteBarCodes :: Int -> Vector Int -> Vector (Maybe Chain) -> [BarCode Int]
      makeInfiniteBarCodes dim marked slots =
        V.toList $ V.map (\i -> (one $ filtration ! dim ! i, Infinity)) $ V.filter (\i -> slots ! i == Nothing) marked

      --add the infinite bar codes to the list of bar codes in each dimension
      loopInfiniteBarCodes :: Int -> (Vector (Vector Int), Vector (Vector (Maybe Chain)), [[BarCode Int]]) -> [[BarCode Int]]
      loopInfiniteBarCodes dim (marked, slots, barcodes) =
        if dim > maxdim then barcodes
        else
          loopInfiniteBarCodes (dim + 1) (marked, slots, replaceElemList dim ((barcodes !! dim) L.++ (makeInfiniteBarCodes dim (marked ! dim) (slots ! dim))) barcodes)

      s = L.reverse scales

      translateBarCode (i, Infinity) = (s !! i, Infinity)
      translateBarCode (i, Finite j) = (s !! i, Finite $ s !! j)

  in L.map (L.map translateBarCode) $ L.map (L.filter (\(a, b) -> b /= Finite a)) $ loopInfiniteBarCodes 0 $ loopFiniteBarCodes 0 V.empty V.empty []

{- |
  Same as above except acts only on filtrations whose vertices all have filtration index 0.
  Note that scales must be in decreasing order.
-}
scaleBarCodesSimple :: [a] -> SimpleFiltration -> [[BarCode a]]
scaleBarCodesSimple scales (numVerts, allSimplices) =
  let removeUnmarked marked = V.filter (\x -> V.elem x marked)

      removePivotRows reduced chain =
        if V.null chain then chain
        else
          case reduced ! (V.head chain) of
            Nothing -> chain
            Just t  -> removePivotRows reduced (chain `uin` t) --eliminate the element corresponding to the pivot in a different chain

      makeBarCodesAndMark :: Int -> Int -> Vector Int -> Vector (Maybe (Vector Int)) -> Vector (Int, Vector Int, Vector Int) -> ([BarCode Int], Vector Int) -> ([BarCode Int], Vector Int, Vector Int)
      makeBarCodesAndMark dim index marked reduced simplices (codes, newMarked)
        | V.null simplices = (codes, newMarked, V.findIndices (\x -> x == Nothing) reduced)
        | V.null d         = makeBarCodesAndMark dim (index + 1) marked reduced (V.tail simplices) (codes, newMarked `snoc` index)
        | otherwise        =
          let maxindex = V.head d
              begin    = one $ allSimplices ! (dim - 1) ! maxindex
          in makeBarCodesAndMark dim (index + 1) marked (replaceElem maxindex (Just d) reduced) (V.tail simplices)
              ((begin, Finite i):codes, newMarked)
        where (i, v, f) = V.head simplices
              d         = removePivotRows reduced $ removeUnmarked marked f

      makeEdgeCodes :: Int -> Vector (Maybe (Vector Int)) -> Vector (Int, Vector Int, Vector Int) -> ([BarCode Int], Vector Int) -> ([BarCode Int], Vector Int, Vector Int)
      makeEdgeCodes index reduced edges (codes, marked)
        | V.null edges = (codes, marked, V.findIndices (\x -> x == Nothing) reduced)
        | V.null d     =
          makeEdgeCodes (index + 1) reduced (V.tail edges) (codes, marked `snoc` index)
        | otherwise    =
          makeEdgeCodes (index + 1) (replaceElem (V.head d) (Just d) reduced) (V.tail edges) ((0, Finite i):codes, marked)
        where (i, v, f) = V.head edges
              d         = removePivotRows reduced f

      makeFiniteBarCodes :: Int -> Int -> [[BarCode Int]] -> Vector (Vector Int) -> Vector (Vector Int) -> ([[BarCode Int]], Vector (Vector Int), Vector (Vector Int))
      makeFiniteBarCodes dim maxdim barcodes marked slots =
        if dim == maxdim then (barcodes, marked, slots)
        else
          let (newCodes, newMarked, unusedSlots) = makeBarCodesAndMark dim 0 (V.last marked) (V.replicate (V.length $ allSimplices ! (dim - 1)) Nothing) (allSimplices ! dim) ([], V.empty)
          in makeFiniteBarCodes (dim + 1) maxdim (barcodes L.++ [newCodes]) (marked `snoc` newMarked) (slots `snoc` unusedSlots)

      makeInfiniteBarCodes :: ([[BarCode Int]], Vector (Vector Int), Vector (Vector Int)) -> [[BarCode Int]]
      makeInfiniteBarCodes (barcodes, marked, unusedSlots) =
        let makeCodes i codes =
              let slots = unusedSlots ! i; marks = marked ! i
              in codes L.++ (V.toList $ V.map (\j -> (one $ allSimplices ! (i - 1) ! j, Infinity)) $ slots |^| marks)
            loop _ []     = []
            loop 0 (x:xs) = (x L.++ (V.toList $ V.map (\j -> (0, Infinity)) $ (unusedSlots ! 0) |^| (marked ! 0))):(loop 1 xs)
            loop i (x:xs) = (makeCodes i x):(loop (i + 1) xs)
        in loop 0 barcodes

      edges    = V.map (\(i, v, f) -> (i, v, (V.reverse v))) $ V.head allSimplices
      numEdges = V.length edges

      (fstCodes, fstMarked, fstSlots) = makeEdgeCodes 0 (V.replicate numVerts Nothing) edges ([], V.empty)

      verts = 0 `range` (numVerts - 1)

      s = L.reverse scales

      translateBarCode (i, Infinity) = (s !! i, Infinity)
      translateBarCode (i, Finite j) = (s !! i, Finite $ s !! j)

  in L.map (L.map translateBarCode) $ L.map (L.filter (\(a, b) -> b /= Finite a)) $ makeInfiniteBarCodes $ makeFiniteBarCodes 1 (V.length allSimplices) [fstCodes] (verts `cons` (fstMarked `cons` V.empty)) (fstSlots `cons` V.empty)


-- | The standard (Euclidean) metric between index barcodes.
indexMetric :: BarCode Int -> BarCode Int -> Extended Double
indexMetric (_, Finite _) (_, Infinity) = Infinity
indexMetric (_, Infinity) (_, Finite _) = Infinity
indexMetric (i, Infinity) (j, Infinity) =
  Finite $ fromIntegral $ abs $ i - j
indexMetric (i, Finite j) (k, Finite l) =
  let x = i - k; y = j - l
  in Finite $ sqrt $ fromIntegral $ x*x + y*y

{- |
  Given a metric, return the maximum of minimum distances bewteen the bar codes.
  Returns noting if either list of barcodes is empty.
-}
bottleNeckDistance :: Ord b => (BarCode a -> BarCode a -> Extended b) -> [BarCode a] -> [BarCode a] -> Maybe (Extended b)
bottleNeckDistance metric diagram1 diagram2
  | L.null diagram1 = Nothing
  | L.null diagram2 = Nothing
  | otherwise       = Just $ L.maximum $ L.map (\p -> L.minimum $ L.map (metric p) diagram2) diagram1

-- |  Get's all the bottleneck distances; a good way to determine the similarity of the topology of two filtrations.
bottleNeckDistances :: Ord b => (BarCode a -> BarCode a -> Extended b) -> [[BarCode a]] -> [[BarCode a]] -> [Maybe (Extended b)]
bottleNeckDistances metric diagrams1 diagrams2 =
  let d = (L.length diagrams1) - (L.length diagrams2)
  in
    if d >= 0 then (L.zipWith (bottleNeckDistance metric) diagrams1 diagrams2) L.++ (L.replicate d Nothing)
    else (L.zipWith (bottleNeckDistance metric) diagrams1 diagrams2) L.++ (L.replicate (-d) Nothing)