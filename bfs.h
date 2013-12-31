/*
 * bfs.h
 *
 *  Created on: Dec 2, 2013
 *      Author: zhisong
 */

#ifndef BFS_H_
#define BFS_H_

#include <b40c/graph/GASengine/csr_problem.cuh>

//TODO: edge data not currently represented
//TODO: initialize frontier
struct bfs
{
  typedef int DataType;
  typedef DataType MiscType;
  typedef DataType GatherType;

  static const DataType INIT_VALUE = -1;

  struct VertexType
  {
    int* d_labels;
    int nodes;
    int edges;

    VertexType() :
        d_labels(NULL), nodes(0), edges(0)
    {
    }
  };

  static void Initialize(const int nodes, const int edges, int num_srcs,
      int* srcs, int* d_row_offsets, int* d_column_indices, int* d_column_offsets, int* d_row_indices,
      VertexType &vertex_list, int* d_frontier_keys[3],
      MiscType* d_frontier_values[3])
  {
    vertex_list.nodes = nodes;
    vertex_list.edges = edges;

    b40c::util::B40CPerror(cudaMalloc((void**) &vertex_list.d_labels, nodes * sizeof(int)), "cudaMalloc VertexType::d_labels failed", __FILE__, __LINE__);

    int memset_block_size = 256;
    int memset_grid_size_max = 32 * 1024; // 32K CTAs
    int memset_grid_size;

    // Initialize d_labels elements to -1
    memset_grid_size = B40C_MIN(memset_grid_size_max, (nodes + memset_block_size - 1) / memset_block_size);
    b40c::util::MemsetKernel<int><<<memset_grid_size, memset_block_size, 0, 0>>>(
        vertex_list.d_labels,
        -1,
        nodes);

    if (b40c::util::B40CPerror(
        cudaMemcpy(d_frontier_keys[0], srcs, num_srcs * sizeof(int),
            cudaMemcpyHostToDevice),
        "CsrProblem cudaMemcpy d_frontier_keys failed", __FILE__,
        __LINE__))
      exit(0);

    if (b40c::util::B40CPerror(
        cudaMemcpy(d_frontier_keys[1], srcs, num_srcs * sizeof(int),
            cudaMemcpyHostToDevice),
        "CsrProblem cudaMemcpy d_frontier_keys failed", __FILE__,
        __LINE__))
      exit(0);

    int init_value[1] = { 0 };
    if (b40c::util::B40CPerror(
        cudaMemcpy(d_frontier_values[0], init_value,
            num_srcs * sizeof(int), cudaMemcpyHostToDevice),
        "CsrProblem cudaMemcpy d_frontier_values failed", __FILE__,
        __LINE__))
      exit(0);

    if (b40c::util::B40CPerror(
        cudaMemcpy(d_frontier_values[1], init_value,
            num_srcs * sizeof(int), cudaMemcpyHostToDevice),
        "CsrProblem cudaMemcpy d_frontier_values failed", __FILE__,
        __LINE__))
      exit(0);

  }

  static SrcVertex srcVertex()
  {
    return SINGLE;
  }

  static GatherEdges gatherOverEdges()
  {
    return NO_GATHER_EDGES;
  }

  static ApplyVertices applyOverEdges()
  {
    return NO_APPLY_VERTICES;
  }

  static ExpandEdges expandOverEdges()
  {
    return EXPAND_OUT_EDGES;
  }

  static PostApplyVertices postApplyOverEdges()
  {
    return POST_APPLY_FRONTIER;
  }

  struct contract
  {
    __device__
    void operator()(const int iteration, int &vertex_id,
        VertexType &vertex_list, int& misc_value)
    {
      // Load label of node
      int row_id = vertex_id;
      int label;
      label = vertex_list.d_labels[row_id];

      if (label != -1)
      {

        // Seen it
        vertex_id = -1;

      }
      else
      {

        // Update label with current iteration
        vertex_list.d_labels[row_id] = iteration;
      }
    }
  };

  /**
   * the binary operator
   */
  struct gather_sum
  {
    __device__
    GatherType operator()(GatherType left, GatherType right)
    {
      return left + right;
    }
  };

  /**
   * For each vertex in the frontier,
   */
  struct gather_vertex
  {
    __device__
    void operator()(int row_id, GatherType final_value, VertexType &vertex_list)
    {

    }
  };

  /** post-apply function (invoked after threads in apply() synchronize at a memory barrier). */
  struct post_apply
  {
    __device__
    void operator()(const int vertex_id, VertexType& vertex_list)
    {
    }
  };

  struct expand_vertex
  {
    __device__
    bool operator()(int &row_id, VertexType &vertex_list)
    {
      return true;
    }
  };

  struct expand_edge
  {
    __device__
    void operator()(const bool changed, const int iteration,
        const int vertex_id, const int neighbor_id_in,
        VertexType& vertex_list, int& frontier, int& misc_value)
    {
      misc_value = vertex_id;
      frontier = neighbor_id_in;
    }
  };

  struct gather_edge
  {
    __device__
    void operator()(int row_id, int neighbor_id_in, VertexType &vertex_list, int& new_value)
    {

    }
  };

  struct sum
  {
    __device__
    int operator()(int left, int right)
    {
      return min(left, right);
    }
  };

  struct reset
  {
    __device__
    void operator()(VertexType& vertex_list, int v)
    {
    }
  };

  struct apply
  {
    __device__
    void operator()(const int vertex_id, const int iteration,
        VertexType& vertex_list)
    {
    }
  };

  static void extractResult(VertexType& vertex_list, DataType* h_output)
  {
    cudaMemcpy(h_output, vertex_list.d_labels, sizeof(DataType) * vertex_list.nodes, cudaMemcpyDeviceToHost);
  }

};

#endif /* BFS_H_ */
