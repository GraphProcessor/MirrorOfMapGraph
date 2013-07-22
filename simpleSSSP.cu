/*********************************************************

Licensed to the Apache Software Foundation (ASF) under one
or more contributor license agreements.  See the NOTICE file
distributed with this work for additional information
regarding copyright ownership.  The ASF licenses this file
to you under the Apache License, Version 2.0 (the
"License"); you may not use this file except in compliance
with the License.  You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing,
software distributed under the License is distributed on an
"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, either express or implied.  See the License for the
specific language governing permissions and limitations
under the License.

**********************************************************/

/* Written by Erich Elsen and Vishal Vaidyanathan
   of Royal Caliber, LLC
   Contact us at: info@royal-caliber.com
*/

typedef unsigned int uint;

#include "GASEngine.h"
#include "sssp.h"
#include <thrust/random/linear_congruential_engine.h>
#include <thrust/random/normal_distribution.h>
#include <thrust/random/uniform_int_distribution.h>
#include "graphio.h"
#include <cstdlib>

void generateRandomGraph(std::vector<int> &h_edge_src_vertex,
                         std::vector<int> &h_edge_dst_vertex,
                         int numVertices, int avgEdgesPerVertex) {
  thrust::minstd_rand rng;
  thrust::random::experimental::normal_distribution<float> n_dist(avgEdgesPerVertex, sqrtf(avgEdgesPerVertex));
  thrust::uniform_int_distribution<int> u_dist(0, numVertices - 1);

  for (int v = 0; v < numVertices; ++v) {
    int numEdges = min(max((int)roundf(n_dist(rng)), 1), 1000);
    for (int e = 0; e < numEdges; ++e) {
      uint dst_v = u_dist(rng);
      h_edge_src_vertex.push_back(v);
      h_edge_dst_vertex.push_back(dst_v);
    }
  }
}

int main(int argc, char **argv) {

  int numVertices;
  const char* outFileName = 0;

  //generate simple random graph
  std::vector<int> h_edge_src_vertex;
  std::vector<int> h_edge_dst_vertex;
  std::vector<int> h_edge_data;
  int ispattern;
  
  if (argc == 1) {
    numVertices = 1000000;
    const int avgEdgesPerVertex = 10;
    generateRandomGraph(h_edge_src_vertex, h_edge_dst_vertex, numVertices, avgEdgesPerVertex);
    h_edge_data.reserve(h_edge_src_vertex.size());
    for (int i = 0; i < h_edge_src_vertex.size(); ++i) {
      h_edge_data.push_back(rand() % 100);
    }
  }
  else if (argc == 2 || argc == 3) {
    ispattern = loadGraph( argv[1], numVertices, h_edge_src_vertex, h_edge_dst_vertex, &h_edge_data );
    if (argc == 3)
      outFileName = argv[2];
  }
  else {
    std::cerr << "Too many arguments!" << std::endl;
    exit(1);
  }

  const uint numEdges = h_edge_src_vertex.size();
  if(ispattern == 0) // if it is pattern mtx
      h_edge_data = std::vector<int>(numEdges, 1);

  thrust::device_vector<int> d_edge_src_vertex = h_edge_src_vertex;
  thrust::device_vector<int> d_edge_dst_vertex = h_edge_dst_vertex;
  thrust::device_vector<int> d_edge_data = h_edge_data;

  //use PSW ordering
  thrust::sort_by_key(d_edge_dst_vertex.begin(), d_edge_dst_vertex.end(), thrust::make_zip_iterator(
                                                                          thrust::make_tuple(
                                                                            d_edge_src_vertex.begin(),
                                                                            d_edge_data.begin())));

  thrust::device_vector<sssp::VertexType> d_vertex_data(numVertices); //each vertex value starts at "infinity"

  std::vector<thrust::device_vector<int> > d_active_vertex_flags;
  {
    thrust::device_vector<int> foo;
    d_active_vertex_flags.push_back(foo);
    d_active_vertex_flags.push_back(foo);
  }

  //find max out degree vertex to start
  int startVertex;
  std::vector<char> existing_vertices(numVertices, 0);
  {
    std::vector<int> h_out_edges(numVertices);
    for (int i = 0; i < h_edge_src_vertex.size(); ++i) {
      h_out_edges[h_edge_src_vertex[i]]++;
      existing_vertices[h_edge_src_vertex[i]] = 1;
      existing_vertices[h_edge_dst_vertex[i]] = 1;
    }

    startVertex = std::max_element(h_out_edges.begin(), h_out_edges.end()) - h_out_edges.begin();
  }
  std::cout << "Starting at " << startVertex << " of " << numVertices << std::endl;

  //one vertex starts active in sssp
  d_active_vertex_flags[0].resize(numVertices, 0);
  d_active_vertex_flags[1].resize(numVertices, 0);


  d_active_vertex_flags[0][startVertex] = 1;
  d_vertex_data[startVertex] = sssp::VertexType(0, true);

  std::vector<int> ret(2);
  GASEngine<sssp, sssp::VertexType, int, int, int> engine;

  cudaEvent_t start, stop;
  cudaEventCreate(&start); cudaEventCreate(&stop);

  cudaEventRecord(start);

  ret = engine.run(d_edge_dst_vertex,
                            d_edge_src_vertex,
                            d_vertex_data,
                            d_edge_data,
                            d_active_vertex_flags, INT_MAX);

  cudaEventRecord(stop);
  cudaEventSynchronize(stop);

  int diameter = ret[0]; 
  float elapsed;
  cudaEventElapsedTime(&elapsed, start, stop);
  std::cout << "Took: " << elapsed << " ms" << std::endl;
  std::cout << "Iterations to convergence: " << diameter << std::endl;

  if (outFileName) {
    FILE* f = fopen(outFileName, "w");
    std::vector<sssp::VertexType> h_vertex_data(d_vertex_data.size());
    thrust::copy(d_vertex_data.begin(), d_vertex_data.end(), h_vertex_data.begin());

    for ( int i = 0; i < existing_vertices.size(); ++i)
    {
      if (!existing_vertices[i])
        continue;
      fprintf( f, "%d\t%d\n", i, h_vertex_data[i].dist);
    }

    fclose(f);
  }
  
  return 0;
}
