module Persistence where

import Util
import Matrix
import Data.List as L
import MaximalCliques
import Data.Vector as V
import SimplicialComplex

--the index of the filtration where the simplex enters
--indices of the vertices in the original data set
--and indices of the faces in the filtration
data Simplex = Simplex Int (Vector Int) (Vector Int)

getIndex (Simplex i _ _) = i

instance Eq Simplex where
  (==) = \(Simplex a _ _) (Simplex b _ _) -> a == b

instance Ord Simplex where
  (>)   = \(Simplex a _ _) (Simplex b _ _) -> a > b
  (<)   = \(Simplex a _ _) (Simplex b _ _) -> a < b
  (<=)  = \(Simplex a _ _) (Simplex b _ _) -> a <= b
  (>=)  = \(Simplex a _ _) (Simplex b _ _) -> a >= b

sim2String :: Simplex -> String
sim2String (Simplex index vertices faces) =
  "Filtration index: " L.++ (show index) L.++
    "\nVertex indices: " L.++ (show vertices) L.++
      "\nBoundary indices: " L.++ (show faces) L.++ "\nend\n"

--number of vertices paired with
--2D array of simplices organized according to dimension
--each array of simplices should be sorted based on filtration index
type Filtration = (Int, Vector (Vector Simplex))

filtr2String :: Filtration -> String
filtr2String = (intercalate "\n") . toList . (V.map (L.concat . toList . (V.map sim2String))) . snd

--scales must be in decreasing order
makeFiltration :: (Ord a, Eq b) => [a] -> (b -> b -> a) -> [b] -> Filtration
makeFiltration scales metric dataSet =
  let edgeNotInSimplex edge       = forallVec (\x -> V.head edge /= x && V.last edge /= x)
      edgeToLong scale edge       = metric (dataSet !! (V.head edge)) (dataSet !! (V.last edge)) > scale
      calcIndices 0 [] sc         = sc
      calcIndices i (scl:scls) sc =
        let longEdges = V.filter (edgeToLong scl) $ V.map (\(Simplex i v f) -> v) $ V.head sc --find edges excluded by this scale
        in calcIndices (i - 1) scls $
          V.map (V.map (\(Simplex j v f) ->
            if j == 0 then --if the simplex has not yet been assigned a filtration index
              if forallVec (\edge -> edgeNotInSimplex edge v) longEdges then Simplex 0 v f --check if it isnt excluded by this scale
              else Simplex i v f --if it is excluded, assign to it the current filtration index
            else Simplex j v f)) sc --if it already has an index, do not change it
      maxIndex           = (L.length scales) - 1
      (verts, simplices) = makeVRComplex (L.head scales) metric dataSet
  in (verts, V.map quicksort $ --sort the simplices by filtration index
      calcIndices maxIndex (L.tail scales) $
        V.map (V.map (\(v, f) -> Simplex 0 v f)) $ fromList $ simplices)

edgeBoundaryBool :: Filtration -> BPolyMat
edgeBoundaryBool (verts, simplices) =
  if V.null simplices then V.empty
  else
    let makeBoundary (Simplex i v f) =
          replaceElem (f ! 0) (Power i) $ replaceElem (f ! 1) (Power i) $ V.replicate verts Zero
    in transposeMat $ V.map makeBoundary $ V.head simplices

boundOpBool :: Int -> Filtration -> BPolyMat
boundOpBool dim (verts, simplices) =
  let makeBoundary (Simplex i v f) =
        let makeMonomial j =
              if V.elem j f then
                let (Simplex k v f) = simplices ! (dim - 2) ! j
                in Power $ i - k
              else Zero
        in V.map makeMonomial $ 0 `range` ((V.length $ simplices ! (dim - 2)) - 1)
  in transposeMat $ V.map makeBoundary $ simplices ! (dim - 1)

boundaryOperatorsBool :: Filtration -> Vector BPolyMat
boundaryOperatorsBool f =
  let calc 1 = (edgeBoundaryBool f) `cons` V.empty
      calc i = (boundOpBool i f) `cons` (calc $ i - 1)
  in calc $ V.length $ snd f

persistentHomologyBool :: Filtration -> [[(Int, Int)]]
persistentHomologyBool filtration =
  let boundOps   = boundaryOperatorsBool filtration
      max        = (V.length boundOps) - 1

      reduce i ixs ops =
        if i == max then (ixs, ops) --need to get final column eschelon form!
        else
          let i1     = i + 1
              triple = eschelonAndNextBool (ops ! i) (ops ! i1)
          in reduce i1 (ixs `snoc` (two triple)) $ replaceElem i (one triple) $ replaceElem i1 (thr triple) ops

      getEdgeBarCodes op =
        let find j =
              case V.findIndex (\x -> x /= Zero) $ V.map (\r -> r ! j) op of
                Just k  ->
                  case op ! k ! j of
                    Power p -> (0, p):(find $ j + 1)
                    Zero    -> error "The impossible happened; Persistence.persistentHomologyBool.getEdgeBarCodes.find"
                Nothing -> []
        in find 0

      getBarCodes i ops indices =
        if V.null ops then []
        else
          let op     = V.head ops

              find j =
                case V.findIndex (\x -> x /= Zero) $ V.map (\r -> r ! j) op of
                  Just k  ->
                    case op ! k ! j of
                      Power p ->
                        let i1 = i - 1; rowIndex = getIndex $ (snd filtration) ! i1 ! (indices ! i1 ! k)
                        in (rowIndex, rowIndex + p):(find $ j + 1)
                      Zero    -> error "The impossible happened; Persistence.persistentHomologyBool.getBarCodes.find"
                  Nothing -> []
          in (find 0):(getBarCodes (i + 1) (V.tail ops) indices)

      reduced = reduce 0 V.empty boundOps
  in (getEdgeBarCodes $ V.head $ snd reduced):(getBarCodes 1 (V.tail $ snd reduced) (fst reduced))