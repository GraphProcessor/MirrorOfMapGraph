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
 * Simple test utilities for consecutive reduction
 ******************************************************************************/

#pragma once

#include <stdio.h> 

// ConsecutiveReduction includes
#include <b40c/consecutive_reduction/enactor.cuh>

// Test utils
#include "b40c_test_util.h"


/******************************************************************************
 * Test wrappers for binary, associative operations
 ******************************************************************************/

template <typename T>
struct Sum
{
	// Binary reduction
	__host__ __device__ __forceinline__ T operator()(const T &a, const T &b)
	{
		return a + b;
	}
};

template <typename T>
struct Max
{
	// Binary reduction
	__host__ __device__ __forceinline__ T operator()(const T &a, const T &b)
	{
		return (a > b) ? a : b;
	}
};


template <typename T>
struct Equality
{
	// Equality test
	__host__ __device__ __forceinline__ bool operator()(const T &a, const T &b)
	{
		return a == b;
	}
};


/******************************************************************************
 * Utility Routines
 ******************************************************************************/

/**
 * Timed consecutive reduction.  Uses the GPU to copy the specified vector of elements for the given
 * number of iterations, displaying runtime information.
 */
template <
	b40c::consecutive_reduction::ProbSizeGenre PROB_SIZE_GENRE,
	typename DoubleBuffer,
	typename SizeT,
	typename ReductionOp,
	typename EqualityOp>
double TimedConsecutiveReduction(
	DoubleBuffer &h_problem_storage,			// host problem storage (selector points to input, but output contains reference result)
	SizeT num_elements,
	SizeT num_compacted,						// number of elements in reference result
	ReductionOp scan_op,
	EqualityOp equality_op,
	int max_ctas,
	bool verbose,
	int iterations)
{
	using namespace b40c;

	typedef typename DoubleBuffer::KeyType 		KeyType;
	typedef typename DoubleBuffer::ValueType 	ValueType;

	// Allocate device storage
	DoubleBuffer 	d_problem_storage;
	SizeT				*d_num_compacted;

	if (util::B40CPerror(cudaMalloc((void**) &d_problem_storage.d_keys[0], sizeof(KeyType) * num_elements),
		"TimedConsecutiveReduction cudaMalloc d_keys failed: ", __FILE__, __LINE__)) exit(1);
	if (util::B40CPerror(cudaMalloc((void**) &d_problem_storage.d_keys[1], sizeof(KeyType) * num_elements),
		"TimedConsecutiveReduction cudaMalloc d_keys failed: ", __FILE__, __LINE__)) exit(1);
	if (util::B40CPerror(cudaMalloc((void**) &d_problem_storage.d_values[0], sizeof(ValueType) * num_elements),
		"TimedConsecutiveReduction cudaMalloc d_values failed: ", __FILE__, __LINE__)) exit(1);
	if (util::B40CPerror(cudaMalloc((void**) &d_problem_storage.d_values[1], sizeof(ValueType) * num_elements),
		"TimedConsecutiveReduction cudaMalloc d_values failed: ", __FILE__, __LINE__)) exit(1);

	if (util::B40CPerror(cudaMalloc((void**) &d_num_compacted, sizeof(SizeT) * 1),
		"TimedConsecutiveReduction cudaMalloc d_num_compacted failed: ", __FILE__, __LINE__)) exit(1);

	// Move a fresh copy of the problem into device storage
	if (util::B40CPerror(cudaMemcpy(
			d_problem_storage.d_keys[0],
			h_problem_storage.d_keys[0],
			sizeof(KeyType) * num_elements,
			cudaMemcpyHostToDevice),
		"TimedConsecutiveReduction cudaMemcpy d_keys failed: ", __FILE__, __LINE__)) exit(1);
	if (util::B40CPerror(cudaMemcpy(
			d_problem_storage.d_values[0],
			h_problem_storage.d_values[0],
			sizeof(ValueType) * num_elements,
			cudaMemcpyHostToDevice),
		"TimedConsecutiveReduction cudaMemcpy d_values failed: ", __FILE__, __LINE__)) exit(1);

	// Create enactor
	consecutive_reduction::Enactor enactor;

	SizeT gpu_num_compacted;

	// Marker kernel in profiling stream
	util::FlushKernel<void><<<1,1>>>();

	// Perform a single iteration to allocate any memory if needed, prime code caches, etc.
	printf("\n");
	enactor.ENACTOR_DEBUG = true;
	enactor.template Reduce<PROB_SIZE_GENRE>(
		d_problem_storage,
		num_elements,
		&gpu_num_compacted,
		d_num_compacted,
		scan_op,
		equality_op,
		max_ctas);
	enactor.ENACTOR_DEBUG = false;

	// Perform the timed number of iterations
	GpuTimer timer;

	double elapsed = 0;
	for (int i = 0; i < iterations; i++) {

		// Marker kernel in profiling stream
		util::FlushKernel<void><<<1,1>>>();

		// Start timing record
		timer.Start();

		// Call the consecutive reduction API routine
		enactor.template Reduce<PROB_SIZE_GENRE>(
			d_problem_storage,
			num_elements,
			(SizeT *) NULL,
			d_num_compacted,
			scan_op,
			equality_op,
			max_ctas);

		// End timing record
		timer.Stop();
		elapsed += (double) timer.ElapsedMillis();
	}

	// Display timing information
	double avg_runtime = elapsed / iterations;
	double throughput = ((double) num_elements) / avg_runtime / 1000.0 / 1000.0;
	long long bytes = ((num_elements * 2) + num_compacted) * (sizeof(KeyType) + sizeof(ValueType));
	double bandwidth = bytes / avg_runtime / 1000.0 / 1000.0;
	printf("\nB40C consecutive reduction: %d iterations, %lu elements -> %lu compacted, ",
		iterations, (unsigned long) num_elements, (unsigned long) num_compacted);
    printf("%f GPU ms, %f x10^9 elts/sec, %f x10^9 B/sec, ",
		avg_runtime, throughput, bandwidth);

	// Check and display results
	printf("\nCompacted keys: ");
	CompareDeviceResults(h_problem_storage.d_keys[1], d_problem_storage.d_keys[1], num_compacted, verbose, verbose);
	printf("\nCompacted and reduced values: ");
	CompareDeviceResults(h_problem_storage.d_values[1], d_problem_storage.d_values[1], num_compacted, verbose, verbose);
	printf("\nCompacted size: ");
	CompareDeviceResults(&num_compacted, d_num_compacted, 1, verbose, verbose);
	printf("\nCompacted size reported to host: %s\n", (num_compacted == gpu_num_compacted) ? "CORRECT" : "INCORRECT");
	printf("\n");
	fflush(stdout);

	// Free allocated memory
    if (d_problem_storage.d_keys[0]) cudaFree(d_problem_storage.d_keys[0]);
    if (d_problem_storage.d_keys[1]) cudaFree(d_problem_storage.d_keys[1]);
    if (d_problem_storage.d_values[0]) cudaFree(d_problem_storage.d_values[0]);
    if (d_problem_storage.d_values[1]) cudaFree(d_problem_storage.d_values[1]);
    if (d_num_compacted) cudaFree(d_num_compacted);

	// Flushes any stdio from the GPU
	cudaThreadSynchronize();

	return throughput;
}


