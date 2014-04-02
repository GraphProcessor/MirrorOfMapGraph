/******************************************************************************
 * enactor
 ******************************************************************************/

#pragma once

#include <stdlib.h>

#include <config.h>

#include <b40c/util/spine.cuh>
#include <b40c/util/kernel_runtime_stats.cuh>
#include <b40c/util/global_barrier.cuh>

#include <GASengine/problem_type.cuh>
#include <GASengine/csr_problem.cuh>
#include <GASengine/enactor_base.cuh>

//#include <GASengine/vertex_centric/gather/kernel.cuh>
//#include <GASengine/vertex_centric/gather/kernel_policy.cuh>
#include <GASengine/vertex_centric/mgpukernel/kernel.cuh>
#include <GASengine/vertex_centric/expand_atomic/kernel.cuh>
#include <GASengine/vertex_centric/expand_atomic/kernel_policy.cuh>
#include <GASengine/vertex_centric/expand_atomic_flag/kernel.cuh>
#include <GASengine/vertex_centric/expand_atomic_flag/kernel_policy.cuh>
#include <GASengine/vertex_centric/contract_atomic/kernel.cuh>
#include <GASengine/vertex_centric/contract_atomic/kernel_policy.cuh>

#include <thrust/device_vector.h>
#include <thrust/device_ptr.h>
#include <thrust/copy.h>
#include <thrust/sort.h>
#include <thrust/transform.h>
#include <thrust/functional.h>

#include <vector>
#include <iterator>
#include <moderngpu.cuh>
//#include <util.h>
#include <util/mgpucontext.h>
#include <mgpuenums.h>

using namespace b40c;

using namespace std;

namespace GASengine
{
  template<typename CsrProblem, typename Program, bool INSTRUMENT> // Whether or not to collect per-CTA clock-count statistics
  class EnactorVertexCentric: public EnactorBase
  {
    //---------------------------------------------------------------------
    // Members
    //---------------------------------------------------------------------

  protected:

    //convenience
    void errorCheck(cudaError_t err, const char* file, int line)
    {
      if (err != cudaSuccess)
      {
        printf("%s(%d): cuda error %d (%s)\n", file, line, err, cudaGetErrorString(err));
        abort();
      }
    }

    //use only for debugging kernels
    //this slows stuff down a LOT
    void syncAndErrorCheck(const char* file, int line)
    {
      cudaDeviceSynchronize();
      errorCheck(cudaGetLastError(), file, line);
    }

    //this is undefined at the end of this template definition
#define CHECK(X) errorCheck(X, __FILE__, __LINE__)
#define SYNC_CHECK() syncAndErrorCheck(__FILE__, __LINE__)

    /**
     * CTA duty kernel stats
     */
    util::KernelRuntimeStatsLifetime expand_kernel_stats;
    util::KernelRuntimeStatsLifetime filter_kernel_stats;
    util::KernelRuntimeStatsLifetime contract_kernel_stats;
    util::KernelRuntimeStatsLifetime backward_sum_kernel_stats;
    util::KernelRuntimeStatsLifetime backward_contract_kernel_stats;

    unsigned long long total_runtimes; // Total time "worked" by each cta
    unsigned long long total_lifetimes; // Total time elapsed by each cta
    unsigned long long total_queued;

    volatile int *done;
    int *d_done;
    cudaEvent_t throttle_event;
    Config cfg;
    mgpu::ContextPtr m_mgpuContext;

    /**
     * Mechanism for implementing software global barriers from within
     * a single grid invocation
     */
    util::GlobalBarrierLifetime global_barrier;

    /**
     * Current iteration (mapped into GPU space so that it can
     * be modified by multi-iteration kernel launches)
     */
    volatile long long *iteration;
    long long *d_iteration;

    //---------------------------------------------------------------------
    // Methods
    //---------------------------------------------------------------------

  protected:

    /**
     * Prepare enactor for search.  Must be called prior to each search.
     */
    cudaError_t Setup(CsrProblem &csr_problem, int expand_grid_size,
        int contract_grid_size, int iter)
    {
      typedef typename CsrProblem::SizeT SizeT;
      typedef typename CsrProblem::VertexId VertexId;
      typedef typename CsrProblem::VisitedMask VisitedMask;

      cudaError_t retval = cudaSuccess;

      do
      {

        // Make sure host-mapped "done" is initialized
        if (!done)
        {
          int flags = cudaHostAllocMapped;

          // Allocate pinned memory for done
          if (retval = util::B40CPerror(
              cudaHostAlloc((void **) &done, sizeof(int) * 1, flags),
              "EnactorContractExpand cudaHostAlloc done failed",
              __FILE__, __LINE__))
            break;

          // Map done into GPU space
          if (retval =
              util::B40CPerror(
                  cudaHostGetDevicePointer((void **) &d_done,
                      (void *) done, 0),
                  "EnactorContractExpand cudaHostGetDevicePointer done failed",
                  __FILE__, __LINE__))
            break;

          // Create throttle event
          if (retval =
              util::B40CPerror(
                  cudaEventCreateWithFlags(&throttle_event,
                      cudaEventDisableTiming),
                  "EnactorContractExpand cudaEventCreateWithFlags throttle_event failed",
                  __FILE__, __LINE__))
            break;
        }

        // Make sure host-mapped "iteration" is initialized
        if (!iteration)
        {

          int flags = cudaHostAllocMapped;

          // Allocate pinned memory
          if (retval = util::B40CPerror(
              cudaHostAlloc((void **) &iteration,
                  sizeof(long long) * 1, flags),
              "EnactorContractExpand cudaHostAlloc iteration failed",
              __FILE__, __LINE__))
            break;

          // Map into GPU space
          if (retval =
              util::B40CPerror(
                  cudaHostGetDevicePointer((void **) &d_iteration,
                      (void *) iteration, 0),
                  "EnactorContractExpand cudaHostGetDevicePointer iteration failed",
                  __FILE__, __LINE__))
            break;
        }

        // Make sure software global barriers are initialized
        if (retval = global_barrier.Setup(expand_grid_size))
          break;

        // Make sure our runtime stats are initialized
        if (retval = expand_kernel_stats.Setup(expand_grid_size))
          break;
        if (retval = contract_kernel_stats.Setup(contract_grid_size))
          break;
//            if (retval = filter_kernel_stats.Setup(filter_grid_size)) break;
        if (retval = backward_sum_kernel_stats.Setup(expand_grid_size))
          break;
        if (retval = backward_contract_kernel_stats.Setup(
            contract_grid_size))
          break;

        // Reset statistics
        iteration[0] = iter;
        total_runtimes = 0;
        total_lifetimes = 0;
        total_queued = 0;
        done[0] = -1;

        // Single-gpu graph slice
        typename CsrProblem::GraphSlice *graph_slice =
            csr_problem.graph_slices[0];

        // Bind bitmask texture
        int bytes = (graph_slice->nodes + 8 - 1) / 8;
        cudaChannelFormatDesc bitmask_desc = cudaCreateChannelDesc<char>();
        if (retval =
            util::B40CPerror(
                cudaBindTexture(0,
                    vertex_centric::contract_atomic::BitmaskTex<
                        VisitedMask>::ref,
                    graph_slice->d_visited_mask, bitmask_desc,
                    bytes),
                "EnactorVertexCentric cudaBindTexture bitmask_tex_ref failed",
                __FILE__, __LINE__))
          break;
      }
      while (0);

      return retval;
    }

  public:
    int *m_hostMappedValue;
    int *m_deviceMappedValue;
    thrust::device_vector<int> d_vertex_ids;
    int* d_frontier_size;
    int* d_edge_frontier_size;
    int frontier_size;
    int edge_frontier_size;

    typedef typename Program::VertexId VertexId;
    typedef typename Program::SizeT SizeT;
    typedef typename Program::DataType DataType;
    typedef typename Program::GatherType GatherType;

    GatherType *m_gatherMapTmp;
    GatherType *m_gatherTmp;
    GatherType *m_gatherTmp1;
    GatherType *m_gatherTmp2;
    VertexId *m_gatherDstsTmp;
    std::auto_ptr<mgpu::ReduceByKeyPreprocessData> preprocessData;
    bool preComputed;

    /**
     * Constructor
     */
    EnactorVertexCentric(Config cfg, bool DEBUG = false) :
        cfg(cfg), EnactorBase(EDGE_FRONTIERS, DEBUG), iteration(NULL), d_iteration(
            NULL), total_queued(0), done(NULL), d_done(NULL), preComputed(false)
    {
    }

    /**
     * Destructor
     */
    virtual ~EnactorVertexCentric()
    {
      if (iteration)
      {
        util::B40CPerror(cudaFreeHost((void *) iteration),
            "EnactorVertexCentric cudaFreeHost iteration failed",
            __FILE__, __LINE__);
      }
      if (done)
      {
        util::B40CPerror(cudaFreeHost((void *) done),
            "EnactorVertexCentric cudaFreeHost done failed", __FILE__,
            __LINE__);

        util::B40CPerror(cudaEventDestroy(throttle_event),
            "EnactorVertexCentric cudaEventDestroy throttle_event failed",
            __FILE__, __LINE__);
      }
    }

    /**
     * Obtain statistics about the last BFS search enacted
     */
    void GetStatistics(long long &total_queued, VertexId &search_depth,
        double &avg_duty)
    {
      cudaThreadSynchronize();

      total_queued = this->total_queued;
      search_depth = this->iteration[0] - 1;

      avg_duty =
          (total_lifetimes > 0) ?
                                  double(total_runtimes) / total_lifetimes :
                                  0.0;
    }

//	template<typename ContractPolicy, typename SizeT, typename CsrProblem,
//			typename Program>
//	void contract(bool DEBUG, SizeT frontier_size, int src, int selector, int queue_index,
//			int contract_grid_size,
//			typename CsrProblem::GraphSlice *graph_slice,
//			double &elapsedcontract) {
//		double startcontract, endcontract;
//		if (DEBUG)
//			startcontract = omp_get_wtime();
//
//		// Contraction
//		//
//		//
//		vertex_centric::contract_atomic::Kernel<ContractPolicy, Program><<<
//				contract_grid_size, ContractPolicy::THREADS>>>(
//				src,
//				iteration[0],
//				graph_slice->init_num_elements, // initial num_elements, for BFS it is 1
//				queue_index, // queue counter index
//				queue_index, // steal counter index
//				1, // number of GPUs
//				d_done,
//				graph_slice->frontier_queues.d_keys[selector ^ 1], // filtered edge frontier in
//				graph_slice->frontier_queues.d_keys[selector], // vertex frontier out
//				graph_slice->frontier_queues.d_values[selector ^ 1], // predecessor in
//				graph_slice->vertex_list, graph_slice->edge_list,
//				graph_slice->d_labels, // source distance out
//				graph_slice->d_preds, // prtedecessor out
//				graph_slice->d_sigmas, graph_slice->d_dists,
//				graph_slice->d_changed, graph_slice->d_visited_mask,
//				this->work_progress,
//				graph_slice->frontier_elements[selector ^ 1], // max filtered edge frontier vertices
//				graph_slice->frontier_elements[selector], // max vertex frontier vertices
//				this->contract_kernel_stats);
//
//		cudaError_t retval;
//		if ((retval = util::B40CPerror(cudaThreadSynchronize(),
//				"contract_atomic::Kernel failed ", __FILE__, __LINE__)))
//			exit(1);
//
//		cudaEventQuery(throttle_event); // give host memory mapped visibility to GPU updates
//
//		if (DEBUG) {
//			cudaDeviceSynchronize();
//			endcontract = omp_get_wtime();
//			elapsedcontract = endcontract - startcontract;
//		}
//
//		queue_index++;
//		selector ^= 1;
//
//		//        if (retval = work_progress.GetQueueLength(queue_index,
//		//                queue_length))
//		//        exit(1);
//		//        frontier_size = queue_length;
//		printf("DEBUG=%d\n", DEBUG);
//		if (DEBUG) {
//			int queue_length;
//			if (retval = work_progress.GetQueueLength(queue_index,
//					queue_length))
//				printf("queue_length after contraction: %lld\n",
//						(long long) queue_length);
//
//			//                  VertexId* test_vid = new VertexId[queue_length];
//			//                  cudaMemcpy(test_vid, graph_slice->frontier_queues.d_keys[selector ^ 1], queue_length * sizeof(VertexId), cudaMemcpyDeviceToHost);
//			//                  printf("Frontier after contraction: ");
//			//                  for (int i = 0; i < queue_length; ++i)
//			//                  {
//			//                    printf("%d, ", test_vid[i]);
//			//                  }
//			//                  printf("\n");
//			//                  delete[] test_vid;
//
//			//                EValue *test_vid2 = new EValue[graph_slice->nodes];
//			//                cudaMemcpy(test_vid2, graph_slice->vertex_list.d_dists, graph_slice->nodes * sizeof(EValue), cudaMemcpyDeviceToHost);
//			//                printf("d_dists after contract: ");
//			//                for (int i = 0; i < graph_slice->nodes; ++i)
//			//                {
//			//                  printf("%d, ", test_vid2[i]);
//			//                }
//			//                printf("\n");
//			//                delete[] test_vid2;
//
//			//                test_vid2 = new EValue[graph_slice->nodes];
//			//                cudaMemcpy(test_vid2, graph_slice->vertex_list.d_min_dists, graph_slice->nodes * sizeof(EValue), cudaMemcpyDeviceToHost);
//			//                printf("d_min_dists after contract: ");
//			//                for (int i = 0; i < graph_slice->nodes; ++i)
//			//                {
//			//                  printf("%d, ", test_vid2[i]);
//			//                }
//			//                printf("\n");
//			//                delete[] test_vid2;
//		}
//
//		// Throttle
//		if (iteration[0] & 1) {
//			if (retval =
//					util::B40CPerror(cudaEventRecord(throttle_event),
//							"EnactorVertexCentric cudaEventRecord throttle_event failed",
//							__FILE__, __LINE__))
//				exit(1);
//		} else {
//			if (retval =
//					util::B40CPerror(cudaEventSynchronize(throttle_event),
//							"EnactorVertexCentric cudaEventSynchronize throttle_event failed",
//							__FILE__, __LINE__))
//				exit(1);
//		};
//
//	}

    struct EdgeCountIterator: public std::iterator<std::input_iterator_tag, int>
    {
      int *m_offsets;
      int *m_active;

      __host__ __device__ EdgeCountIterator(int *offsets, int *active) :
          m_offsets(offsets), m_active(active)
      {
      }
      ;

      __device__
      int operator[](int i) const
          {
        int active = m_active[i];
        return max(m_offsets[active + 1] - m_offsets[active], 1);
      }

      __device__ EdgeCountIterator operator +(int i) const
          {
        return EdgeCountIterator(m_offsets, m_active + i);
      }
    };

    struct ReduceFunctor: std::binary_function<GatherType, GatherType, GatherType>
    {
      __device__ GatherType operator()(const GatherType &left, const GatherType &right)
      {
        typename Program::gather_sum gather_sum_functor;
        return gather_sum_functor(left, right);
      }
    };

    struct PredicatedEdgeCountIterator: public std::iterator<std::input_iterator_tag, VertexId>
    {
      VertexId *m_offsets;
      VertexId *m_active;
      typename Program::VertexType &m_vertex_list;
      typename Program::EdgeType &m_edge_list;
      char *m_predicates;

      __host__ __device__
      PredicatedEdgeCountIterator(VertexId *offsets, VertexId *active, char * predicates, typename Program::VertexType &vertex_list, typename Program::EdgeType &edge_list) :
          m_offsets(offsets), m_active(active), m_predicates(predicates), m_vertex_list(vertex_list), m_edge_list(edge_list)
      {
      }
      ;

      __device__
      VertexId operator[](VertexId i) const
          {
        VertexId active = m_active[i];
        typename Program::expand_vertex expand_vertex_functor;
        bool changed = expand_vertex_functor(active, m_predicates[active], m_vertex_list, m_edge_list);
        return changed ? m_offsets[active + 1] - m_offsets[active] : 0;
      }

      __device__
      PredicatedEdgeCountIterator operator +(VertexId i) const
          {
        return PredicatedEdgeCountIterator(m_offsets, m_active + i, m_predicates, m_vertex_list, m_edge_list);
      }
    };

