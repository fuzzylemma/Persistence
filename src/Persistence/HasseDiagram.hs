{- |
Module     : Persistence.HasseDiagram
Copyright  : (c) Eben Kadile, 2018
License    : BSD 3 Clause
Maintainer : eben.cowley42@gmail.com
Stability  : experimental

This module allows one to do computations involving directed graphs. Namely, it allows you to convert a directed graph (presented in a generic way) into a simplicial complex and provides functions for constructing the "directed clique complex," see below.

This module uses algorithms for admissible Hasse diagrams. A Hasse diagram is admissible if it is stratified and oriented. A diagram is stratified if all the vertices can be arranged in rows such that all the sources of each vertex are in the next highest row and all the targets are in the next lowest row. A diagram is oriented if every vertex has a linear ordering on its targets.

A node in the diagram is represented as a tuple: the indices of the level 0 nodes in the diagram that are reachable from this node, the indices of targets in the next lowest level, and the indices of the sources in the next highest level. The entire diagram is simply an array of arrays representing each particular level; index 0 represents level 0, etc.

Any directed graph can be encoded as an admissible Hasse diagram with 2 levels. The edges are level 1 and the vertices are level 0. The ordering on the targets of a node representing an edge is simply the terminal vertex first and the initial vertex second. This may be counterintuitive, but its helpful to interpret an arrow between two vertices as the "<" operator. This induces a linear ordering on the vertices of any acyclic complete subgraph - which is what the nodes in the Hasse diagram of the directed clique complex represent.

Any oriented simplicial complex can also be encoded as an admissible Hasse diagram. A node is a simplex, the targets are the faces of the simplex, and the sources are simplices of which the given simplex is a face.

The main feature of this module is an algorithm which takes the Hasse diagram of a directed graph and generates the Hasse diagram of the directed flag complex - the simplicial complex whose simplices are acyclic complete subgraphs of the given graph. Here acyclic refers to a directed graph without any sequence of arrows whose heads and tails match up and which has the same start and end vertex.

The idea is that, if your directed graph represents any kind of information flow, "sub-modules" in the network are groups of nodes that simply take input, process it, and then output it without spinning the information around at all. These "sub-modules" are the directed cliques/flags which I've been referring to as acyclic complete subgraphs up to this point. Constructing a simplicial complex out of them will allow you to both simplify the 1-dimensional topology of the network and possibly detect higher-dimensional topological features.

The algorithm for constructing the directed clique complex comes from this paper by Markram et al: https://www.frontiersin.org/articles/10.3389/fncom.2017.00048/full.

-}

module Persistence.HasseDiagram
  ( Node
  , HasseDiagram
  , hsd2String
  , dGraph2sc
  , encodeDirectedGraph
  , directedFlagComplex
  , hDiagram2sc
  ) where

import Persistence.Util
import Persistence.Graph
import Persistence.SimplicialComplex

import Data.List           as L
import Data.Vector         as V
import Data.Vector.Unboxed as UV

{- |
  Type representing a node in a Hasse diagram.
  Hasse diagrams are being used to represent simplicial complexes so each node represents a simplex.
  Contents of the tuple in order: Vector of references to vertices of the underlying directed graph,
  vector of references to the simplices faes in the next lowest level of the Hasse diagram,
  vector of references to "parent" simplices (simplices who have this simplex as a face) in the next highest level of the Hasse diagram.
-}
type Node = (UV.Vector Int, UV.Vector Int, UV.Vector Int)

-- | Type representing an admissible Hasse diagram. Each entry in the vector represents a level in the Hasse diagram.
type HasseDiagram = V.Vector (V.Vector Node)

-- | Simple printing function for Hasse diagrams.
hsd2String :: HasseDiagram -> String
hsd2String =
  (L.intercalate "\n\n") . V.toList . (V.map (L.intercalate "\n" . V.toList . V.map show))

{- |
  Given the number of vertices in a directed graph,
  and pairs representing the direction of each edge,
  construct a 1-dimensional simplicial complex in the canonical way.
  Betti numbers of this simplicial complex can be used to count cycles and connected components.
-}
dGraph2sc :: Int -> [(Int, Int)] -> SimplicialComplex
dGraph2sc v edges =
  (v, V.fromList [V.fromList $ L.map (\(i, j) ->
    (i `UV.cons` (j `UV.cons` UV.empty), UV.empty)) edges])

{- |
  Given the number of vertices in a directed graph,
  and pairs representing the direction of each edge (initial, terminal),
  construct a Hasse diagram representing the graph.
-}
encodeDirectedGraph :: Int -> [(Int, Int)] -> HasseDiagram
encodeDirectedGraph numVerts cxns =
  let verts       = V.map (\n ->
                      (n `UV.cons` UV.empty, UV.empty, UV.empty)) $ 0 `range` (numVerts - 1)

      encodeEdges :: Int -> V.Vector Node -> V.Vector Node -> [(Int, Int)] -> HasseDiagram
      encodeEdges _ vertices edges []          = V.empty `V.snoc` vertices `V.snoc` edges
      encodeEdges n vertices edges ((i, j):xs) =
        let v1       = vertices V.! i
            v2       = vertices V.! j
            edge     = UV.empty `UV.snoc` j `UV.snoc` i
            newverts = replaceElem i (one v1, two v1, (thr v1) `UV.snoc` n)
                         $ replaceElem j (one v2, two v2, (thr v2) `UV.snoc` n) vertices
            newedges = edges `V.snoc` (edge, edge, UV.empty)
        in encodeEdges (n + 1) newverts newedges xs

  in encodeEdges 0 verts V.empty cxns

