module Persistence where

import Data.List as L
import Data.Vector as V
import Control.Parallel.Strategies

import Util
import Matrix
import MaximalCliques
import SimplicialComplex

--number of vertices paired with
--2D array of simplices organized according to dimension
--each array of simplices should be sorted based on filtration index
type Filtration = (Int, Vector (Vector (Int, Vector Int, Vector Int)))

--gets the simplicial complex at the specified filtration index
getComplex :: Int -> Filtration -> SimplicialComplex
getComplex index (n, simplices) = (n, V.map (V.map not1 . V.filter (\(i, _, _) -> i == index)) simplices)

getDimension :: Filtration -> Int
getDimension = V.length . snd

sim2String :: (Int, Vector Int, Vector Int) -> String
sim2String (index, vertices, faces) =
  "Filtration index: " L.++ (show index) L.++
    "; Vertex indices: " L.++ (show vertices) L.++
      "; Boundary indices: " L.++ (show faces) L.++ "\n"

filtr2String :: Filtration -> String
filtr2String = (intercalate "\n") . toList . (V.map (L.concat . toList . (V.map sim2String))) . snd

type BarCode = (Int, Maybe Int)

--scales must be in decreasing order
makeFiltrationFast :: (Ord a, Eq b) => [a] -> (b -> b -> a) -> [b] -> Filtration
makeFiltrationFast scales metric dataSet =
  let edgeInSimplex edge simplex  = (existsVec (\x -> V.head edge == x) simplex) && (existsVec (\x -> V.last edge == x) simplex)
      ((verts, simplices), graph) = makeVRComplexFast (L.head scales) metric dataSet
      edgeTooLong scale edge      = scale <= (fst $ graph ! (edge ! 0) ! (edge ! 1))
      maxIndex                    = (L.length scales) - 1

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

  in (verts, sortFiltration $ --sort the simplices by filtration index
      calcIndices maxIndex (L.tail scales) $
        V.map (V.map (\(v, f) -> (0, v, f))) $ simplices)

--scales must be in decreasing order
makeFiltrationLight :: (Ord a, Eq b) => [a] -> (b -> b -> a) -> [b] -> Filtration
makeFiltrationLight scales metric dataSet =
  let edgeInSimplex edge simplex  = (existsVec (\x -> V.head edge == x) simplex) && (existsVec (\x -> V.last edge == x) simplex)
      (verts, simplices)          = makeVRComplexLight (L.head scales) metric dataSet
      vector                      = V.fromList dataSet
      edgeTooLong scale edge      = scale <= (metric (vector ! (edge ! 0)) (vector ! (edge ! 1)))
      maxIndex                    = (L.length scales) - 1

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
                      Nothing -> error "Persistence.makeFiltrationLight.sortFiltration.newFaces.findNew"
              in (i, v, (V.map findNew f))
        in
          if V.null simplices then simplices
          else mapWithIndex (\i ss -> V.map ((newFaces i) . fst) ss) sortedSimplices

  in (verts, sortFiltration $ --sort the simplices by filtration index
      calcIndices maxIndex (L.tail scales) $
        V.map (V.map (\(v, f) -> (0, v, f))) $ simplices)