    struct ActivateGatherIterator: public std::iterator<std::input_iterator_tag, VertexId>
    {
      VertexId *m_offsets;
      VertexId *m_active;

      __host__ __device__
      ActivateGatherIterator(VertexId* offsets, VertexId* active)
      :
          m_offsets(offsets)
              , m_active(active)
      {
      }
      ;

      __device__
      VertexId operator [](VertexId i)
      {
        return m_offsets[m_active[i]];
      }

      __device__
      ActivateGatherIterator operator +(VertexId i) const
          {
        return ActivateGatherIterator(m_offsets, m_active + i);
      }
    };

    struct ActivateOutputIterator
    {
      int* m_flags;

      __host__ __device__
      ActivateOutputIterator(int* flags) :
          m_flags(flags)
      {
      }

      __device__
      ActivateOutputIterator& operator[](VertexId i)
      {
        return *this;
      }

      __device__
      void operator =(VertexId dst)
      {
        m_flags[dst] = 1;
      }

      __device__
      ActivateOutputIterator operator +(VertexId i)
      {
        return ActivateOutputIterator(m_flags);
      }
    };

    struct ReduceOutputIterator: public std::iterator<std::input_iterator_tag, VertexId>
    {
      GatherType *m_gather;
      VertexId *m_active;

      __host__ __device__
      ReduceOutputIterator(GatherType *gatherTmp, VertexId *active) :
          m_gather(gatherTmp), m_active(active)
      {
      }
      ;

      __device__
      GatherType& operator[](VertexId i) const
          {
        VertexId active = m_active[i];
        return m_gather[active];
      }

      __device__
      ReduceOutputIterator operator +(VertexId i) const
          {
        return ReduceOutputIterator(m_gather, m_active + i);
      }

      __device__
      ReduceOutputIterator& operator +=(const VertexId i)
      {
        m_active += i;
        return *this;
      }
    };

    void scatter_mgpu(int frontier_selector,
        int* d_edge_frontier_size,
        int num_active,
        typename Program::SizeT* offsets,
        typename Program::VertexId* active_vertices,
        typename Program::VertexId* edge_count_scan,
        typename Program::VertexId* indices,
        typename Program::VertexId* edge_frontier,
        typename Program::VertexType& vertex_list,
        typename Program::EdgeType& edge_list,
        typename Program::VertexId* d_edgeCSC_indices,
        typename Program::VertexId* misc_values)
    {

      const int NT = 128;
      const int VT = 7;
      typedef mgpu::LaunchBoxVT<NT, VT> Tuning;
      int2 launch = Tuning::GetLaunchParams(*m_mgpuContext);
      int move_count = edge_frontier_size;

      int NV = launch.x * launch.y;
      int numBlocks = MGPU_DIV_UP(move_count + num_active, NV);

      MGPU_MEM(int)partitionsDevice = mgpu::MergePathPartitions<mgpu::MgpuBoundsUpper>(
          mgpu::counting_iterator<int>(0), move_count, edge_count_scan,
          num_active, NV, 0, mgpu::less<int>(), *m_mgpuContext);

      vertex_centric::mgpukernel::kernel_scatter_mgpu<Tuning, NT, VT, Program>
      <<<numBlocks, launch.x, 0, m_mgpuContext->Stream()>>>(frontier_selector,
          move_count,
          num_active,
          d_edge_frontier_size,
          offsets,
          active_vertices,
          edge_count_scan,
          indices,
          partitionsDevice->get(),
          edge_frontier,
          vertex_list,
          edge_list,
          d_edgeCSC_indices,
          misc_values);

      MGPU_SYNC_CHECK("KernelIntervalMove");
    }

    template<typename PredIt, typename OutputIt>
    void copy_if_mgpu(int num,
        PredIt pred,
        OutputIt output,
        int *d_total,
        mgpu::ContextPtr mgpuContext)
    {

      MGPU_MEM(int)d_map = mgpuContext->Malloc<int>(num);

      mgpu::Scan<mgpu::MgpuScanTypeExc>(pred
          , num
          , 0
          , mgpu::plus<int>()
          , d_total
          , (int *)NULL
          , d_map->get()
          , *mgpuContext);

      int threads = 256;
      int blocks = min((num + threads - 1) / threads, 256);

      mgpu::counting_iterator<int> input(0);

      vertex_centric::mgpukernel::kernel_copy_if<<<blocks, threads>>>(input, num,
          pred,
          d_map->get(),
          output);
    }

    void expand_mgpu(typename CsrProblem::GraphSlice *graph_slice, int &selector, const int frontier_selector, const int directed)
    {
      int zero = 0;
      //counts = m_applyRet ? outEdgeCount[ m_active ] : 0
      //first scan the numbers of edges from the active list

//      int* test_vid2 = new int[100];
//      cudaMemcpy(test_vid2, graph_slice->frontier_queues.d_keys[selector ^ 1], 100 * sizeof(int), cudaMemcpyDeviceToHost);
//      printf("frontier before scatter mgpu: ");
//      for (int i = 0; i < 100; ++i)
//      {
//        printf("%d, ", test_vid2[i]);
//      }
//      printf("\n");
//      delete[] test_vid2;
//
//      char*test_vid3 = new char[graph_slice->nodes];
//      cudaMemcpy(test_vid3, graph_slice->d_changed, graph_slice->nodes * sizeof(char), cudaMemcpyDeviceToHost);
//      printf("changed before scatter mgpu: ");
//      for (int i = 0; i < graph_slice->nodes; ++i)
//      {
//        printf("%d, ", test_vid3[i]);
//      }
//      printf("\n");
//      delete[] test_vid3;

//      double startscatter = 0.0, startactive = 0.0, endscatter = 0.0, endactive = 0.0;
//      startscatter = omp_get_wtime();

      //Gathers the dst vertex ids from m_dsts and writes a true for each
      //dst vertex into m_activeFlags

      if (Program::allow_duplicates)
      {

        if(directed == 0)
        {
          //          printf("Expand_mgpu:Dup:All\n");
          PredicatedEdgeCountIterator ecIterator(graph_slice->d_row_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1], graph_slice->d_changed, graph_slice->vertex_list, graph_slice->edge_list);
          mgpu::Scan<mgpu::MgpuScanTypeExc, PredicatedEdgeCountIterator, VertexId, mgpu::plus<VertexId>, VertexId*>(ecIterator
              , frontier_size
              , 0
              , mgpu::plus<VertexId>()
              , &d_edge_frontier_size[frontier_selector]
              , &edge_frontier_size
              , graph_slice->d_edgeCountScan
              , *m_mgpuContext);
          //      cudaDeviceSynchronize();      //terminate scan kernel before read out m_hostMappedValue

          //      if (util::B40CPerror(cudaMemcpy(&edge_frontier_size, &d_edge_frontier_size[frontier_selector], sizeof(SizeT), cudaMemcpyDeviceToHost),
          //          "CsrProblem cudaMemcpy d_edge_frontier_size failed", __FILE__,
          //          __LINE__))
          //        exit(1);
          //
          //      printf("m_nActive = %d\n", frontier_size);
          //      printf("nActiveEdges = %d\n", edge_frontier_size);
          //          if (edge_frontier_size >= graph_slice->frontier_elements[selector])
          //          {
          //            printf("queue size: %d, Frontier queue overflow (%d).  Please increase queue-sizing factor.\n", edge_frontier_size, graph_slice->frontier_elements[selector]);
          //            exit(1);
          //          }
          //        SYNC_CHECK();

          scatter_mgpu(frontier_selector,
              d_edge_frontier_size,
              frontier_size,
              graph_slice->d_row_offsets,
              graph_slice->frontier_queues.d_keys[selector ^ 1],
              graph_slice->d_edgeCountScan,
              graph_slice->d_column_indices,
              graph_slice->frontier_queues.d_keys[selector],
              graph_slice->vertex_list,
              graph_slice->edge_list,
              NULL,
              graph_slice->frontier_queues.d_values[0]);

          int edge_frontier_size1 = edge_frontier_size;

          PredicatedEdgeCountIterator ecIterator2(graph_slice->d_column_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1], graph_slice->d_changed, graph_slice->vertex_list, graph_slice->edge_list);
          mgpu::Scan<mgpu::MgpuScanTypeExc, PredicatedEdgeCountIterator, VertexId, mgpu::plus<VertexId>, VertexId*>(ecIterator2
              , frontier_size
              , 0
              , mgpu::plus<VertexId>()
              , &d_edge_frontier_size[frontier_selector]
              , &edge_frontier_size
              , graph_slice->d_edgeCountScan
              , *m_mgpuContext);

          //      cudaDeviceSynchronize();      //terminate scan kernel before read out m_hostMappedValue

          //      if (util::B40CPerror(cudaMemcpy(&edge_frontier_size, &d_edge_frontier_size[frontier_selector], sizeof(SizeT), cudaMemcpyDeviceToHost),
          //          "CsrProblem cudaMemcpy d_edge_frontier_size failed", __FILE__,
          //          __LINE__))
          //        exit(1);
          //
          //      printf("m_nActive = %d\n", frontier_size);
          //          printf("edge_frontier_size1 = %d\n", edge_frontier_size1);
          //          printf("edge_frontier_size2 = %d\n", edge_frontier_size);
          if (edge_frontier_size1 + edge_frontier_size >= graph_slice->frontier_elements[selector])
          {
            printf("queue size: %d, Frontier queue overflow (%d).  Please increase queue-sizing factor.\n", edge_frontier_size1 + edge_frontier_size, graph_slice->frontier_elements[selector]);
            exit(1);
          }
          //        SYNC_CHECK();
          scatter_mgpu(frontier_selector,
              d_edge_frontier_size,
              frontier_size,
              graph_slice->d_column_offsets,
              graph_slice->frontier_queues.d_keys[selector ^ 1],
              graph_slice->d_edgeCountScan,
              graph_slice->d_row_indices,
              graph_slice->frontier_queues.d_keys[selector] + edge_frontier_size1,
              graph_slice->vertex_list,
              graph_slice->edge_list,
              graph_slice->d_edgeCSC_indices,
              graph_slice->frontier_queues.d_values[0] + edge_frontier_size1);

          //          cudaMemcpy(
          //              graph_slice->frontier_queues.d_keys[selector]
          //              + edge_frontier_size,
          //              graph_slice->frontier_queues.d_keys[2],
          //              edge_frontier_size2 * sizeof(VertexId),
          //              cudaMemcpyDeviceToDevice);
          //
          //          cudaMemcpy(
          //              graph_slice->frontier_queues.d_values[0]
          //              + edge_frontier_size,
          //              graph_slice->frontier_queues.d_values[1],
          //              edge_frontier_size2 * sizeof(VertexId),
          //              cudaMemcpyDeviceToDevice);

          edge_frontier_size += edge_frontier_size1;
          //          printf("edge_frontier_final = %d\n", edge_frontier_size);
          cudaMemcpy(
              &d_edge_frontier_size[frontier_selector],
              &edge_frontier_size,
              sizeof(int),
              cudaMemcpyHostToDevice);

          //          VertexId* test_vid = new VertexId[edge_frontier_size];
          //          cudaMemcpy(test_vid, graph_slice->frontier_queues.d_keys[selector], edge_frontier_size * sizeof(VertexId), cudaMemcpyDeviceToHost);
          //          printf("Frontier after expansion: ");
          //          for (int i = 0; i < edge_frontier_size; ++i)
          //          {
          //            printf("%d, ", test_vid[i]);
          //          }
          //          printf("\n");
          //          delete[] test_vid;

        }
        else
        {
          if(Program::expandOverEdges() == EXPAND_OUT_EDGES)
          {
            PredicatedEdgeCountIterator ecIterator(graph_slice->d_row_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1], graph_slice->d_changed, graph_slice->vertex_list, graph_slice->edge_list);
            mgpu::Scan<mgpu::MgpuScanTypeExc, PredicatedEdgeCountIterator, VertexId, mgpu::plus<VertexId>, VertexId*>(ecIterator
                , frontier_size
                , 0
                , mgpu::plus<VertexId>()
                , &d_edge_frontier_size[frontier_selector]
                , &edge_frontier_size
                , graph_slice->d_edgeCountScan
                , *m_mgpuContext);
            //      cudaDeviceSynchronize();      //terminate scan kernel before read out m_hostMappedValue

            //      if (util::B40CPerror(cudaMemcpy(&edge_frontier_size, &d_edge_frontier_size[frontier_selector], sizeof(SizeT), cudaMemcpyDeviceToHost),
            //          "CsrProblem cudaMemcpy d_edge_frontier_size failed", __FILE__,
            //          __LINE__))
            //        exit(1);
            //
            //      printf("m_nActive = %d\n", frontier_size);
            //      printf("nActiveEdges = %d\n", edge_frontier_size);
            if (edge_frontier_size >= graph_slice->frontier_elements[selector])
            {
              printf("queue size: %d, Frontier queue overflow (%d).  Please increase queue-sizing factor.\n", edge_frontier_size, graph_slice->frontier_elements[selector]);
              exit(1);
            }
//        SYNC_CHECK();

            scatter_mgpu(frontier_selector,
                d_edge_frontier_size,
                frontier_size,
                graph_slice->d_row_offsets,
                graph_slice->frontier_queues.d_keys[selector ^ 1],
                graph_slice->d_edgeCountScan,
                graph_slice->d_column_indices,
                graph_slice->frontier_queues.d_keys[selector],
                graph_slice->vertex_list,
                graph_slice->edge_list,
                NULL,
                graph_slice->frontier_queues.d_values[0]);
          }
          else if(Program::expandOverEdges() == EXPAND_IN_EDGES)
          {
            PredicatedEdgeCountIterator ecIterator(graph_slice->d_column_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1], graph_slice->d_changed, graph_slice->vertex_list, graph_slice->edge_list);
            mgpu::Scan<mgpu::MgpuScanTypeExc, PredicatedEdgeCountIterator, VertexId, mgpu::plus<VertexId>, VertexId*>(ecIterator
                , frontier_size
                , 0
                , mgpu::plus<VertexId>()
                , &d_edge_frontier_size[frontier_selector]
                , &edge_frontier_size
                , graph_slice->d_edgeCountScan
                , *m_mgpuContext);
            //      cudaDeviceSynchronize();      //terminate scan kernel before read out m_hostMappedValue

            //      if (util::B40CPerror(cudaMemcpy(&edge_frontier_size, &d_edge_frontier_size[frontier_selector], sizeof(SizeT), cudaMemcpyDeviceToHost),
            //          "CsrProblem cudaMemcpy d_edge_frontier_size failed", __FILE__,
            //          __LINE__))
            //        exit(1);
            //
            //      printf("m_nActive = %d\n", frontier_size);
            //      printf("nActiveEdges = %d\n", edge_frontier_size);
            if (edge_frontier_size >= graph_slice->frontier_elements[selector])
            {
              printf("queue size: %d, Frontier queue overflow (%d).  Please increase queue-sizing factor.\n", edge_frontier_size, graph_slice->frontier_elements[selector]);
              exit(1);
            }
            //        SYNC_CHECK();

            scatter_mgpu(frontier_selector,
                d_edge_frontier_size,
                frontier_size,
                graph_slice->d_column_offsets,
                graph_slice->frontier_queues.d_keys[selector ^ 1],
                graph_slice->d_edgeCountScan,
                graph_slice->d_row_indices,
                graph_slice->frontier_queues.d_keys[selector],
                graph_slice->vertex_list,
                graph_slice->edge_list,
                graph_slice->d_edgeCSC_indices,
                graph_slice->frontier_queues.d_values[0]);

          }
          else if(Program::expandOverEdges() == EXPAND_ALL_EDGES)
          {
//          printf("Expand_mgpu:Dup:All\n");
            PredicatedEdgeCountIterator ecIterator(graph_slice->d_row_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1], graph_slice->d_changed, graph_slice->vertex_list, graph_slice->edge_list);
            mgpu::Scan<mgpu::MgpuScanTypeExc, PredicatedEdgeCountIterator, VertexId, mgpu::plus<VertexId>, VertexId*>(ecIterator
                , frontier_size
                , 0
                , mgpu::plus<VertexId>()
                , &d_edge_frontier_size[frontier_selector]
                , &edge_frontier_size
                , graph_slice->d_edgeCountScan
                , *m_mgpuContext);
            //      cudaDeviceSynchronize();      //terminate scan kernel before read out m_hostMappedValue