{- |
Given a Hasse diagram representing a directed graph, construct the diagram representing the directed clique/flag complex of the graph.
Algorithm adapted from the one shown in the supplementary materials of this paper: https://www.frontiersin.org/articles/10.3389/fncom.2017.00048/full
-}
directedFlagComplex :: HasseDiagram -> HasseDiagram
directedFlagComplex directedGraph =
  let edges      = V.last directedGraph
      sameSource = \e1 e2 -> (two e1) UV.! 0 == (two e2) UV.! 0
      sameTarget = \e1 e2 -> (two e1) UV.! 1 == (two e2) UV.! 1
      targ2Src   = \e1 e2 -> (two e1) UV.! 1 == (two e2) UV.! 0
      fstSinks =
        V.map (\e ->
          V.map (\(e0, _) ->
            (two e0) UV.! 0) $ findBothElems sameSource
              (V.filter (sameTarget e) edges) (V.filter (targ2Src e) edges)) edges

      --take last level of nodes and their sinks
      --return modified last level, new level, and new sinks
      makeLevel :: Bool
                -> HasseDiagram
                -> V.Vector Node
                -> V.Vector (V.Vector Int)
                -> (V.Vector Node, V.Vector Node, V.Vector (V.Vector Int))
      makeLevel fstIter result oldNodes oldSinks =
        let maxindex = V.length oldNodes

            --given a node and a specific sink
            --construct a new node with new sinks that has the given index
            --Fst output is the modified input nodes
            --snd output is the new node, thrd output is the sinks of the new node
            makeNode :: Int
                     -> Int
                     -> Int
                     -> V.Vector Node
                     -> V.Vector Int
                     -> (V.Vector Node, Node, V.Vector Int)
            makeNode newIndex oldIndex sinkIndex nodes sinks =
              let sink     = sinks V.! sinkIndex
                  oldNode  = nodes V.! oldIndex
                  --the vertices of the new simplex are
                  --the vertices of the old simplex plus the sink
                  verts    = sink `UV.cons` (one oldNode)
                  numFaces = UV.length $ two oldNode

                  --find all the faces of the new node by looking at the faces of the old node
                  testTargets :: Int
                              -> Node
                              -> V.Vector Node
                              -> Node
                              -> V.Vector Int
                              -> (V.Vector Node, Node, V.Vector Int)
                  testTargets i onode onodes newNode newSinks =
                    let toi       = (two onode) UV.! i
                        faceVerts =
                          if fstIter then one $ (V.last $ V.init $ result) V.! toi
                          else one $ (V.last $ result) V.! toi
                    in
                      if i == numFaces then (onodes, newNode, newSinks)
                      else
                        case V.find (\(_, (v, _, _)) ->
                               UV.head v == sink && UV.tail v == faceVerts)
                                 $ mapWithIndex (\j n -> (j, n)) onodes of
                          Just (j, n) ->
                            let newNode' = (one newNode, (two newNode) `UV.snoc` j, thr newNode)
                                onodes'  = replaceElem j
                                             (one n, two n, (thr n) `smartSnoc` newIndex) onodes
                            in testTargets (i + 1) onode onodes'
                                 newNode (newSinks |^| (oldSinks V.! j))
                          Nothing     -> error "Persistence.HasseDiagram.directedFlagComplex.makeDiagram.makeNode.testTargets. This is a bug. Please email the Persistence maintainers."

              in testTargets 0 oldNode nodes (verts, oldIndex `UV.cons` UV.empty, UV.empty) sinks

            loopSinks :: Int
                      -> Int
                      -> V.Vector Node
                      -> (V.Vector Node, V.Vector Node, V.Vector (V.Vector Int), Int)
            loopSinks nodeIndex lastIndex nodes =
              let node     = oldNodes V.! nodeIndex
                  sinks    = oldSinks V.! nodeIndex
                  numSinks = V.length sinks

                  loop i (modifiedNodes, newNodes, newSinks) =
                    if i == numSinks then (modifiedNodes, newNodes, newSinks, i + lastIndex)
                    else
                      let (modNodes, newNode, ns) =
                            makeNode (i + lastIndex) nodeIndex i modifiedNodes sinks
                      in loop (i + 1) (modNodes, newNodes `V.snoc` newNode, newSinks `V.snoc` ns)

              in loop 0 (nodes, V.empty, V.empty)

            loopNodes :: Int
                      -> Int
                      -> V.Vector Node
                      -> V.Vector Node
                      -> V.Vector (V.Vector Int)
                      -> (V.Vector Node, V.Vector Node, V.Vector (V.Vector Int))
            loopNodes i lastIndex nodes newNodes newSinks =
              if i == maxindex then (nodes, newNodes, newSinks)
              else
                let (modifiedNodes, nnodes, nsinks, index) = loopSinks i lastIndex nodes
                in loopNodes (i + 1) lastIndex modifiedNodes
                     (newNodes V.++ nnodes) (newSinks V.++ nsinks)

        in loopNodes 0 0 oldNodes V.empty V.empty

      loopLevels :: Int -> HasseDiagram -> V.Vector Node -> V.Vector (V.Vector Int) -> HasseDiagram
      loopLevels iter diagram nextNodes sinks =
        let (modifiedNodes, newNodes, newSinks) = makeLevel (iter < 2) diagram nextNodes sinks
            newDiagram                          = diagram `V.snoc` modifiedNodes
        in
          if V.null newNodes then newDiagram
          else loopLevels (iter + 1) newDiagram newNodes newSinks

  in loopLevels 0 directedGraph edges fstSinks

-- | Convert a Hasse diagram to a simplicial complex.
hDiagram2sc :: HasseDiagram -> SimplicialComplex
hDiagram2sc diagram =
  let sc = V.map (V.map not3) $ V.tail diagram
  in (V.length $ V.head diagram, (V.map (\(v, _) -> (v, UV.empty)) $ sc V.! 0) `V.cons` V.tail sc)