persistentHomology :: Filtration -> [[BarCode]]
persistentHomology (numVerts, allSimplices) =
  let
      --union minus intersection
      uin :: Ord a => Vector a -> Vector a -> Vector a
      u `uin` v =
        let findAndInsert elem vec =
              let (vec1, vec2) = biFilter (\x -> x > elem) vec
              in
                if V.null vec2 then vec `snoc` elem
                else if elem == V.head vec2 then vec1 V.++ V.tail vec2
                else vec1 V.++ (elem `cons` vec2)
        in
          if V.null u then v
          else (V.tail u) `uin` (findAndInsert (V.head u) v)
          
      removeUnmarked marked = V.filter (\x -> existsVec (\y -> y == x) marked)

      removePivotRows reduced chain =
        if V.null chain then chain
        else
          case reduced ! (V.head chain) of
            Nothing -> chain
            Just t  -> removePivotRows reduced (chain `uin` t) --eliminate the element corresponding to the pivot in a different chain

      makeBarCodesAndMark :: Int -> Int -> Vector Int -> Vector (Maybe (Vector Int)) -> Vector (Int, Vector Int, Vector Int) -> ([BarCode], Vector Int) -> ([BarCode], Vector Int, Vector Int)
      makeBarCodesAndMark dim index marked reduced simplices (codes, newMarked)
        | V.null simplices = (codes, newMarked, V.findIndices (\x -> x == Nothing) reduced)
        | V.null d         = makeBarCodesAndMark dim (index + 1) marked reduced (V.tail simplices) (codes, index `cons` newMarked)
        | otherwise        =
          let begin = one $ allSimplices ! (dim - 1) ! (V.head d)
          in makeBarCodesAndMark dim (index + 1) marked (replaceElem (V.head d) (Just d) reduced) (V.tail simplices)
              (if begin == i then codes else (begin, Just i):codes, newMarked)
        where (i, v, f) = V.head simplices
              d         = removePivotRows reduced $ removeUnmarked marked f

      makeEdgeCodes :: Int -> Vector (Maybe (Vector Int)) -> Vector (Int, Vector Int, Vector Int) -> ([BarCode], Vector Int) -> ([BarCode], Vector Int, Vector Int)
      makeEdgeCodes index reduced edges (codes, marked)
        | V.null edges = (codes, marked, V.findIndices (\x -> x == Nothing) reduced)
        | V.null d     = makeEdgeCodes (index + 1) reduced (V.tail edges) (codes, index `cons` marked)
        | otherwise    =
          makeEdgeCodes (index + 1) (replaceElem (V.head d) (Just d) reduced) (V.tail edges) (if i == 0 then codes else (0, Just i):codes, marked)
        where (i, v, f) = V.head edges
              d         = removePivotRows reduced f
      
      makeFiniteBarCodes :: Int -> Int -> [[BarCode]] -> Vector (Vector Int) -> Vector (Vector Int) -> ([[BarCode]], Vector (Vector Int), Vector (Vector Int))
      makeFiniteBarCodes dim maxdim barcodes marked slots =
        if dim == maxdim then (barcodes, marked, slots)
        else
          let (newCodes, newMarked, unusedSlots) =
                makeBarCodesAndMark dim 0 (V.last marked) (V.replicate (V.length $ allSimplices ! (dim - 1)) Nothing) (allSimplices ! dim) ([], V.empty)
          in makeFiniteBarCodes (dim + 1) maxdim (barcodes L.++ [newCodes]) (marked `snoc` newMarked) (slots `snoc` unusedSlots)

      makeInfiniteBarCodes :: ([[BarCode]], Vector (Vector Int), Vector (Vector Int)) -> [[BarCode]]
      makeInfiniteBarCodes (barcodes, marked, unusedSlots) =
        let makeCodes i codes =
              let slots = unusedSlots ! i; marks = marked ! i
              in codes L.++ (V.toList $ V.map (\j -> (one $ allSimplices ! i ! j, Nothing)) $ slots |^| marks)
            loop i []     = []
            loop i (x:xs) = (makeCodes i x):(loop (i + 1) xs)
        in loop 0 barcodes

      edges    = V.map (\(i, v, f) -> (i, v, (V.reverse v))) $ V.head allSimplices
      numEdges = V.length edges

      (fstCodes, fstMarked, fstSlots) = makeEdgeCodes 0 (V.replicate numVerts Nothing) edges ([], V.empty)

  in makeInfiniteBarCodes $ makeFiniteBarCodes 1 (V.length allSimplices) [fstCodes] (fstMarked `cons` V.empty) (fstSlots `cons` V.empty)