            //      if (util::B40CPerror(cudaMemcpy(&edge_frontier_size, &d_edge_frontier_size[frontier_selector], sizeof(SizeT), cudaMemcpyDeviceToHost),
            //          "CsrProblem cudaMemcpy d_edge_frontier_size failed", __FILE__,
            //          __LINE__))
            //        exit(1);
            //
            //      printf("m_nActive = %d\n", frontier_size);
            //      printf("nActiveEdges = %d\n", edge_frontier_size);
//          if (edge_frontier_size >= graph_slice->frontier_elements[selector])
//          {
//            printf("queue size: %d, Frontier queue overflow (%d).  Please increase queue-sizing factor.\n", edge_frontier_size, graph_slice->frontier_elements[selector]);
//            exit(1);
//          }
            //        SYNC_CHECK();

            scatter_mgpu(frontier_selector,
                d_edge_frontier_size,
                frontier_size,
                graph_slice->d_row_offsets,
                graph_slice->frontier_queues.d_keys[selector ^ 1],
                graph_slice->d_edgeCountScan,
                graph_slice->d_column_indices,
                graph_slice->frontier_queues.d_keys[selector],
                graph_slice->vertex_list,
                graph_slice->edge_list,
                NULL,
                graph_slice->frontier_queues.d_values[0]);

            int edge_frontier_size1 = edge_frontier_size;

            PredicatedEdgeCountIterator ecIterator2(graph_slice->d_column_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1], graph_slice->d_changed, graph_slice->vertex_list, graph_slice->edge_list);
            mgpu::Scan<mgpu::MgpuScanTypeExc, PredicatedEdgeCountIterator, VertexId, mgpu::plus<VertexId>, VertexId*>(ecIterator2
                , frontier_size
                , 0
                , mgpu::plus<VertexId>()
                , &d_edge_frontier_size[frontier_selector]
                , &edge_frontier_size
                , graph_slice->d_edgeCountScan
                , *m_mgpuContext);

            //      cudaDeviceSynchronize();      //terminate scan kernel before read out m_hostMappedValue

            //      if (util::B40CPerror(cudaMemcpy(&edge_frontier_size, &d_edge_frontier_size[frontier_selector], sizeof(SizeT), cudaMemcpyDeviceToHost),
            //          "CsrProblem cudaMemcpy d_edge_frontier_size failed", __FILE__,
            //          __LINE__))
            //        exit(1);
            //
            //      printf("m_nActive = %d\n", frontier_size);
//          printf("edge_frontier_size1 = %d\n", edge_frontier_size1);
//          printf("edge_frontier_size2 = %d\n", edge_frontier_size);
            if (edge_frontier_size1 + edge_frontier_size >= graph_slice->frontier_elements[selector])
            {
              printf("queue size: %d, Frontier queue overflow (%d).  Please increase queue-sizing factor.\n", edge_frontier_size1 + edge_frontier_size, graph_slice->frontier_elements[selector]);
              exit(1);
            }
            //        SYNC_CHECK();
            scatter_mgpu(frontier_selector,
                d_edge_frontier_size,
                frontier_size,
                graph_slice->d_column_offsets,
                graph_slice->frontier_queues.d_keys[selector ^ 1],
                graph_slice->d_edgeCountScan,
                graph_slice->d_row_indices,
                graph_slice->frontier_queues.d_keys[selector] + edge_frontier_size1,
                graph_slice->vertex_list,
                graph_slice->edge_list,
                graph_slice->d_edgeCSC_indices,
                graph_slice->frontier_queues.d_values[0] + edge_frontier_size1);

//          cudaMemcpy(
//              graph_slice->frontier_queues.d_keys[selector]
//              + edge_frontier_size,
//              graph_slice->frontier_queues.d_keys[2],
//              edge_frontier_size2 * sizeof(VertexId),
//              cudaMemcpyDeviceToDevice);
//
//          cudaMemcpy(
//              graph_slice->frontier_queues.d_values[0]
//              + edge_frontier_size,
//              graph_slice->frontier_queues.d_values[1],
//              edge_frontier_size2 * sizeof(VertexId),
//              cudaMemcpyDeviceToDevice);

            edge_frontier_size += edge_frontier_size1;
//          printf("edge_frontier_final = %d\n", edge_frontier_size);
            cudaMemcpy(
                &d_edge_frontier_size[frontier_selector],
                &edge_frontier_size,
                sizeof(int),
                cudaMemcpyHostToDevice);

//          VertexId* test_vid = new VertexId[edge_frontier_size];
//          cudaMemcpy(test_vid, graph_slice->frontier_queues.d_keys[selector], edge_frontier_size * sizeof(VertexId), cudaMemcpyDeviceToHost);
//          printf("Frontier after expansion: ");
//          for (int i = 0; i < edge_frontier_size; ++i)
//          {
//            printf("%d, ", test_vid[i]);
//          }
//          printf("\n");
//          delete[] test_vid;

          }
          else
          {
            cout << "Invalid expandOverEdges value!" << endl;
            exit(1);
          }
        }

      }
      else
      {
        if(directed == 0)
        {
//          int* test_vid = new int[graph_slice->nodes];
//          cudaMemcpy(test_vid, graph_slice->d_changed, graph_slice->nodes * sizeof(char), cudaMemcpyDeviceToHost);
//          printf("d_changed before scatter out mgpu: ");
//          for (int i = 0; i < graph_slice->nodes; ++i)
//          {
//            printf("%d, ", test_vid[i]);
//          }
//          printf("\n");
//          delete[] test_vid;

//          int* test_vid = new int[graph_slice->nodes];
//          cudaMemcpy(test_vid, graph_slice->d_active_flags, graph_slice->nodes * sizeof(int), cudaMemcpyDeviceToHost);
//          printf("flag before scatter out mgpu: ");
//          for (int i = 0; i < graph_slice->nodes; ++i)
//          {
//            printf("%d, ", test_vid[i]);
//          }
//          printf("\n");
//          delete[] test_vid;

          PredicatedEdgeCountIterator ecIterator(graph_slice->d_row_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1], graph_slice->d_changed, graph_slice->vertex_list, graph_slice->edge_list);
          mgpu::Scan<mgpu::MgpuScanTypeExc, PredicatedEdgeCountIterator, VertexId, mgpu::plus<VertexId>, VertexId*>(ecIterator
              , frontier_size
              , 0
              , mgpu::plus<VertexId>()
              , &d_edge_frontier_size[frontier_selector]
              , &edge_frontier_size
              , graph_slice->d_edgeCountScan
              , *m_mgpuContext);

//          printf("edge_frontier_size1=%d\n", edge_frontier_size);

          IntervalGather(edge_frontier_size,
              ActivateGatherIterator(graph_slice->d_row_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1]),
              graph_slice->d_edgeCountScan,
              frontier_size,
              graph_slice->d_column_indices,
              ActivateOutputIterator(graph_slice->d_active_flags),
              *m_mgpuContext);

//          test_vid = new int[graph_slice->nodes];
//          cudaMemcpy(test_vid, graph_slice->d_active_flags, graph_slice->nodes * sizeof(int), cudaMemcpyDeviceToHost);
//          printf("flag after scatter out mgpu: ");
//          for (int i = 0; i < graph_slice->nodes; ++i)
//          {
//            printf("%d, ", test_vid[i]);
//          }
//          printf("\n");
//          delete[] test_vid;

          PredicatedEdgeCountIterator ecIterator2(graph_slice->d_column_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1], graph_slice->d_changed, graph_slice->vertex_list, graph_slice->edge_list);
          mgpu::Scan<mgpu::MgpuScanTypeExc, PredicatedEdgeCountIterator, VertexId, mgpu::plus<VertexId>, VertexId*>(ecIterator2
              , frontier_size
              , 0
              , mgpu::plus<VertexId>()
              , &d_edge_frontier_size[frontier_selector]
              , &edge_frontier_size
              , graph_slice->d_edgeCountScan
              , *m_mgpuContext);

//          printf("edge_frontier_size2=%d\n", edge_frontier_size);

          IntervalGather(edge_frontier_size,
              ActivateGatherIterator(graph_slice->d_column_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1]),
              graph_slice->d_edgeCountScan,
              frontier_size,
              graph_slice->d_row_indices,
              ActivateOutputIterator(graph_slice->d_active_flags),
              *m_mgpuContext);

//          test_vid = new int[graph_slice->nodes];
//          cudaMemcpy(test_vid, graph_slice->d_active_flags, graph_slice->nodes * sizeof(int), cudaMemcpyDeviceToHost);
//          printf("flag after scatter in mgpu: ");
//          for (int i = 0; i < graph_slice->nodes; ++i)
//          {
//            printf("%d, ", test_vid[i]);
//          }
//          printf("\n");
//          delete[] test_vid;

          copy_if_mgpu(graph_slice->nodes,
              graph_slice->d_active_flags,
              graph_slice->frontier_queues.d_keys[selector],
              &d_frontier_size[frontier_selector],
              m_mgpuContext);

          //using memset is faster?
          if (util::B40CPerror(cudaMemcpy(&d_edge_frontier_size[frontier_selector], &zero, sizeof(SizeT), cudaMemcpyHostToDevice),
                  "CsrProblem reset to zero d_edge_frontier_size failed", __FILE__,
                  __LINE__))
          exit(1);

        }
        else
        {
          if(Program::expandOverEdges() == EXPAND_OUT_EDGES)
          {
            PredicatedEdgeCountIterator ecIterator(graph_slice->d_row_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1], graph_slice->d_changed, graph_slice->vertex_list, graph_slice->edge_list);
            mgpu::Scan<mgpu::MgpuScanTypeExc, PredicatedEdgeCountIterator, VertexId, mgpu::plus<VertexId>, VertexId*>(ecIterator
                , frontier_size
                , 0
                , mgpu::plus<VertexId>()
                , &d_edge_frontier_size[frontier_selector]
                , &edge_frontier_size
                , graph_slice->d_edgeCountScan
                , *m_mgpuContext);
            //      cudaDeviceSynchronize();      //terminate scan kernel before read out m_hostMappedValue

            //      if (util::B40CPerror(cudaMemcpy(&edge_frontier_size, &d_edge_frontier_size[frontier_selector], sizeof(SizeT), cudaMemcpyDeviceToHost),
            //          "CsrProblem cudaMemcpy d_edge_frontier_size failed", __FILE__,
            //          __LINE__))
            //        exit(1);
            //
            //      printf("m_nActive = %d\n", frontier_size);
            //      printf("nActiveEdges = %d\n", edge_frontier_size);
            if (edge_frontier_size >= graph_slice->frontier_elements[selector])
            {
              printf("queue size: %d, Frontier queue overflow (%d).  Please increase queue-sizing factor.\n", edge_frontier_size, graph_slice->frontier_elements[selector]);
              exit(1);
            }
//        SYNC_CHECK();
            if (util::B40CPerror(cudaMemcpy(&d_edge_frontier_size[frontier_selector], &zero, sizeof(SizeT), cudaMemcpyHostToDevice),
                    "CsrProblem reset to zero d_edge_frontier_size failed", __FILE__,
                    __LINE__))
            exit(1);

            IntervalGather(edge_frontier_size,
                ActivateGatherIterator(graph_slice->d_row_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1]),
                graph_slice->d_edgeCountScan,
                frontier_size,
                graph_slice->d_column_indices,
                ActivateOutputIterator(graph_slice->d_active_flags),
                *m_mgpuContext);

            copy_if_mgpu(graph_slice->nodes,
                graph_slice->d_active_flags,
                graph_slice->frontier_queues.d_keys[selector],
                &d_frontier_size[frontier_selector],
                m_mgpuContext);
          }
          else if(Program::expandOverEdges() == EXPAND_IN_EDGES)
          {
            PredicatedEdgeCountIterator ecIterator(graph_slice->d_column_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1], graph_slice->d_changed, graph_slice->vertex_list, graph_slice->edge_list);
            mgpu::Scan<mgpu::MgpuScanTypeExc, PredicatedEdgeCountIterator, VertexId, mgpu::plus<VertexId>, VertexId*>(ecIterator
                , frontier_size
                , 0
                , mgpu::plus<VertexId>()
                , &d_edge_frontier_size[frontier_selector]
                , &edge_frontier_size
                , graph_slice->d_edgeCountScan
                , *m_mgpuContext);
            //      cudaDeviceSynchronize();      //terminate scan kernel before read out m_hostMappedValue

            //      if (util::B40CPerror(cudaMemcpy(&edge_frontier_size, &d_edge_frontier_size[frontier_selector], sizeof(SizeT), cudaMemcpyDeviceToHost),
            //          "CsrProblem cudaMemcpy d_edge_frontier_size failed", __FILE__,
            //          __LINE__))
            //        exit(1);
            //
            //      printf("m_nActive = %d\n", frontier_size);
            //      printf("nActiveEdges = %d\n", edge_frontier_size);
            if (edge_frontier_size >= graph_slice->frontier_elements[selector])
            {
              printf("queue size: %d, Frontier queue overflow (%d).  Please increase queue-sizing factor.\n", edge_frontier_size, graph_slice->frontier_elements[selector]);
              exit(1);
            }
            //        SYNC_CHECK();
            if (util::B40CPerror(cudaMemcpy(&d_edge_frontier_size[frontier_selector], &zero, sizeof(SizeT), cudaMemcpyHostToDevice),
                    "CsrProblem reset to zero d_edge_frontier_size failed", __FILE__,
                    __LINE__))
            exit(1);

            IntervalGather(edge_frontier_size,
                ActivateGatherIterator(graph_slice->d_column_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1]),
                graph_slice->d_edgeCountScan,
                frontier_size,
                graph_slice->d_row_indices,
                ActivateOutputIterator(graph_slice->d_active_flags),
                *m_mgpuContext);

            copy_if_mgpu(graph_slice->nodes,
                graph_slice->d_active_flags,
                graph_slice->frontier_queues.d_keys[selector],
                &d_frontier_size[frontier_selector],
                m_mgpuContext);

          }
          else if(Program::expandOverEdges() == EXPAND_ALL_EDGES)
          {

            PredicatedEdgeCountIterator ecIterator(graph_slice->d_row_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1], graph_slice->d_changed, graph_slice->vertex_list, graph_slice->edge_list);
            mgpu::Scan<mgpu::MgpuScanTypeExc, PredicatedEdgeCountIterator, VertexId, mgpu::plus<VertexId>, VertexId*>(ecIterator
                , frontier_size
                , 0
                , mgpu::plus<VertexId>()
                , &d_edge_frontier_size[frontier_selector]
                , &edge_frontier_size
                , graph_slice->d_edgeCountScan
                , *m_mgpuContext);

            IntervalGather(edge_frontier_size,
                ActivateGatherIterator(graph_slice->d_row_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1]),
                graph_slice->d_edgeCountScan,
                frontier_size,
                graph_slice->d_column_indices,
                ActivateOutputIterator(graph_slice->d_active_flags),
                *m_mgpuContext);
//
//          int* test_vid = new int[graph_slice->nodes];
//          cudaMemcpy(test_vid, graph_slice->d_active_flags, graph_slice->nodes * sizeof(int), cudaMemcpyDeviceToHost);
//          printf("flag after scatter out mgpu: ");
//          for (int i = 0; i < graph_slice->nodes; ++i)
//          {
//            printf("%d, ", test_vid[i]);
//          }
//          printf("\n");
//          delete[] test_vid;

            PredicatedEdgeCountIterator ecIterator2(graph_slice->d_column_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1], graph_slice->d_changed, graph_slice->vertex_list, graph_slice->edge_list);
            mgpu::Scan<mgpu::MgpuScanTypeExc, PredicatedEdgeCountIterator, VertexId, mgpu::plus<VertexId>, VertexId*>(ecIterator2
                , frontier_size
                , 0
                , mgpu::plus<VertexId>()
                , &d_edge_frontier_size[frontier_selector]
                , &edge_frontier_size
                , graph_slice->d_edgeCountScan
                , *m_mgpuContext);

            IntervalGather(edge_frontier_size,
                ActivateGatherIterator(graph_slice->d_column_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1]),
                graph_slice->d_edgeCountScan,
                frontier_size,
                graph_slice->d_row_indices,
                ActivateOutputIterator(graph_slice->d_active_flags),
                *m_mgpuContext);

