/******************************************************************************
 * 
 * Copyright 2010-2012 Duane Merrill
 * 
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License. 
 * 
 * For more information, see our Google Code project site: 
 * http://code.google.com/p/back40computing/
 * 
 ******************************************************************************/

/******************************************************************************
 * Segmented scan downsweep scan kernel
 ******************************************************************************/

#pragma once

#include <b40c/util/cta_work_distribution.cuh>
#include <b40c/segmented_scan/downsweep/cta.cuh>

namespace b40c {
namespace segmented_scan {
namespace downsweep {


/**
 * Segmented scan downsweep scan pass
 */
template <typename KernelPolicy>
__device__ __forceinline__ void DownsweepPass(
	typename KernelPolicy::T 									*d_partials_in,
	typename KernelPolicy::Flag									*d_flags_in,
	typename KernelPolicy::T 									*d_partials_out,
	typename KernelPolicy::T 									*d_spine_partials,
	typename KernelPolicy::ReductionOp 							scan_op,
	typename KernelPolicy::IdentityOp 							identity_op,
	util::CtaWorkDistribution<typename KernelPolicy::SizeT> 	&work_decomposition,
	typename KernelPolicy::SmemStorage							&smem_storage)
{
	typedef Cta<KernelPolicy> 						Cta;
	typedef typename KernelPolicy::T				T;
	typedef typename KernelPolicy::SizeT 			SizeT;
	typedef typename KernelPolicy::SoaScanOperator	SoaScanOperator;

	// Read the exclusive partial from our spine
	T spine_partial;
	util::io::ModifiedLoad<KernelPolicy::READ_MODIFIER>::Ld(
		spine_partial, d_spine_partials + blockIdx.x);

	// CTA processing abstraction
	Cta cta(
		smem_storage,
		d_partials_in,
		d_flags_in,
		d_partials_out,
		SoaScanOperator(scan_op, identity_op),
		spine_partial);

	// Determine our threadblock's work range
	util::CtaWorkLimits<SizeT> work_limits;
	work_decomposition.template GetCtaWorkLimits<
		KernelPolicy::LOG_TILE_ELEMENTS,
		KernelPolicy::LOG_SCHEDULE_GRANULARITY>(work_limits);

	cta.ProcessWorkRange(work_limits);
}


/**
 * Segmented scan downsweep scan kernel entry point
 */
template <typename KernelPolicy>
__launch_bounds__ (KernelPolicy::THREADS, KernelPolicy::MIN_CTA_OCCUPANCY)
__global__
void Kernel(
	typename KernelPolicy::T 									*d_partials_in,
	typename KernelPolicy::Flag									*d_flags_in,
	typename KernelPolicy::T 									*d_partials_out,
	typename KernelPolicy::T 									*d_spine_partials,
	typename KernelPolicy::ReductionOp 							scan_op,
	typename KernelPolicy::IdentityOp 							identity_op,
	util::CtaWorkDistribution<typename KernelPolicy::SizeT> 	work_decomposition)
{
	// Shared storage for the kernel
	__shared__ typename KernelPolicy::SmemStorage smem_storage;

	DownsweepPass<KernelPolicy>(
		d_partials_in,
		d_flags_in,
		d_partials_out,
		d_spine_partials,
		scan_op,
		identity_op,
		work_decomposition,
		smem_storage);
}


} // namespace downsweep
} // namespace segmented_scan
} // namespace b40c

