/* 
 * File:   concomp.h
 * Author: zhisong
 *
 * Created on July 2, 2013, 9:17 AM
 */

#ifndef CONCOMP_H
#define	CONCOMP_H

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

/* Written Zhisong Fu 
   of SYSTAP, LLC
 */


//the activation flag is now the high bit of the edge field

struct concomp
{

  struct VertexType
  {
    int val;
    bool changed;
		int num_out_edges;

    __host__ __device__
    VertexType() : val(0), num_out_edges(0x80000000)
    {
    }
  };

  static GatherEdges gatherOverEdges()
  {
    return GATHER_IN_EDGES;
  }

  struct gather
  {

    __host__ __device__
            float operator()(const VertexType &dst, const VertexType &src, const int &e, const int flag)
    {
      return src.val;
    }
  };

  struct sum
  {

    __host__ __device__
            float operator()(int left, int right)
    {
      return min(left, right);
    }
  };

  struct apply
  {

    __host__ __device__
            void operator()(VertexType &cur_val, const int newvalue = 0)
    {
      int rnew = min(cur_val.val, newvalue);
      cur_val.changed = !(cur_val.val == newvalue);
      cur_val.val = rnew;      
    }
  };

  static ScatterEdges scatterOverEdges()
  {
    return SCATTER_OUT_EDGES;
  }

  struct scatter
  {

    __host__ __device__
            int operator()(const VertexType &dst, const VertexType &src, const int &e)
    {
      return src.changed;
    }
  };

};

#endif	/* CONCOMP_H */