//          test_vid = new int[graph_slice->nodes];
//          cudaMemcpy(test_vid, graph_slice->d_active_flags, graph_slice->nodes * sizeof(int), cudaMemcpyDeviceToHost);
//          printf("flag after scatter in mgpu: ");
//          for (int i = 0; i < graph_slice->nodes; ++i)
//          {
//            printf("%d, ", test_vid[i]);
//          }
//          printf("\n");
//          delete[] test_vid;

            copy_if_mgpu(graph_slice->nodes,
                graph_slice->d_active_flags,
                graph_slice->frontier_queues.d_keys[selector],
                &d_frontier_size[frontier_selector],
                m_mgpuContext);

            if (edge_frontier_size >= graph_slice->frontier_elements[selector])
            {
              printf("queue size: %d, Frontier queue overflow (%d).  Please increase queue-sizing factor.\n", edge_frontier_size, graph_slice->frontier_elements[selector]);
              exit(1);
            }

            //using memset is faster?
            if (util::B40CPerror(cudaMemcpy(&d_edge_frontier_size[frontier_selector], &zero, sizeof(SizeT), cudaMemcpyHostToDevice),
                    "CsrProblem reset to zero d_edge_frontier_size failed", __FILE__,
                    __LINE__))
            exit(1);

          }
          else
          {
            cout << "Invalid expandOverEdges value!" << endl;
            exit(1);
          }
          SYNC_CHECK();
        }
        CHECK(cudaMemset(graph_slice->d_active_flags, 0, sizeof(int) * graph_slice->nodes));
      }
      cudaDeviceSynchronize();
      SYNC_CHECK();
      selector ^= 1;

//      endscatter = omp_get_wtime();

//      int tmp_frontier_size;
//      if (util::B40CPerror(cudaMemcpy(&tmp_frontier_size, &d_frontier_size[frontier_selector], sizeof(SizeT), cudaMemcpyDeviceToHost),
//              "CsrProblem cudaMemcpy tmp_frontier_size failed", __FILE__,
//              __LINE__))
//      exit(1);
//      printf("frontier_size after activation: %d\n", tmp_frontier_size);

//      int* test_vid = new int[tmp_frontier_size];
//      cudaMemcpy(test_vid, graph_slice->frontier_queues.d_keys[selector ^ 1], tmp_frontier_size * sizeof(int), cudaMemcpyDeviceToHost);
//      printf("frontier after scatter mgpu: ");
//      for (int i = 0; i < tmp_frontier_size; ++i)
//      {
//        printf("%d, ", test_vid[i]);
//      }
//      printf("\n");
//      delete[] test_vid;

//      startactive = omp_get_wtime();
//      selector ^= 1;

//      cudaDeviceSynchronize();
//      endactive = omp_get_wtime();
//      selector ^= 1;

//
//      test_vid2 = new int[100];
//      cudaMemcpy(test_vid2, graph_slice->d_edgeCountScan, 100 * sizeof(int), cudaMemcpyDeviceToHost);
//      printf("d_edgeCountScan after scatter: ");
//      for (int i = 0; i < 100; ++i)
//      {
//        printf("%d, ", test_vid2[i]);
//      }
//      printf("\n");
//      delete[] test_vid2;
//
//      printf("Scatter time: %f ms\n", (endscatter - startscatter) * 1000.0);
//      printf("Activate time: %f ms\n", (endactive - startactive) * 1000.0);
    }

    void apply_mgpu(typename CsrProblem::GraphSlice *graph_slice, int selector)
    {
//      float* test_vid = new float[graph_slice->nodes];
//      cudaMemcpy(test_vid, graph_slice->vertex_list.d_dists, graph_slice->nodes * sizeof(float), cudaMemcpyDeviceToHost);
//      printf("d_dists before apply: ");
//      for (int i = 0; i < graph_slice->nodes; ++i)
//      {
//        printf("%f, ", test_vid[i]);
//      }
//      printf("\n");
//      delete[] test_vid;

      const int nThreadsPerBlock = 128;
      SizeT nBlocks = MGPU_DIV_UP(frontier_size,
          nThreadsPerBlock);

      vertex_centric::mgpukernel::apply<Program><<<nBlocks, nThreadsPerBlock>>>(
          iteration[0],
          frontier_size,
          graph_slice->frontier_queues.d_keys[selector ^ 1],
          m_gatherTmp,
          graph_slice->vertex_list,
          graph_slice->edge_list,
          graph_slice->d_changed);
      SYNC_CHECK();

//      test_vid = new float[graph_slice->nodes];
//      cudaMemcpy(test_vid, graph_slice->vertex_list.d_dists, graph_slice->nodes * sizeof(float), cudaMemcpyDeviceToHost);
//      printf("d_dists after apply: ");
//      for (int i = 0; i < graph_slice->nodes; ++i)
//      {
//        printf("%f, ", test_vid[i]);
//      }
//      printf("\n");
//      delete[] test_vid;
//
//      int* test_vid2 = new int[graph_slice->nodes];
//      cudaMemcpy(test_vid2, graph_slice->d_changed, graph_slice->nodes * sizeof(int), cudaMemcpyDeviceToHost);
//      printf("changed after apply: ");
//      for (int i = 0; i < graph_slice->nodes; ++i)
//      {
//        printf("%d, ", test_vid2[i]);
//      }
//      printf("\n");
//      delete[] test_vid2;
    }

    void gather_mgpu(typename CsrProblem::GraphSlice *graph_slice, const int selector, const int directed)
    {
      if (directed == 0)
//      if(0)
      {
        //          printf("Gather all edges --- gather in!\n");
        EdgeCountIterator ecIterator(graph_slice->d_column_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1]);

        mgpu::Scan<mgpu::MgpuScanTypeExc, EdgeCountIterator, int, mgpu::plus<int>, int*>(
            ecIterator,
            frontier_size,
            0,
            mgpu::plus<int>(),
            m_deviceMappedValue,
            (int *) NULL,
            graph_slice->d_edgeCountScan,
            *m_mgpuContext);

        //          int n_active_edges = *m_hostMappedValue;
        int n_active_edges;
        cudaMemcpy(&n_active_edges, m_deviceMappedValue,
            sizeof(int),
            cudaMemcpyDeviceToHost);

        SYNC_CHECK();
        //      printf("n_active_edges = %d\n", n_active_edges);
//        printf("Gather all: int: n_active_edges = %d\n", n_active_edges);

        const int nThreadsPerBlock = 128;
        MGPU_MEM(int)partitions = mgpu::MergePathPartitions<mgpu::MgpuBoundsUpper>
        (mgpu::counting_iterator<int>(0), n_active_edges, graph_slice->d_edgeCountScan, frontier_size,
            nThreadsPerBlock, 0, mgpu::less<int>(), *m_mgpuContext);

        SizeT nBlocks = MGPU_DIV_UP(n_active_edges + frontier_size, nThreadsPerBlock);
        //          dim3 grid = vertex_centric::mgpukernel::calcGridDim(nBlocks);

        vertex_centric::mgpukernel::kernel_gather_mgpu<Program, VertexId,
        nThreadsPerBlock><<<nBlocks, nThreadsPerBlock>>>(
            frontier_size,
            graph_slice->frontier_queues.d_keys[selector ^ 1],
            nBlocks,
            n_active_edges,
            graph_slice->d_edgeCountScan,
            partitions->get(),
            graph_slice->d_column_offsets,
            graph_slice->d_row_indices,
            graph_slice->vertex_list,
            graph_slice->edge_list,
            NULL,
            m_gatherDstsTmp,
            m_gatherMapTmp);

        SYNC_CHECK();

//        VertexId* test_vid3 = new VertexId[n_active_edges];
//        cudaMemcpy(test_vid3, m_gatherDstsTmp,
//            n_active_edges * sizeof(VertexId),
//            cudaMemcpyDeviceToHost);
//        printf("m_gatherDstsTmp after gather-mgpu: ");
//        for (int i = 0; i < n_active_edges; ++i)
//        {
//          printf("%d, ", test_vid3[i]);
//        }
//        printf("\n");
//        delete[] test_vid3;
//
//        GatherType* test_vid2 = new GatherType[n_active_edges];
//        cudaMemcpy(test_vid2, m_gatherMapTmp,
//            n_active_edges * sizeof(GatherType),
//            cudaMemcpyDeviceToHost);
//        printf("m_gatherMapTmp after gather-mgpu: ");
//        for (int i = 0; i < n_active_edges; ++i)
//        {
//          printf("%f, ", test_vid2[i]);
//        }
//        printf("\n");
//        delete[] test_vid2;

        mgpu::ReduceByKey(m_gatherDstsTmp
            , m_gatherMapTmp
            , n_active_edges
            , Program::INIT_VALUE
            , ReduceFunctor()
            , mgpu::equal_to<VertexId>()
            , (VertexId *) NULL
            , ReduceOutputIterator(m_gatherTmp1, graph_slice->frontier_queues.d_keys[selector ^ 1])
            , NULL
            , NULL
            , *m_mgpuContext);

        SYNC_CHECK();

        //          GatherType* test_vid1 = new GatherType[graph_slice->nodes];
        //          cudaMemcpy(test_vid1, m_gatherTmp1,
        //              graph_slice->nodes * sizeof(GatherType),
        //              cudaMemcpyDeviceToHost);
        //          printf("m_gatherTmp after gather-mgpu: ");
        //          for (int i = 0; i < graph_slice->nodes; ++i)
        //          {
        //            printf("%f, ", test_vid1[i]);
        //          }
        //          printf("\n");
        //          delete[] test_vid1;

//        printf("Gather all edges --- gather out!\n");

        EdgeCountIterator ecIterator2(graph_slice->d_row_offsets,
            graph_slice->frontier_queues.d_keys[selector ^ 1]);

        mgpu::Scan<mgpu::MgpuScanTypeExc, EdgeCountIterator, int, mgpu::plus<int>, int*>(
            ecIterator2,
            frontier_size,
            0,
            mgpu::plus<int>(),
            m_deviceMappedValue,
            (int *) NULL,
            graph_slice->d_edgeCountScan,
            *m_mgpuContext);

        SYNC_CHECK();

        //          n_active_edges = *m_hostMappedValue;
        cudaMemcpy(&n_active_edges, m_deviceMappedValue,
            sizeof(int),
            cudaMemcpyDeviceToHost);
//        printf("Gather all: out: n_active_edges = %d\n", n_active_edges);

        partitions = mgpu::MergePathPartitions<mgpu::MgpuBoundsUpper>
        (mgpu::counting_iterator<int>(0), n_active_edges, graph_slice->d_edgeCountScan, frontier_size,
            nThreadsPerBlock, 0, mgpu::less<int>(), *m_mgpuContext);

        nBlocks = MGPU_DIV_UP(n_active_edges + frontier_size,
            nThreadsPerBlock);
        //          grid = vertex_centric::mgpukernel::calcGridDim(nBlocks);

        vertex_centric::mgpukernel::kernel_gather_mgpu<Program, VertexId,
        nThreadsPerBlock><<<nBlocks, nThreadsPerBlock>>>(
            frontier_size,
            graph_slice->frontier_queues.d_keys[selector ^ 1],
            nBlocks,
            n_active_edges,
            graph_slice->d_edgeCountScan,
            partitions->get(),
            graph_slice->d_row_offsets,
            graph_slice->d_column_indices,
            graph_slice->vertex_list,
            graph_slice->edge_list,
            graph_slice->d_edgeCSC_indices,
            m_gatherDstsTmp,
            m_gatherMapTmp);

        SYNC_CHECK();

        //          test_vid3 = new VertexId[n_active_edges];
        //          cudaMemcpy(test_vid3, m_gatherDstsTmp,
        //              n_active_edges * sizeof(VertexId),
        //              cudaMemcpyDeviceToHost);
        //          printf("m_gatherDstsTmp after gather-mgpu: ");
        //          for (int i = 0; i < n_active_edges; ++i)
        //          {
        //            printf("%d, ", test_vid3[i]);
        //          }
        //          printf("\n");
        //          delete[] test_vid3;
        //
        //          test_vid2 = new GatherType[n_active_edges];
        //          cudaMemcpy(test_vid2, m_gatherMapTmp,
        //              n_active_edges * sizeof(GatherType),
        //              cudaMemcpyDeviceToHost);
        //          printf("m_gatherMapTmp after gather-mgpu: ");
        //          for (int i = 0; i < n_active_edges; ++i)
        //          {
        //            printf("%f, ", test_vid2[i]);
        //          }
        //          printf("\n");
        //          delete[] test_vid2;

        mgpu::ReduceByKey(m_gatherDstsTmp
            , m_gatherMapTmp
            , n_active_edges
            , Program::INIT_VALUE
            , ReduceFunctor()
            , mgpu::equal_to<VertexId>()
            , (VertexId *) NULL
            , ReduceOutputIterator(m_gatherTmp2, graph_slice->frontier_queues.d_keys[selector ^ 1])
            , NULL
            , NULL
            , *m_mgpuContext);

        SYNC_CHECK();

        //          test_vid1 = new GatherType[graph_slice->nodes];
        //          cudaMemcpy(test_vid1, m_gatherTmp2,
        //              graph_slice->nodes * sizeof(GatherType),
        //              cudaMemcpyDeviceToHost);
        //          printf("m_gatherTmp after gather-mgpu: ");
        //          for (int i = 0; i < graph_slice->nodes; ++i)
        //          {
        //            printf("%f, ", test_vid1[i]);
        //          }
        //          printf("\n");
        //          delete[] test_vid1;

        thrust::device_ptr<GatherType> m_gatherTmp1_ptr = thrust::device_pointer_cast(m_gatherTmp1);
        thrust::device_ptr<GatherType> m_gatherTmp2_ptr = thrust::device_pointer_cast(m_gatherTmp2);
        thrust::device_ptr<GatherType> m_gatherTmp_ptr = thrust::device_pointer_cast(m_gatherTmp);
        typename Program::gather_sum gather_sum_functor;
        thrust::transform(m_gatherTmp1_ptr,
            m_gatherTmp1_ptr + graph_slice->nodes,
            m_gatherTmp2_ptr,
            m_gatherTmp_ptr,
            gather_sum_functor);

        //          test_vid1 = new GatherType[graph_slice->nodes];
        //          cudaMemcpy(test_vid1, m_gatherTmp,
        //              graph_slice->nodes * sizeof(GatherType),
        //              cudaMemcpyDeviceToHost);
        //          printf("final m_gatherTmp after gather-mgpu: ");
        //          for (int i = 0; i < graph_slice->nodes; ++i)
        //          {
        //            printf("%f, ", test_vid1[i]);
        //          }
        //          printf("\n");
        //          delete[] test_vid1;
//        EdgeCountIterator ecIterator(graph_slice->d_row_offsets,
//            graph_slice->frontier_queues.d_keys[selector ^ 1]);
//
//        mgpu::Scan<mgpu::MgpuScanTypeExc, EdgeCountIterator, int, mgpu::plus<int>, int*>(
//            ecIterator,
//            frontier_size,
//            0,
//            mgpu::plus<int>(),
//            m_deviceMappedValue,
//            (int *) NULL,
//            graph_slice->d_edgeCountScan,
//            *m_mgpuContext);
//
////        int n_active_edges = *m_hostMappedValue;
//        int n_active_edges;
//        cudaMemcpy(&n_active_edges, m_deviceMappedValue,
//            sizeof(int),
//            cudaMemcpyDeviceToHost);
//        //      printf("n_active_edges = %d\n", n_active_edges);
//
//        const int nThreadsPerBlock = 128;
//        MGPU_MEM(int)partitions = mgpu::MergePathPartitions<mgpu::MgpuBoundsUpper>
//        (mgpu::counting_iterator<int>(0), n_active_edges, graph_slice->d_edgeCountScan, frontier_size,
//            nThreadsPerBlock, 0, mgpu::less<int>(), *m_mgpuContext);
//
//        SizeT nBlocks = MGPU_DIV_UP(n_active_edges + frontier_size,
//            nThreadsPerBlock);
//        dim3 grid = vertex_centric::mgpukernel::calcGridDim(nBlocks);
//
//        vertex_centric::mgpukernel::kernel_gather_mgpu<Program, VertexId,
//        nThreadsPerBlock><<<nBlocks, nThreadsPerBlock>>>(
//            frontier_size,
//            graph_slice->frontier_queues.d_keys[selector ^ 1],
//            nBlocks,
//            n_active_edges,
//            graph_slice->d_edgeCountScan,
//            partitions->get(),
//            graph_slice->d_row_offsets,
//            graph_slice->d_column_indices,
//            graph_slice->vertex_list,
//            graph_slice->edge_list,
//            NULL,
//            m_gatherDstsTmp,
//            m_gatherMapTmp);
//
//        mgpu::ReduceByKey(m_gatherDstsTmp
//            , m_gatherMapTmp
//            , n_active_edges
//            , Program::INIT_VALUE
//            , ReduceFunctor()
//            , mgpu::equal_to<VertexId>()
//            , (VertexId *) NULL
//            , ReduceOutputIterator(m_gatherTmp, graph_slice->frontier_queues.d_keys[selector ^ 1])
//            , NULL
//            , NULL
//            , *m_mgpuContext);
      }
      else
      {
        if (Program::gatherOverEdges() == GATHER_IN_EDGES)
        {
          EdgeCountIterator ecIterator(graph_slice->d_column_offsets,
              graph_slice->frontier_queues.d_keys[selector ^ 1]);

          mgpu::Scan<mgpu::MgpuScanTypeExc, EdgeCountIterator, int, mgpu::plus<int>, int*>(
              ecIterator,
              frontier_size,
              0,
              mgpu::plus<int>(),
              m_deviceMappedValue,
              (int *) NULL,
              graph_slice->d_edgeCountScan,
              *m_mgpuContext);

//          int n_active_edges = *m_hostMappedValue;
          int n_active_edges;
          cudaMemcpy(&n_active_edges, m_deviceMappedValue,
              sizeof(int),
              cudaMemcpyDeviceToHost);

//          printf("n_active_edges = %d, frontier_size = %d\n", n_active_edges, frontier_size);

          const int nThreadsPerBlock = 128;
          MGPU_MEM(int)partitions = mgpu::MergePathPartitions<mgpu::MgpuBoundsUpper>
          (mgpu::counting_iterator<int>(0), n_active_edges, graph_slice->d_edgeCountScan, frontier_size,
              nThreadsPerBlock, 0, mgpu::less<int>(), *m_mgpuContext);

          SizeT nBlocks = MGPU_DIV_UP(n_active_edges + frontier_size,
              nThreadsPerBlock);
          dim3 grid = vertex_centric::mgpukernel::calcGridDim(nBlocks);

          vertex_centric::mgpukernel::kernel_gather_mgpu<Program, VertexId,
          nThreadsPerBlock><<<nBlocks, nThreadsPerBlock>>>(
              frontier_size,
              graph_slice->frontier_queues.d_keys[selector ^ 1],
              nBlocks,
              n_active_edges,
              graph_slice->d_edgeCountScan,
              partitions->get(),
              graph_slice->d_column_offsets,
              graph_slice->d_row_indices,
              graph_slice->vertex_list,
              graph_slice->edge_list,
              NULL,
              m_gatherDstsTmp,
              m_gatherMapTmp);

          mgpu::ReduceByKey(m_gatherDstsTmp
              , m_gatherMapTmp
              , n_active_edges
              , Program::INIT_VALUE
              , ReduceFunctor()
              , mgpu::equal_to<VertexId>()
              , (VertexId *) NULL
              , ReduceOutputIterator(m_gatherTmp, graph_slice->frontier_queues.d_keys[selector ^ 1])
              , NULL
              , NULL
              , *m_mgpuContext);

//          GatherType* test_vid2 = new GatherType[graph_slice->nodes];
//          cudaMemcpy(test_vid2, m_gatherTmp,
//              graph_slice->nodes * sizeof(GatherType),
//              cudaMemcpyDeviceToHost);
//          printf("m_gatherTmp after gather-mgpu: ");
//          for (int i = 0; i < graph_slice->nodes; ++i)
//          {
//            printf("%f, ", test_vid2[i]);
//          }
//          printf("\n");
//          delete[] test_vid2;
        }
        else if (Program::gatherOverEdges() == GATHER_OUT_EDGES)
        {
          EdgeCountIterator ecIterator(graph_slice->d_row_offsets,
              graph_slice->frontier_queues.d_keys[selector ^ 1]);

          mgpu::Scan<mgpu::MgpuScanTypeExc, EdgeCountIterator, int, mgpu::plus<int>, int*>(
              ecIterator,
              frontier_size,
              0,
              mgpu::plus<int>(),
              m_deviceMappedValue,
              (int *) NULL,
              graph_slice->d_edgeCountScan,
              *m_mgpuContext);

//          int n_active_edges = *m_hostMappedValue;
          int n_active_edges;
          cudaMemcpy(&n_active_edges, m_deviceMappedValue,
              sizeof(int),
              cudaMemcpyDeviceToHost);
          //      printf("n_active_edges = %d\n", n_active_edges);

          const int nThreadsPerBlock = 128;
          MGPU_MEM(int)partitions = mgpu::MergePathPartitions<mgpu::MgpuBoundsUpper>
          (mgpu::counting_iterator<int>(0), n_active_edges, graph_slice->d_edgeCountScan, frontier_size,
              nThreadsPerBlock, 0, mgpu::less<int>(), *m_mgpuContext);

          SizeT nBlocks = MGPU_DIV_UP(n_active_edges + frontier_size,
              nThreadsPerBlock);
          dim3 grid = vertex_centric::mgpukernel::calcGridDim(nBlocks);

          vertex_centric::mgpukernel::kernel_gather_mgpu<Program, VertexId,
          nThreadsPerBlock><<<nBlocks, nThreadsPerBlock>>>(
              frontier_size,
              graph_slice->frontier_queues.d_keys[selector ^ 1],
              nBlocks,
              n_active_edges,
              graph_slice->d_edgeCountScan,
              partitions->get(),
              graph_slice->d_row_offsets,
              graph_slice->d_column_indices,
              graph_slice->vertex_list,
              graph_slice->edge_list,
              graph_slice->d_edgeCSC_indices,
              m_gatherDstsTmp,
              m_gatherMapTmp);

          mgpu::ReduceByKey(m_gatherDstsTmp
              , m_gatherMapTmp
              , n_active_edges
              , Program::INIT_VALUE
              , ReduceFunctor()
              , mgpu::equal_to<VertexId>()
              , (VertexId *) NULL
              , ReduceOutputIterator(m_gatherTmp, graph_slice->frontier_queues.d_keys[selector ^ 1])
              , NULL
              , NULL
              , *m_mgpuContext);
        }
        else if (Program::gatherOverEdges() == GATHER_ALL_EDGES)
        {
//          printf("Gather all edges --- gather in!\n");
          EdgeCountIterator ecIterator(graph_slice->d_column_offsets, graph_slice->frontier_queues.d_keys[selector ^ 1]);

          mgpu::Scan<mgpu::MgpuScanTypeExc, EdgeCountIterator, int, mgpu::plus<int>, int*>(
              ecIterator,
              frontier_size,
              0,
              mgpu::plus<int>(),
              m_deviceMappedValue,
              (int *) NULL,
              graph_slice->d_edgeCountScan,
              *m_mgpuContext);

//          int n_active_edges = *m_hostMappedValue;
          int n_active_edges;
          cudaMemcpy(&n_active_edges, m_deviceMappedValue,
              sizeof(int),
              cudaMemcpyDeviceToHost);
          //      printf("n_active_edges = %d\n", n_active_edges);
//          printf("Gather all: int: n_active_edges = %d\n", n_active_edges);

          const int nThreadsPerBlock = 128;
          MGPU_MEM(int)partitions = mgpu::MergePathPartitions<mgpu::MgpuBoundsUpper>
          (mgpu::counting_iterator<int>(0), n_active_edges, graph_slice->d_edgeCountScan, frontier_size,
              nThreadsPerBlock, 0, mgpu::less<int>(), *m_mgpuContext);

          SizeT nBlocks = MGPU_DIV_UP(n_active_edges + frontier_size, nThreadsPerBlock);
//          dim3 grid = vertex_centric::mgpukernel::calcGridDim(nBlocks);

          vertex_centric::mgpukernel::kernel_gather_mgpu<Program, VertexId,
          nThreadsPerBlock><<<nBlocks, nThreadsPerBlock>>>(
              frontier_size,
              graph_slice->frontier_queues.d_keys[selector ^ 1],
              nBlocks,
              n_active_edges,
              graph_slice->d_edgeCountScan,
              partitions->get(),
              graph_slice->d_column_offsets,
              graph_slice->d_row_indices,
              graph_slice->vertex_list,
              graph_slice->edge_list,
              NULL,
              m_gatherDstsTmp,
              m_gatherMapTmp);

//          VertexId* test_vid3 = new VertexId[n_active_edges];
//          cudaMemcpy(test_vid3, m_gatherDstsTmp,
//              n_active_edges * sizeof(VertexId),
//              cudaMemcpyDeviceToHost);
//          printf("m_gatherDstsTmp after gather-mgpu: ");
//          for (int i = 0; i < n_active_edges; ++i)
//          {
//            printf("%d, ", test_vid3[i]);
//          }
//          printf("\n");
//          delete[] test_vid3;
//
//          GatherType* test_vid2 = new GatherType[n_active_edges];
//          cudaMemcpy(test_vid2, m_gatherMapTmp,
//              n_active_edges * sizeof(GatherType),
//              cudaMemcpyDeviceToHost);
//          printf("m_gatherMapTmp after gather-mgpu: ");
//          for (int i = 0; i < n_active_edges; ++i)
//          {
//            printf("%f, ", test_vid2[i]);
//          }
//          printf("\n");
//          delete[] test_vid2;

          mgpu::ReduceByKey(m_gatherDstsTmp
              , m_gatherMapTmp
              , n_active_edges
              , Program::INIT_VALUE
              , ReduceFunctor()
              , mgpu::equal_to<VertexId>()
              , (VertexId *) NULL
              , ReduceOutputIterator(m_gatherTmp1, graph_slice->frontier_queues.d_keys[selector ^ 1])
              , NULL
              , NULL
              , *m_mgpuContext);

//          GatherType* test_vid1 = new GatherType[graph_slice->nodes];
//          cudaMemcpy(test_vid1, m_gatherTmp1,
//              graph_slice->nodes * sizeof(GatherType),
//              cudaMemcpyDeviceToHost);
//          printf("m_gatherTmp after gather-mgpu: ");
//          for (int i = 0; i < graph_slice->nodes; ++i)
//          {
//            printf("%f, ", test_vid1[i]);
//          }
//          printf("\n");
//          delete[] test_vid1;

//          printf("Gather all edges --- gather out!\n");

          EdgeCountIterator ecIterator2(graph_slice->d_row_offsets,
              graph_slice->frontier_queues.d_keys[selector ^ 1]);

          mgpu::Scan<mgpu::MgpuScanTypeExc, EdgeCountIterator, int, mgpu::plus<int>, int*>(
              ecIterator2,
              frontier_size,
              0,
              mgpu::plus<int>(),
              m_deviceMappedValue,
              (int *) NULL,
              graph_slice->d_edgeCountScan,
              *m_mgpuContext);

//          n_active_edges = *m_hostMappedValue;
          cudaMemcpy(&n_active_edges, m_deviceMappedValue,
              sizeof(int),
              cudaMemcpyDeviceToHost);
//          printf("Gather all: out: n_active_edges = %d\n", n_active_edges);

          partitions = mgpu::MergePathPartitions<mgpu::MgpuBoundsUpper>
          (mgpu::counting_iterator<int>(0), n_active_edges, graph_slice->d_edgeCountScan, frontier_size,
              nThreadsPerBlock, 0, mgpu::less<int>(), *m_mgpuContext);

          nBlocks = MGPU_DIV_UP(n_active_edges + frontier_size,
              nThreadsPerBlock);
//          grid = vertex_centric::mgpukernel::calcGridDim(nBlocks);

          vertex_centric::mgpukernel::kernel_gather_mgpu<Program, VertexId,
          nThreadsPerBlock><<<nBlocks, nThreadsPerBlock>>>(
              frontier_size,
              graph_slice->frontier_queues.d_keys[selector ^ 1],
              nBlocks,
              n_active_edges,
              graph_slice->d_edgeCountScan,
              partitions->get(),
              graph_slice->d_row_offsets,
              graph_slice->d_column_indices,
              graph_slice->vertex_list,
              graph_slice->edge_list,
              graph_slice->d_edgeCSC_indices,
              m_gatherDstsTmp,
              m_gatherMapTmp);

//          test_vid3 = new VertexId[n_active_edges];
//          cudaMemcpy(test_vid3, m_gatherDstsTmp,
//              n_active_edges * sizeof(VertexId),
//              cudaMemcpyDeviceToHost);
//          printf("m_gatherDstsTmp after gather-mgpu: ");
//          for (int i = 0; i < n_active_edges; ++i)
//          {
//            printf("%d, ", test_vid3[i]);
//          }
//          printf("\n");
//          delete[] test_vid3;
//
//          test_vid2 = new GatherType[n_active_edges];
//          cudaMemcpy(test_vid2, m_gatherMapTmp,
//              n_active_edges * sizeof(GatherType),
//              cudaMemcpyDeviceToHost);
//          printf("m_gatherMapTmp after gather-mgpu: ");
//          for (int i = 0; i < n_active_edges; ++i)
//          {
//            printf("%f, ", test_vid2[i]);
//          }
//          printf("\n");
//          delete[] test_vid2;

          mgpu::ReduceByKey(m_gatherDstsTmp
              , m_gatherMapTmp
              , n_active_edges
              , Program::INIT_VALUE
              , ReduceFunctor()
              , mgpu::equal_to<VertexId>()
              , (VertexId *) NULL
              , ReduceOutputIterator(m_gatherTmp2, graph_slice->frontier_queues.d_keys[selector ^ 1])
              , NULL
              , NULL
              , *m_mgpuContext);

//          test_vid1 = new GatherType[graph_slice->nodes];
//          cudaMemcpy(test_vid1, m_gatherTmp2,
//              graph_slice->nodes * sizeof(GatherType),
//              cudaMemcpyDeviceToHost);
//          printf("m_gatherTmp after gather-mgpu: ");
//          for (int i = 0; i < graph_slice->nodes; ++i)
//          {
//            printf("%f, ", test_vid1[i]);
//          }
//          printf("\n");
//          delete[] test_vid1;

          thrust::device_ptr<GatherType> m_gatherTmp1_ptr = thrust::device_pointer_cast(m_gatherTmp1);
          thrust::device_ptr<GatherType> m_gatherTmp2_ptr = thrust::device_pointer_cast(m_gatherTmp2);
          thrust::device_ptr<GatherType> m_gatherTmp_ptr = thrust::device_pointer_cast(m_gatherTmp);
          typename Program::gather_sum gather_sum_functor;
          thrust::transform(m_gatherTmp1_ptr,
              m_gatherTmp1_ptr + graph_slice->nodes,
              m_gatherTmp2_ptr,
              m_gatherTmp_ptr,
              gather_sum_functor);

//          test_vid1 = new GatherType[graph_slice->nodes];
//          cudaMemcpy(test_vid1, m_gatherTmp,
//              graph_slice->nodes * sizeof(GatherType),
//              cudaMemcpyDeviceToHost);
//          printf("final m_gatherTmp after gather-mgpu: ");
//          for (int i = 0; i < graph_slice->nodes; ++i)
//          {
//            printf("%f, ", test_vid1[i]);
//          }
//          printf("\n");
//          delete[] test_vid1;
        }
        else
        {
          cout << "Error gatherOverEdges type!" << endl;
          exit(1);
        }
      }
      SYNC_CHECK();
    }

    template<typename ExpandPolicy>
    void expand_dynamic(typename CsrProblem::GraphSlice *graph_slice, const int directed, const int selector, const int frontier_selector, const int queue_index, const int expand_grid_size)
    {
//      printf("frontier_size before expand = %d\n", frontier_size);

      if (Program::allow_duplicates)
      {

        if (directed == 0)
        {
          //            printf("Expand_dynamic:Dup:All\n");
          vertex_centric::expand_atomic::Kernel<ExpandPolicy,
          Program><<<expand_grid_size,
          ExpandPolicy::THREADS>>>(iteration[0],
              queue_index,// queue counter index
              queue_index,// steal counter index
              1,// number of GPUs
              frontier_selector,
              0,
              d_frontier_size,
              d_edge_frontier_size,
              d_done,
              graph_slice->frontier_queues.d_keys[selector
              ^ 1],// vertex frontier in
              graph_slice->frontier_queues.d_keys[selector],// edge frontier out
              graph_slice->frontier_queues.d_values[selector],// predecessor out
              graph_slice->vertex_list,//
              graph_slice->edge_list,
              NULL,
              graph_slice->d_changed,
              graph_slice->d_column_indices,
              graph_slice->d_row_offsets,
              this->work_progress,
              graph_slice->frontier_elements[selector ^ 1],// max vertex frontier vertices
              graph_slice->frontier_elements[selector],// max edge frontier vertices
              this->expand_kernel_stats);

          int edge_frontier_size1;
          cudaMemcpy(
              &edge_frontier_size1,
              &d_edge_frontier_size[frontier_selector],
              sizeof(int),
              cudaMemcpyDeviceToHost);

          //            cudaDeviceSynchronize();
          //
          //            printf("frontier size1: %d: ", edge_frontier_size1);
          //            int* frontier = new int[edge_frontier_size1];
          //            cudaMemcpy(frontier,
          //                graph_slice->frontier_queues.d_keys[selector],
          //                sizeof(int) * edge_frontier_size1,
          //                cudaMemcpyDeviceToHost);
          //            for(int i=0; i<edge_frontier_size1; i++)
          //            {
          //              printf("%d, ", frontier[i]);
          //            }
          //            printf("\n");
          //            delete [] frontier;

          vertex_centric::expand_atomic::Kernel<ExpandPolicy,
          Program><<<expand_grid_size,
          ExpandPolicy::THREADS>>>(iteration[0],
              queue_index,// queue counter index
              queue_index,// steal counter index
              1,// number of GPUs
              frontier_selector,
              edge_frontier_size1,
              d_frontier_size,
              d_edge_frontier_size,
              d_done,
              graph_slice->frontier_queues.d_keys[selector
              ^ 1],// vertex frontier in
              graph_slice->frontier_queues.d_keys[selector] + edge_frontier_size1,// edge frontier out
              graph_slice->frontier_queues.d_values[selector] + edge_frontier_size1,// predecessor out
              graph_slice->vertex_list,//
              graph_slice->edge_list,
              graph_slice->d_edgeCSC_indices,
              graph_slice->d_changed,
              graph_slice->d_row_indices,
              graph_slice->d_column_offsets,
              this->work_progress,
              graph_slice->frontier_elements[selector ^ 1],// max vertex frontier vertices
              graph_slice->frontier_elements[selector],// max edge frontier vertices
              this->expand_kernel_stats);
//          vertex_centric::expand_atomic::Kernel<ExpandPolicy,
//          Program><<<expand_grid_size,
//          ExpandPolicy::THREADS>>>(iteration[0],
//              queue_index,              // queue counter index
//              queue_index,// steal counter index
//              1,// number of GPUs
//              frontier_selector,
//              0,
//              d_frontier_size,
//              d_edge_frontier_size,
//              d_done,
//              graph_slice->frontier_queues.d_keys[selector ^ 1],// vertex frontier in
//              graph_slice->frontier_queues.d_keys[selector],// edge frontier out
//              graph_slice->frontier_queues.d_values[selector],// predecessor out
//              graph_slice->vertex_list,//
//              graph_slice->edge_list,
//              NULL,
//              graph_slice->d_changed,
//              graph_slice->d_column_indices,
//              graph_slice->d_row_offsets, this->work_progress,
//              graph_slice->frontier_elements[selector ^ 1],// max vertex frontier vertices
//              graph_slice->frontier_elements[selector],// max edge frontier vertices
//              this->expand_kernel_stats);

        }
        else
        {
          if (Program::expandOverEdges() == EXPAND_OUT_EDGES)
          {

            vertex_centric::expand_atomic::Kernel<ExpandPolicy, Program><<<expand_grid_size,
            ExpandPolicy::THREADS>>>(iteration[0],
                queue_index,              // queue counter index
                queue_index,// steal counter index
                1,// number of GPUs
                frontier_selector,
                0,
                d_frontier_size,
                d_edge_frontier_size,
                d_done,
                graph_slice->frontier_queues.d_keys[selector ^ 1],// vertex frontier in
                graph_slice->frontier_queues.d_keys[selector],// edge frontier out
                graph_slice->frontier_queues.d_values[selector],// predecessor out
                graph_slice->vertex_list,//
                graph_slice->edge_list,
                NULL,
                graph_slice->d_changed,
                graph_slice->d_column_indices,
                graph_slice->d_row_offsets,
                this->work_progress,
                graph_slice->frontier_elements[selector ^ 1],// max vertex frontier vertices
                graph_slice->frontier_elements[selector],// max edge frontier vertices
                this->expand_kernel_stats);
          }
          else if (Program::expandOverEdges()
              == EXPAND_IN_EDGES)
          {
            vertex_centric::expand_atomic::Kernel<ExpandPolicy,
            Program><<<expand_grid_size,
            ExpandPolicy::THREADS>>>(iteration[0],
                queue_index,          // queue counter index
                queue_index,// steal counter index
                1,// number of GPUs
                frontier_selector,
                0,
                d_frontier_size,
                d_edge_frontier_size,
                d_done,
                graph_slice->frontier_queues.d_keys[selector
                ^ 1],// vertex frontier in
                graph_slice->frontier_queues.d_keys[selector],// edge frontier out
                graph_slice->frontier_queues.d_values[selector],// predecessor out
                graph_slice->vertex_list,//
                graph_slice->edge_list,
                graph_slice->d_edgeCSC_indices,
                graph_slice->d_changed,
                graph_slice->d_row_indices,
                graph_slice->d_column_offsets,
                this->work_progress,
                graph_slice->frontier_elements[selector ^ 1],// max vertex frontier vertices
                graph_slice->frontier_elements[selector],// max edge frontier vertices
                this->expand_kernel_stats);
          }
          else if (Program::expandOverEdges() == EXPAND_ALL_EDGES)
          {

//            printf("Expand_dynamic:Dup:All\n");
            vertex_centric::expand_atomic::Kernel<ExpandPolicy,
            Program><<<expand_grid_size,
            ExpandPolicy::THREADS>>>(iteration[0],
                queue_index,// queue counter index
                queue_index,// steal counter index
                1,// number of GPUs
                frontier_selector,
                0,
                d_frontier_size,
                d_edge_frontier_size,
                d_done,
                graph_slice->frontier_queues.d_keys[selector
                ^ 1],// vertex frontier in
                graph_slice->frontier_queues.d_keys[selector],// edge frontier out
                graph_slice->frontier_queues.d_values[selector],// predecessor out
                graph_slice->vertex_list,//
                graph_slice->edge_list,
                NULL,
                graph_slice->d_changed,
                graph_slice->d_column_indices,
                graph_slice->d_row_offsets,
                this->work_progress,
                graph_slice->frontier_elements[selector ^ 1],// max vertex frontier vertices
                graph_slice->frontier_elements[selector],// max edge frontier vertices
                this->expand_kernel_stats);

            int edge_frontier_size1;
            cudaMemcpy(
                &edge_frontier_size1,
                &d_edge_frontier_size[frontier_selector],
                sizeof(int),
                cudaMemcpyDeviceToHost);

//            cudaDeviceSynchronize();
//
//            printf("frontier size1: %d: ", edge_frontier_size1);
//            int* frontier = new int[edge_frontier_size1];
//            cudaMemcpy(frontier,
//                graph_slice->frontier_queues.d_keys[selector],
//                sizeof(int) * edge_frontier_size1,
//                cudaMemcpyDeviceToHost);
//            for(int i=0; i<edge_frontier_size1; i++)
//            {
//              printf("%d, ", frontier[i]);
//            }
//            printf("\n");
//            delete [] frontier;

            vertex_centric::expand_atomic::Kernel<ExpandPolicy,
            Program><<<expand_grid_size,
            ExpandPolicy::THREADS>>>(iteration[0],
                queue_index,// queue counter index
                queue_index,// steal counter index
                1,// number of GPUs
                frontier_selector,
                edge_frontier_size1,
                d_frontier_size,
                d_edge_frontier_size,
                d_done,
                graph_slice->frontier_queues.d_keys[selector
                ^ 1],// vertex frontier in
                graph_slice->frontier_queues.d_keys[selector] + edge_frontier_size1,// edge frontier out
                graph_slice->frontier_queues.d_values[selector] + edge_frontier_size1,// predecessor out
                graph_slice->vertex_list,//
                graph_slice->edge_list,
                graph_slice->d_edgeCSC_indices,
                graph_slice->d_changed,
                graph_slice->d_row_indices,
                graph_slice->d_column_offsets,
                this->work_progress,
                graph_slice->frontier_elements[selector ^ 1],// max vertex frontier vertices
                graph_slice->frontier_elements[selector],// max edge frontier vertices
                this->expand_kernel_stats);
          }
        }
      }
      else
      {
        if (directed == 0)
        {
          //            printf("Expand dynamic: expand all\n");
          vertex_centric::expand_atomic_flag::Kernel<ExpandPolicy, Program><<<expand_grid_size, ExpandPolicy::THREADS>>>(
              iteration[0],
              queue_index,// queue counter index
              queue_index,// steal counter index
              1,// number of GPUs
              frontier_selector,
              0,
              d_frontier_size,
              d_edge_frontier_size,
              d_done,
              graph_slice->frontier_queues.d_keys[selector ^ 1],// vertex frontier in
              graph_slice->frontier_queues.d_keys[selector],// edge frontier out
              graph_slice->frontier_queues.d_values[selector],// predecessor out
              graph_slice->vertex_list,//
              graph_slice->edge_list,
              NULL,
              graph_slice->d_changed,
              graph_slice->d_active_flags,
              graph_slice->d_column_indices,
              graph_slice->d_row_offsets,
              this->work_progress,
              graph_slice->frontier_elements[selector ^ 1],// max vertex frontier vertices
              graph_slice->frontier_elements[selector],// max edge frontier vertices
              this->expand_kernel_stats);

          int edge_frontier_size1;
          cudaMemcpy(
              &edge_frontier_size1,
              &d_edge_frontier_size[frontier_selector],
              sizeof(int),
              cudaMemcpyDeviceToHost);

//          printf("frontier size1: %d: ", edge_frontier_size1);
//          int* frontier = new int[edge_frontier_size1];
//          cudaMemcpy(frontier,
//              graph_slice->frontier_queues.d_keys[selector],
//              sizeof(int) * edge_frontier_size1,
//              cudaMemcpyDeviceToHost);
//          for(int i=0; i<edge_frontier_size1; i++)
//          {
//            printf("%d, ", frontier[i]);
//          }
//          printf("\n");
//          delete [] frontier;

          vertex_centric::expand_atomic_flag::Kernel<ExpandPolicy, Program><<<expand_grid_size, ExpandPolicy::THREADS>>>(
              iteration[0],
              queue_index,// queue counter index
              queue_index,// steal counter index
              1,// number of GPUs
              frontier_selector,
              edge_frontier_size1,
              d_frontier_size,
              d_edge_frontier_size,
              d_done,
              graph_slice->frontier_queues.d_keys[selector ^ 1],// vertex frontier in
              graph_slice->frontier_queues.d_keys[selector] + edge_frontier_size1,// edge frontier out
              graph_slice->frontier_queues.d_values[selector] + edge_frontier_size1,// predecessor out
              graph_slice->vertex_list,//
              graph_slice->edge_list,
              graph_slice->d_edgeCSC_indices,
              graph_slice->d_changed,
              graph_slice->d_active_flags,
              graph_slice->d_row_indices,
              graph_slice->d_column_offsets,
              this->work_progress,
              graph_slice->frontier_elements[selector ^ 1],// max vertex frontier vertices
              graph_slice->frontier_elements[selector],// max edge frontier vertices
              this->expand_kernel_stats);

          int edge_frontier_size2;
          cudaMemcpy(
              &edge_frontier_size2,
              &d_edge_frontier_size[frontier_selector],
              sizeof(int),
              cudaMemcpyDeviceToHost);

//          printf("frontier size2: %d: ", edge_frontier_size2);
//          frontier = new int[edge_frontier_size2];
//          cudaMemcpy(frontier,
//              graph_slice->frontier_queues.d_keys[selector],
//              sizeof(int) * (edge_frontier_size2),
//              cudaMemcpyDeviceToHost);
//          for(int i=0; i<edge_frontier_size2; i++)
//          {
//            printf("%d, ", frontier[i]);
//          }
//          printf("\n");
//          delete [] frontier;

          //reset the active flags
          cudaMemset(graph_slice->d_active_flags, 0, graph_slice->nodes * sizeof(int));

//          vertex_centric::expand_atomic_flag::Kernel<ExpandPolicy, Program><<<expand_grid_size, ExpandPolicy::THREADS>>>(
//              iteration[0],
//              queue_index,              // queue counter index
//              queue_index,// steal counter index
//              1,// number of GPUs
//              frontier_selector,
//              0,
//              d_frontier_size,
//              d_edge_frontier_size,
//              d_done,
//              graph_slice->frontier_queues.d_keys[selector ^ 1],// vertex frontier in
//              graph_slice->frontier_queues.d_keys[selector],// edge frontier out
//              graph_slice->frontier_queues.d_values[selector],// predecessor out
//              graph_slice->vertex_list,//
//              graph_slice->edge_list,
//              NULL,
//              graph_slice->d_changed,
//              graph_slice->d_active_flags,
//              graph_slice->d_column_indices,
//              graph_slice->d_row_offsets,
//              this->work_progress,
//              graph_slice->frontier_elements[selector ^ 1],// max vertex frontier vertices
//              graph_slice->frontier_elements[selector],// max edge frontier vertices
//              this->expand_kernel_stats);

        }
        else
        {
          if (Program::expandOverEdges() == EXPAND_OUT_EDGES)
          {

            //                printf("EXPAND_OUT_EDGES ...\n");
            vertex_centric::expand_atomic_flag::Kernel<ExpandPolicy, Program><<<expand_grid_size, ExpandPolicy::THREADS>>>(
                iteration[0],
                queue_index,// queue counter index
                queue_index,// steal counter index
                1,// number of GPUs
                frontier_selector,
                0,
                d_frontier_size,
                d_edge_frontier_size,
                d_done,
                graph_slice->frontier_queues.d_keys[selector ^ 1],// vertex frontier in
                graph_slice->frontier_queues.d_keys[selector],// edge frontier out
                graph_slice->frontier_queues.d_values[selector],// predecessor out
                graph_slice->vertex_list,//
                graph_slice->edge_list,
                NULL,
                graph_slice->d_changed,
                graph_slice->d_active_flags,
                graph_slice->d_column_indices,
                graph_slice->d_row_offsets,
                this->work_progress,
                graph_slice->frontier_elements[selector ^ 1],// max vertex frontier vertices
                graph_slice->frontier_elements[selector],// max edge frontier vertices
                this->expand_kernel_stats);
          }
          else if(Program::expandOverEdges() == EXPAND_IN_EDGES)
          {
            vertex_centric::expand_atomic_flag::Kernel<ExpandPolicy, Program><<<expand_grid_size, ExpandPolicy::THREADS>>>(
                iteration[0],
                queue_index,              // queue counter index
                queue_index,// steal counter index
                1,// number of GPUs
                frontier_selector,
                0,
                d_frontier_size,
                d_edge_frontier_size,
                d_done,
                graph_slice->frontier_queues.d_keys[selector ^ 1],// vertex frontier in
                graph_slice->frontier_queues.d_keys[selector],// edge frontier out
                graph_slice->frontier_queues.d_values[selector],// predecessor out
                graph_slice->vertex_list,//
                graph_slice->edge_list,
                graph_slice->d_edgeCSC_indices,
                graph_slice->d_changed,
                graph_slice->d_active_flags,
                graph_slice->d_row_indices,
                graph_slice->d_column_offsets,
                this->work_progress,
                graph_slice->frontier_elements[selector ^ 1],// max vertex frontier vertices
                graph_slice->frontier_elements[selector],// max edge frontier vertices
                this->expand_kernel_stats);
          }
          else if(Program::expandOverEdges() == EXPAND_ALL_EDGES)
          {
//            printf("Expand dynamic: expand all\n");
            vertex_centric::expand_atomic_flag::Kernel<ExpandPolicy, Program><<<expand_grid_size, ExpandPolicy::THREADS>>>(
                iteration[0],
                queue_index,// queue counter index
                queue_index,// steal counter index
                1,// number of GPUs
                frontier_selector,
                0,
                d_frontier_size,
                d_edge_frontier_size,
                d_done,
                graph_slice->frontier_queues.d_keys[selector ^ 1],// vertex frontier in
                graph_slice->frontier_queues.d_keys[selector],// edge frontier out
                graph_slice->frontier_queues.d_values[selector],// predecessor out
                graph_slice->vertex_list,//
                graph_slice->edge_list,
                NULL,
                graph_slice->d_changed,
                graph_slice->d_active_flags,
                graph_slice->d_column_indices,
                graph_slice->d_row_offsets,
                this->work_progress,
                graph_slice->frontier_elements[selector ^ 1],// max vertex frontier vertices
                graph_slice->frontier_elements[selector],// max edge frontier vertices
                this->expand_kernel_stats);

            int edge_frontier_size1;
            cudaMemcpy(
                &edge_frontier_size1,
                &d_edge_frontier_size[frontier_selector],
                sizeof(int),
                cudaMemcpyDeviceToHost);

            printf("frontier size1: %d: ", edge_frontier_size1);
            int* frontier = new int[edge_frontier_size1];
            cudaMemcpy(frontier,
                graph_slice->frontier_queues.d_keys[selector],
                sizeof(int) * edge_frontier_size1,
                cudaMemcpyDeviceToHost);
            for(int i=0; i<edge_frontier_size1; i++)
            {
              printf("%d, ", frontier[i]);
            }
            printf("\n");
            delete [] frontier;

            vertex_centric::expand_atomic_flag::Kernel<ExpandPolicy, Program><<<expand_grid_size, ExpandPolicy::THREADS>>>(
                iteration[0],
                queue_index,              // queue counter index
                queue_index,// steal counter index
                1,// number of GPUs
                frontier_selector,
                edge_frontier_size1,
                d_frontier_size,
                d_edge_frontier_size,
                d_done,
                graph_slice->frontier_queues.d_keys[selector ^ 1],// vertex frontier in
                graph_slice->frontier_queues.d_keys[selector] + edge_frontier_size1,// edge frontier out
                graph_slice->frontier_queues.d_values[selector] + edge_frontier_size1,// predecessor out
                graph_slice->vertex_list,//
                graph_slice->edge_list,
                graph_slice->d_edgeCSC_indices,
                graph_slice->d_changed,
                graph_slice->d_active_flags,
                graph_slice->d_row_indices,
                graph_slice->d_column_offsets,
                this->work_progress,
                graph_slice->frontier_elements[selector ^ 1],// max vertex frontier vertices
                graph_slice->frontier_elements[selector],// max edge frontier vertices
                this->expand_kernel_stats);

            int edge_frontier_size2;
            cudaMemcpy(
                &edge_frontier_size2,
                &d_edge_frontier_size[frontier_selector],
                sizeof(int),
                cudaMemcpyDeviceToHost);

            printf("frontier size2: %d: ", edge_frontier_size2);
            frontier = new int[edge_frontier_size2];
            cudaMemcpy(frontier,
                graph_slice->frontier_queues.d_keys[selector],
                sizeof(int) * (edge_frontier_size2),
                cudaMemcpyDeviceToHost);
            for(int i=0; i<edge_frontier_size2; i++)
            {
              printf("%d, ", frontier[i]);
            }
            printf("\n");
            delete [] frontier;
          }
//          thrust::device_ptr<int> active_flags_ptr = thrust::device_pointer_cast(graph_slice->d_active_flags);
//          thrust::device_ptr<VertexId> frontier_queue_ptr = thrust::device_pointer_cast(graph_slice->frontier_queues.d_keys[selector]);
//          thrust::sequence(d_vertex_ids.begin(), d_vertex_ids.end());
//          thrust::device_ptr<VertexId> result_end = thrust::copy_if(d_vertex_ids.begin(), d_vertex_ids.end(),
//              active_flags_ptr, frontier_queue_ptr, thrust::identity<int>());
//          frontier_size = result_end - frontier_queue_ptr;
//          work_progress.SetQueueLength(queue_index + 1, frontier_size);

          //reset the active flags
          cudaMemset(graph_slice->d_active_flags, 0, graph_slice->nodes * sizeof(int));
        }

      }

      if (util::B40CPerror(cudaThreadSynchronize(), "expand_atomic::Kernel failed ", __FILE__, __LINE__))
      exit(1);

    }

    template<typename ExpandPolicy,
    typename ContractPolicy>
    cudaError_t EnactIterativeSearch(CsrProblem &csr_problem,
        typename CsrProblem::SizeT* h_row_offsets,
        int directed, int num_srcs, int* srcs, int iter_num, int threshold)
    {
      typedef typename CsrProblem::SizeT SizeT;
      typedef typename CsrProblem::VertexId VertexId;
      typedef typename CsrProblem::EValue EValue;
      typedef typename CsrProblem::VisitedMask VisitedMask;

// Single-gpu graph slice
      typename CsrProblem::GraphSlice *graph_slice =
      csr_problem.graph_slices[0];

      DEBUG = cfg.getParameter<int>("verbose");
      m_mgpuContext = mgpu::CreateCudaDevice(cfg.getParameter<int>("device"));
      cudaError_t retval = cudaSuccess;

// Determine grid size(s)
      int expand_occupancy = ExpandPolicy::CTA_OCCUPANCY;
      int expand_grid_size = MaxGridSize(expand_occupancy);

//      int gather_occupancy = GatherPolicy::CTA_OCCUPANCY;
//      int gather_grid_size = MaxGridSize(gather_occupancy);

      int contract_occupancy = ContractPolicy::CTA_OCCUPANCY;
      int contract_grid_size = MaxGridSize(contract_occupancy);

      cudaMallocHost(&m_hostMappedValue, sizeof(SizeT), cudaHostAllocMapped);
      cudaHostGetDevicePointer(&m_deviceMappedValue, m_hostMappedValue, 0);
      cudaMalloc((void**) &d_frontier_size, 2 * sizeof(SizeT));
      cudaMalloc((void**) &d_edge_frontier_size, 2 * sizeof(SizeT));

      if (retval = util::B40CPerror(cudaMemset(d_edge_frontier_size, 0, 2 * sizeof(SizeT)),
              "CsrProblem cudaMemset d_edge_frontier_size failed", __FILE__,
              __LINE__))
      return retval;

      int tmp[2] =
      { num_srcs, 0};
      if (retval = util::B40CPerror(
              cudaMemcpy(d_frontier_size,
                  tmp,
                  2 * sizeof(int),
                  cudaMemcpyHostToDevice),
              "CsrProblem cudaMemcpy d_frontier_size failed",
              __FILE__, __LINE__))
      return retval;

      cudaMalloc((void**) &m_gatherMapTmp, (graph_slice->edges + graph_slice->nodes) * sizeof(GatherType));
      cudaMalloc((void**) &m_gatherTmp, graph_slice->nodes * sizeof(GatherType));
      if ( (Program::gatherOverEdges() == GATHER_ALL_EDGES || directed == 0) && Program::gatherOverEdges() != NO_GATHER_EDGES)
      {
        cudaMalloc((void**) &m_gatherTmp1, graph_slice->nodes * sizeof(GatherType));
//        cudaMemset(m_gatherTmp1, 0, graph_slice->nodes * sizeof(GatherType) );
        cudaMalloc((void**) &m_gatherTmp2, graph_slice->nodes * sizeof(GatherType));
      }
      cudaMalloc((void**) &m_gatherDstsTmp, (graph_slice->edges + graph_slice->nodes) * sizeof(VertexId));
      int* edgeCountScan;
      cudaMalloc((void**) &edgeCountScan, graph_slice->nodes * sizeof(SizeT));
      thrust::device_vector<int> d_vertex_ids = thrust::device_vector<int>(graph_slice->nodes);
      thrust::sequence(d_vertex_ids.begin(), d_vertex_ids.end());
      int memset_block_size = 256;
      int memset_grid_size_max = 32 * 1024;              // 32K CTAs
      int memset_grid_size;

      memset_grid_size = B40C_MIN(memset_grid_size_max, (graph_slice->nodes + memset_block_size - 1) / memset_block_size);

//init m_gatherTmp, necessary for CC!!!
      util::MemsetKernel<GatherType><<<memset_grid_size,
      memset_block_size, 0, graph_slice->stream>>>(
          m_gatherTmp, Program::INIT_VALUE,
          graph_slice->nodes);
//
//      if (retval = util::B40CPerror(cudaThreadSynchronize(),
//              "MemsetKernel m_gatherTmp failed", __FILE__, __LINE__))
//      return retval;

      double max_queue_sizing = cfg.getParameter<double>("max_queue_sizing");

// Reset data
      if (retval = csr_problem.Reset(GetFrontierType(),
              max_queue_sizing))
      return retval;

      Program::Initialize(directed, graph_slice->nodes, graph_slice->edges, num_srcs,
          srcs, graph_slice->d_row_offsets, graph_slice->d_column_indices, graph_slice->d_column_offsets, graph_slice->d_row_indices,
          graph_slice->d_edge_values,
          graph_slice->vertex_list, graph_slice->edge_list,
          graph_slice->frontier_queues.d_keys,
          graph_slice->frontier_queues.d_values);

      if (retval = Setup(csr_problem, expand_grid_size,
              contract_grid_size, 0))
      return retval;

//          SizeT queue_length;
      VertexId queue_index = 0;// Work stealing/queue index
      int selector = 0;
      int frontier_selector = 0;
      frontier_size = num_srcs;

      cudaEvent_t start, stop;
      cudaEventCreate(&start);
      cudaEventCreate(&stop);

      double startcontract, endcontract;
      double startgather, endgather;
      double startexpand, endexpand;

      double elapsedcontract = 0.0;
      double elapsedgather = 0.0;
      double elapsedexpand = 0.0;

      cudaEventRecord(start);
      double startTime = omp_get_wtime();

// Forward phase BC iterations
//          while (done[0] < 0 || frontier_size > 0)
      for (int i = 0; i < iter_num && frontier_size > 0; i++)
      {
        if (DEBUG)
        printf("Iteration: %lld, frontier_size: %d\n", (long long) iteration[0], frontier_size);

//        int old_frontier_size = frontier_size; //for contract check

////            if (DEBUG)
////            {
////              printf("queue_length after contraction: %lld\n",
////                  (long long) queue_length);
////
//////              VertexId* test_vid = new VertexId[graph_slice->nodes];
//////              cudaMemcpy(test_vid, graph_slice->frontier_queues.d_keys[selector ^ 1], graph_slice->nodes * sizeof(VertexId), cudaMemcpyDeviceToHost);
//////              printf("Frontier after contraction: ");
//////              for (int i = 0; i < queue_length; ++i)
//////              {
//////                printf("%d, ", test_vid[i]);
//////              }
//////              printf("\n");
//////              delete[] test_vid;
////
//////                EValue *test_vid2 = new EValue[graph_slice->nodes];
//////                cudaMemcpy(test_vid2, graph_slice->vertex_list.d_dists, graph_slice->nodes * sizeof(EValue), cudaMemcpyDeviceToHost);
//////                printf("d_dists after contract: ");
//////                for (int i = 0; i < graph_slice->nodes; ++i)
//////                {
//////                  printf("%d, ", test_vid2[i]);
//////                }
//////                printf("\n");
//////                delete[] test_vid2;
////
//////                test_vid2 = new EValue[graph_slice->nodes];
//////                cudaMemcpy(test_vid2, graph_slice->vertex_list.d_min_dists, graph_slice->nodes * sizeof(EValue), cudaMemcpyDeviceToHost);
//////                printf("d_min_dists after contract: ");
//////                for (int i = 0; i < graph_slice->nodes; ++i)
//////                {
//////                  printf("%d, ", test_vid2[i]);
//////                }
//////                printf("\n");
//////                delete[] test_vid2;
////            }
////
////            // Throttle
////            if (iteration[0] & 1)
////            {
////              if (retval =
////                  util::B40CPerror(
////                      cudaEventRecord(throttle_event),
////                      "EnactorVertexCentric cudaEventRecord throttle_event failed",
////                      __FILE__, __LINE__))
////                break;
////            }
////            else
////            {
////              if (retval =
////                  util::B40CPerror(
////                      cudaEventSynchronize(throttle_event),
////                      "EnactorVertexCentric cudaEventSynchronize throttle_event failed",
////                      __FILE__, __LINE__))
////                break;
////            };
//
//            // Check if done
//            if (done[0] == 0)
//              break;

        if (DEBUG)
        {
          cudaDeviceSynchronize();
          startgather = omp_get_wtime();
        }
        //
        //Gather stage
        //
        if (Program::gatherOverEdges() != NO_GATHER_EDGES)
        gather_mgpu(graph_slice, selector, directed);

        if (DEBUG)
        {
          cudaDeviceSynchronize();
          endgather = omp_get_wtime();
          elapsedgather += endgather - startgather;
          printf("Gather time: %f ms\n", (endgather - startgather) * 1000);
        }

//            if (DEBUG)
//            {
//              if (work_progress.GetQueueLength(queue_index,
//                  queue_length))
//                break;
//              total_queued += queue_length;
//
//              //                  if (DEBUG) printf("queue_length after gather: %lld\n", (long long) queue_length);
//
//              EValue *test_vid2 = new EValue[graph_slice->nodes];
//              cudaMemcpy(test_vid2, graph_slice->vertex_list.d_min_dists, graph_slice->nodes * sizeof(EValue), cudaMemcpyDeviceToHost);
//              printf("d_min_dists after gather: ");
//              for (int i = 0; i < graph_slice->nodes; ++i)
//              {
//                printf("%f, ", test_vid2[i]);
//              }
//              printf("\n");
//              delete[] test_vid2;
//              //
//              //                  test_vid2 = new EValue[graph_slice->nodes];
//              //                  cudaMemcpy(test_vid2, graph_slice->vertex_list.d_min_dists, graph_slice->nodes * sizeof(EValue), cudaMemcpyDeviceToHost);
//              //                  printf("d_gather_results after gather: ");
//              //                  for (int i = 0; i < graph_slice->nodes; ++i)
//              //                  {
//              //                    printf("%f, ", test_vid2[i]);
//              //                  }
//              //                  printf("\n");
//              //                  delete[] test_vid2;
//
//              //                  VertexId* test_vid = new VertexId[graph_slice->nodes];
//              //                  cudaMemcpy(test_vid, graph_slice->d_changed, graph_slice->nodes * sizeof(VertexId), cudaMemcpyDeviceToHost);
//              //                  printf("changed after gather: ");
//              //                  for (int i = 0; i < graph_slice->nodes; ++i)
//              //                  {
//              //                    printf("%d, ", test_vid[i]);
//              //                  }
//              //                  printf("\n");
//              //                  delete[] test_vid;
//            }

        if (Program::applyOverEdges() == APPLY_FRONTIER)
        {
          //
          //apply stage
          //
          apply_mgpu(graph_slice, selector);

//              vertex_centric::gather::apply<GatherPolicy, Program><<<
//              gather_grid_size, GatherPolicy::THREADS>>>(
//                  iteration[0], queue_index, this->work_progress,
//                  graph_slice->frontier_queues.d_keys[selector ^ 1],
//                  graph_slice->vertex_list,
//                  graph_slice->edge_list);

//                  if (DEBUG)
//                  {
//                    int num_changed;
//                    thrust::device_ptr<int> changed_ptr = thrust::device_pointer_cast(graph_slice->vertex_list.d_changed);
//                    num_changed = thrust::reduce(changed_ptr, changed_ptr + graph_slice->nodes);
//                    printf("num_changed=%d\n", num_changed);
//                  }
        }

        if (Program::postApplyOverEdges() == POST_APPLY_FRONTIER)
        {

          //
          //                //reset dists and gather_results
          //                //
          int nthreads = 256;
          int nblocks = MGPU_DIV_UP(frontier_size, nthreads);
          vertex_centric::mgpukernel::reset_gather_result<ExpandPolicy, Program><<<nblocks, nthreads>>>(iteration[0],
              frontier_size,
              graph_slice->frontier_queues.d_keys[selector ^ 1],
              graph_slice->vertex_list,
              graph_slice->edge_list,
              m_gatherTmp,
              graph_slice->d_visited_mask);

          if (DEBUG
              && (retval = util::B40CPerror(
                      cudaThreadSynchronize(),
                      "gather::reset_changed Kernel failed ",
                      __FILE__, __LINE__)))
          break;

          if (DEBUG)
          {
//            EValue *test_vid2 = new EValue[graph_slice->nodes];
//            cudaMemcpy(test_vid2, graph_slice->vertex_list.d_dists, graph_slice->nodes * sizeof(EValue), cudaMemcpyDeviceToHost);
//            printf("d_dists after apply: ");
//            for (int i = 0; i < graph_slice->nodes; ++i)
//            {
//              printf("%f, ", test_vid2[i]);
//            }
//            printf("\n");
//            delete[] test_vid2;
            //
            //                  VertexId *test_vid = new VertexId[graph_slice->nodes];
            //                  cudaMemcpy(test_vid, graph_slice->vertex_list.d_changed, graph_slice->nodes * sizeof(VertexId), cudaMemcpyDeviceToHost);
            //                  printf("changed after apply: ");
            //                  for (int i = 0; i < graph_slice->nodes; ++i)
            //                  {
            //                    printf("%d, ", test_vid[i]);
            //                  }
            //                  printf("\n");
            //                  delete[] test_vid;
          }
        }
        else if (Program::postApplyOverEdges() == POST_APPLY_ALL)
        {
          int nthreads = 256;
          int nblocks = MGPU_DIV_UP(graph_slice->nodes, nthreads);
          vertex_centric::mgpukernel::reset_gather_result<
          ExpandPolicy, Program><<<nblocks,nthreads>>>(iteration[0],
              graph_slice->nodes, graph_slice->vertex_list,
              graph_slice->edge_list,
              m_gatherTmp,
              graph_slice->d_visited_mask);

          if (DEBUG)
          {
            //                EValue *test_vid2 = new EValue[graph_slice->nodes];
            //                cudaMemcpy(test_vid2, graph_slice->vertex_list.d_dists, graph_slice->nodes * sizeof(EValue), cudaMemcpyDeviceToHost);
            //                printf("d_dists after apply: ");
            //                for (int i = 0; i < graph_slice->nodes; ++i)
            //                {
            //                  printf("%f, ", test_vid2[i]);
            //                }
            //                printf("\n");
            //                delete[] test_vid2;
            //
            //                  VertexId *test_vid = new VertexId[graph_slice->nodes];
            //                  cudaMemcpy(test_vid, graph_slice->vertex_list.d_changed, graph_slice->nodes * sizeof(VertexId), cudaMemcpyDeviceToHost);
            //                  printf("changed after apply: ");
            //                  for (int i = 0; i < graph_slice->nodes; ++i)
            //                  {
            //                    printf("%d, ", test_vid[i]);
            //                  }
            //                  printf("\n");
            //                  delete[] test_vid;
          }

        }

//        if (util::B40CPerror(cudaMemset(d_edge_frontier_size, 0, sizeof(SizeT)),
//                "CsrProblem cudaMemset d_edge_frontier_size failed", __FILE__,
//                __LINE__))
//        exit(1);

        if (DEBUG)
        {
          cudaDeviceSynchronize();
          startexpand = omp_get_wtime();
        }

        //
        // Expansion
        //

//        if (frontier_size > graph_slice->nodes / RATIO)
        if (frontier_size > threshold)
        {
          expand_mgpu(graph_slice, selector, frontier_selector, directed);
        }
        else
        {
          //This function call is fine but the contract function call slow things down a lot
          expand_dynamic < ExpandPolicy > (graph_slice, directed, selector, frontier_selector, queue_index, expand_grid_size);
          selector ^= 1;
//          queue_index++;

//          cudaEventQuery(throttle_event);                // give host memory mapped visibility to GPU updates

          //              if (DEBUG) printf("\n%lld", (long long) iteration[0]);

          // Throttle
          if (iteration[0] & 1)
          {
            if (retval =
                util::B40CPerror(cudaEventRecord(throttle_event),
                    "EnactorVertexCentric cudaEventRecord throttle_event failed",
                    __FILE__, __LINE__))
            break;
          }
          else
          {
            if (retval =
                util::B40CPerror(
                    cudaEventSynchronize(throttle_event),
                    "EnactorVertexCentric cudaEventSynchronize throttle_event failed",
                    __FILE__, __LINE__))
            break;
          };

          // Check if done
          if (done[0] == 0)
          break;

        }

        if (DEBUG)
        {

//          if (retval = util::B40CPerror(cudaMemcpy(&edge_frontier_size, &d_edge_frontier_size[frontier_selector], sizeof(SizeT), cudaMemcpyDeviceToHost),
//                  "CsrProblem cudaMemcpy frontier_size failed", __FILE__,
//                  __LINE__))
//          break;
//          VertexId* test_vid = new VertexId[edge_frontier_size];
//          cudaMemcpy(test_vid, graph_slice->frontier_queues.d_keys[selector ^ 1], edge_frontier_size * sizeof(VertexId), cudaMemcpyDeviceToHost);
//          printf("Frontier after expansion: ");
//          for (int i = 0; i < edge_frontier_size; ++i)
//          {
//            printf("%d, ", test_vid[i]);
//          }
//          printf("\n");
//          delete[] test_vid;

          //                test_vid = new VertexId[graph_slice->nodes];
          //                cudaMemcpy(test_vid, graph_slice->vertex_list.d_dists, graph_slice->nodes * sizeof(VertexId), cudaMemcpyDeviceToHost);
          //                printf("d_dists after expansion: ");
          //                for (int i = 0; i < graph_slice->nodes; ++i)
          //                {
          //                  printf("%d, ", test_vid[i]);
          //                }
          //                printf("\n");
          //                delete[] test_vid;

          //                test_vid = new VertexId[queue_length];
          //                cudaMemcpy(test_vid, graph_slice->frontier_queues.d_values[selector ^ 1], queue_length * sizeof(VertexId), cudaMemcpyDeviceToHost);
          //                printf("d_predecesor after expansion: ");
          //                for (int i = 0; i < queue_length; ++i)
          //                {
          //                  printf("%d, ", test_vid[i]);
          //                }
          //                printf("\n");
          //                delete[] test_vid;
        }

        if (DEBUG)
        {
          cudaDeviceSynchronize();
          endexpand = omp_get_wtime();
          elapsedexpand += endexpand - startexpand;
          printf("Expand time: %f ms\n", (endexpand - startexpand) * 1000);
        }

//        if (retval = util::B40CPerror(cudaMemset(d_frontier_size, 0, sizeof(SizeT)),
//                "CsrProblem cudaMemset d_edge_frontier_size failed", __FILE__,
//                __LINE__))
//        break;

//        if (frontier_size <= graph_slice->nodes / RATIO || Program::allow_duplicates)
        if (frontier_size <= threshold || Program::allow_duplicates)
        {
          if (DEBUG)
          {
            startcontract = omp_get_wtime();
          }
          //
          // Contraction
          //

          //Using this function call is much slower, probably due to function call overhead? It is wierd
          //            contract_dynamic<ContractPolicy>(graph_slice, directed, selector, expand_grid_size);

          vertex_centric::contract_atomic::Kernel<ContractPolicy,
          Program><<<contract_grid_size,
          ContractPolicy::THREADS>>>(0,
              iteration[0],
              queue_index,// queue counter index
              queue_index,// steal counter index
              1,// number of GPUs
              frontier_selector,
              d_frontier_size,
              d_edge_frontier_size,
              d_done,
              graph_slice->frontier_queues.d_keys[selector ^ 1],// filtered edge frontier in
              graph_slice->frontier_queues.d_keys[selector],// vertex frontier out
              graph_slice->frontier_queues.d_values[0],// predecessor in
              m_gatherTmp,
              graph_slice->vertex_list,
              graph_slice->edge_list,
              graph_slice->d_changed,
              graph_slice->d_visited_mask,
              this->work_progress,
              graph_slice->frontier_elements[selector ^ 1],// max filtered edge frontier vertices
              graph_slice->frontier_elements[selector],// max vertex frontier vertices
              this->contract_kernel_stats);

          if (DEBUG)
          {
            cudaDeviceSynchronize();
            endcontract = omp_get_wtime();
            elapsedcontract += endcontract - startcontract;
            printf("Contract time: %f ms\n", (endcontract - startcontract) * 1000);
          }

          selector ^= 1;
          frontier_selector ^= 1;
//          queue_index++;

          if (DEBUG)
          {

            if (retval = util::B40CPerror(cudaMemcpy(&frontier_size, &d_frontier_size[frontier_selector], sizeof(SizeT), cudaMemcpyDeviceToHost),
                    "CsrProblem cudaMemcpy frontier_size failed", __FILE__,
                    __LINE__))
            return retval;
//            thrust::sort(graph_slice->frontier_queues.d_keys[selector^1], graph_slice->frontier_queues.d_keys[selector^1] + frontier_size);

//            printf("Frontier size after contract: %d\n", frontier_size);

//            VertexId* test_vid = new VertexId[frontier_size];
//            cudaMemcpy(test_vid, graph_slice->frontier_queues.d_keys[selector^1], frontier_size * sizeof(VertexId), cudaMemcpyDeviceToHost);
//            printf("Frontier after contract: ");
//            for (int i = 0; i < frontier_size; ++i)
//            {
//              printf("%d, ", test_vid[i]);
//            }
//            printf("\n");
//            delete[] test_vid;
          }

          // Check if done
          if (done[0] == 0)
          break;
        }
        if (retval = util::B40CPerror(cudaMemcpy(&frontier_size, &d_frontier_size[frontier_selector], sizeof(SizeT), cudaMemcpyDeviceToHost),
                "CsrProblem cudaMemcpy frontier_size failed", __FILE__,
                __LINE__))
        return retval;

        //convert compacted frontier to bitmap
        if(frontier_size > 0)
        {
          int nthreads = 256;
          int nblocks = (frontier_size + nthreads - 1) / nthreads;
          vertex_centric::mgpukernel::frontier2flag<Program><<<nblocks, nthreads>>>(frontier_size, graph_slice->nodes, graph_slice->frontier_queues.d_keys[selector^1], graph_slice->d_visit_flags);
          SYNC_CHECK();
          int byte_size = (graph_slice->nodes + 8 -1) / 8;
          nblocks = (byte_size + nthreads - 1) / nthreads;
          vertex_centric::mgpukernel::flag2bitmap<Program><<<nblocks, nthreads>>>(graph_slice->nodes, byte_size, graph_slice->d_visit_flags, graph_slice->d_bitmap_vertfrontier);
          SYNC_CHECK();

          if (DEBUG)
          {

//            int bitmap_cout = 0;
//            int byte_size = (graph_slice->nodes + 8 - 1) / 8;
//            char* test_vid = new char[byte_size];
//            cudaMemcpy(test_vid, graph_slice->d_bitmap_vertfrontier, byte_size, cudaMemcpyDeviceToHost);
//            printf("bitmap after contract: ");
//            for (int i = 0; i < byte_size; ++i)
//            {
//              for(int j=0; j<8; j++)
//              {
//                if(test_vid[i] & (1 << j))
//                {
//                  printf("%d, ", i*8 + j);
//                  bitmap_cout++;
//                }
//              }
//            }
//            printf("\n");
//            printf("bitmap_cout=%d\n", bitmap_cout);
//            delete[] test_vid;
          }

//          if (retval = util::B40CPerror(cudaMemset(graph_slice->d_bitmap_vertfrontier, 0, (graph_slice->nodes + 8 - 1) / 8),
//                  "Memset d_bitmap_vertfrontier failed", __FILE__, __LINE__))
//          return retval;

          if (retval = util::B40CPerror(cudaMemset(graph_slice->d_visit_flags, 0, graph_slice->nodes * sizeof(char)),
                  "Memset d_visit_flags failed", __FILE__, __LINE__))
          return retval;
        }
        iteration[0]++;
      }

      cudaEventRecord(stop);
      cudaEventSynchronize(stop);
      cudaDeviceSynchronize();
      double endTime = omp_get_wtime();
      double elapsed_wall = (endTime - startTime) * 1000;

      float elapsed;
      cudaEventElapsedTime(&elapsed, start, stop);
      std::cout << "Kernel time took: " << elapsed << " ms"
      << std::endl;
      std::cout << "Wall time took: " << elapsed_wall << " ms"
      << std::endl;
      std::cout << "Contract time took: " << elapsedcontract * 1000
      << " ms" << std::endl;
      std::cout << "Gather time took: " << elapsedgather * 1000
      << " ms" << std::endl;
      std::cout << "Expand time took: " << elapsedexpand * 1000
      << " ms" << std::endl;

      printf("Total iteration: %lld\n", (long long) iteration[0]);

//          delete[] srcs;
      cudaFree (m_gatherMapTmp);
      cudaFree (m_gatherTmp);
      if ( (Program::gatherOverEdges() == GATHER_ALL_EDGES || directed == 0) && Program::gatherOverEdges() == NO_GATHER_EDGES)
      {
        cudaFree (m_gatherTmp1);
        cudaFree (m_gatherTmp2);
      }

      cudaFree (m_gatherDstsTmp);
      cudaFree(edgeCountScan);

      return retval;
    }

    cudaError_t EnactIterativeSearch(CsrProblem &csr_problem,
        typename CsrProblem::SizeT* h_row_offsets,
        int directed, int num_srcs, int* srcs, int iter_num, int threshold)
    {
      typedef typename CsrProblem::VertexId VertexId;
      typedef typename CsrProblem::SizeT SizeT;

// GF100
      if (this->cuda_props.device_sm_version >= 200)
      {

        // Expansion kernel config
        typedef vertex_centric::expand_atomic::KernelPolicy<Program,
        typename CsrProblem::ProblemType, 200,// CUDA_ARCH
        INSTRUMENT,// INSTRUMENT
        1,// CTA_OCCUPANCY
        9,// LOG_THREADS
        0,// LOG_LOAD_VEC_SIZE
        0,// LOG_LOADS_PER_TILE
        5,// LOG_RAKING_THREADS
        util::io::ld::cg,// QUEUE_READ_MODIFIER,
        util::io::ld::NONE,// COLUMN_READ_MODIFIER,
        util::io::ld::NONE,// EDGE_VALUES_READ_MODIFIER,
        util::io::ld::cg,// ROW_OFFSET_ALIGNED_READ_MODIFIER,
        util::io::ld::NONE,// ROW_OFFSET_UNALIGNED_READ_MODIFIER,
        util::io::st::cg,// QUEUE_WRITE_MODIFIER,
        false,// WORK_STEALING
        32,// WARP_GATHER_THRESHOLD
        128 * 4,// CTA_GATHER_THRESHOLD,
        7>// LOG_SCHEDULE_GRANULARITY
        ExpandPolicy;

          // Contraction kernel config
        typedef vertex_centric::contract_atomic::KernelPolicy<Program,
        typename CsrProblem::ProblemType, 200,// CUDA_ARCH
        INSTRUMENT,// INSTRUMENT
        0,// SATURATION_QUIT
        true,// DEQUEUE_PROBLEM_SIZE
        8,// CTA_OCCUPANCY
        7,// LOG_THREADS
        1,// LOG_LOAD_VEC_SIZE
        0,// LOG_LOADS_PER_TILE
        5,// LOG_RAKING_THREADS
        util::io::ld::NONE,// QUEUE_READ_MODIFIER,
        util::io::st::NONE,// QUEUE_WRITE_MODIFIER,
        false,// WORK_STEALING
        -1,// END_BITMASK_CULL 0 to never perform bitmask filtering, -1 to always perform bitmask filtering
        8> // LOG_SCHEDULE_GRANULARITY
        ContractPolicy;

        return EnactIterativeSearch<ExpandPolicy, ContractPolicy>(
            csr_problem, h_row_offsets, directed, num_srcs, srcs, iter_num, threshold);
      }

      printf("Not yet tuned for this architecture\n");
      return cudaErrorInvalidDeviceFunction;
    }
  }
  ;

} // namespace GASengine

