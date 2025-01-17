#include <cuda.h>
#include <cuda_runtime.h>

#include "common.h"
#include "efficient.h"

namespace StreamCompaction {
namespace Efficient {
using StreamCompaction::Common::PerformanceTimer;
PerformanceTimer &timer() {
  static PerformanceTimer timer;
  return timer;
}

/**
 * Work-Efficient Inclusive Scan
 * Input:   idata
 * Output:  odata --- inclusive scan, idata --- exclusive scan
 */
__global__ void kernScanInclusive(int n, int *odata, int *idata) {
  int tid   = threadIdx.x;
  int bdim  = blockDim.x;
  int id    = blockIdx.x * bdim + tid;
  int log2n = ilog2ceil((n < bdim) ? n : bdim);
  if (id < n) {
    // upsweep
    for (int d = 0; d < log2n; ++d) {
      if (id % (1 << (d + 1)) == 0) {
        idata[id + (1 << (d + 1)) - 1] += idata[id + (1 << d) - 1];
      }
      __syncthreads();
    }

    // last thread remembers and sets reduction sum after downsweep
    int reduction_sum = 0;
    if (tid == bdim - 1 || id == n - 1) {
      reduction_sum = idata[id];
      idata[id]     = 0;
    }
    __syncthreads();

    // downsweep
    for (int d = log2n - 1; d >= 0; --d) {
      if (id % (1 << (d + 1)) == 0) {
        int temp                 = idata[id + (1 << d) - 1];
        idata[id + (1 << d) - 1] = idata[id + (1 << (d + 1)) - 1];
        idata[id + (1 << (d + 1)) - 1] += temp;
      }
      __syncthreads();
    }

    // turn exclusive scan into inclusive scan
    if (tid == bdim - 1 || id == n - 1) {
      odata[id] = reduction_sum;
    } else {
      odata[id] = idata[id + 1];
    }
  }
}

/**
 * Performs prefix-sum (aka scan) on idata, storing the result into odata.
 */
void scan(int n, int *odata, const int *idata) {
  if (n <= 0) return;
  const int n_pad = 1 << (ilog2ceil(n));

  const unsigned int block_size = Common::block_size_efficient;
  int num_scans                 = 1;
  int len                       = n_pad;
  while ((len + block_size - 1) / block_size > 1) {
    ++num_scans;
    len = (len + block_size - 1) / block_size;
  }

  int **dev_idata  = (int **)malloc(num_scans * sizeof(int *));
  int **dev_odata  = (int **)malloc(num_scans * sizeof(int *));
  int **dev_buffer = (int **)malloc(num_scans * sizeof(int *));
  int *array_sizes = (int *)malloc(num_scans * sizeof(int));
  int *grid_sizes  = (int *)malloc(num_scans * sizeof(int));

  len = n_pad;
  for (int i = 0; i < num_scans; ++i) {
    cudaMalloc((void **)&dev_idata[i], len * sizeof(int));
    cudaMalloc((void **)&dev_odata[i], len * sizeof(int));
    cudaMalloc((void **)&dev_buffer[i], len * sizeof(int));
    checkCUDAError("cudaMalloc failed for dev_idata, dev_odata, dev_buffer!");
    array_sizes[i] = len;
    len            = (len + block_size - 1) / block_size;
    grid_sizes[i]  = len;
  }

  cudaMemcpy(dev_idata[0], idata, n * sizeof(int), cudaMemcpyHostToDevice);
  checkCUDAError("cudaMemcpy failed for idata --> dev_idata[0]!");

  /******* KERNEL INVOCATIONS *******/
  dim3 dimBlock{block_size};
  timer().startGpuTimer();
  for (int i = 0; i < num_scans; ++i) {
    dim3 dimGrid{(unsigned int)grid_sizes[i]};
    kernScanInclusive<<<dimGrid, dimBlock>>>(array_sizes[i], dev_buffer[i],
                                             dev_idata[i]);
    cudaMemcpy(dev_idata[i], dev_buffer[i], array_sizes[i] * sizeof(int),
               cudaMemcpyDeviceToDevice);
    if (i < num_scans - 1) {
      Common::kernExtractLastElementPerBlock<<<dimGrid, dimBlock>>>(
          array_sizes[i], dev_idata[i + 1], dev_idata[i]);
    }
  }
  for (int i = num_scans - 1; i >= 0; --i) {
    dim3 dimGrid{(unsigned int)grid_sizes[i]};
    Common::kernShiftToExclusive<<<dimGrid, dimBlock>>>(
        array_sizes[i], dev_odata[i], dev_buffer[i]);
    if (i >= 1) {
      dim3 next_dimGrid{(unsigned int)grid_sizes[i - 1]};
      Common::kernAddOffsetPerBlock<<<next_dimGrid, dimBlock>>>(
          array_sizes[i - 1], dev_buffer[i - 1], dev_odata[i],
          dev_idata[i - 1]);
    }
  }
  cudaDeviceSynchronize();
  timer().endGpuTimer();
  /**********************************/

  cudaMemcpy(odata, dev_odata[0], n * sizeof(int), cudaMemcpyDeviceToHost);

  // Free all memory allocations
  for (int i = 0; i < num_scans; ++i) {
    cudaFree(dev_idata[i]);
    cudaFree(dev_odata[i]);
    cudaFree(dev_buffer[i]);
  }
  free(grid_sizes);
  free(array_sizes);
  free(dev_idata);
  free(dev_odata);
  free(dev_buffer);
}

/**
 * Performs stream compaction on idata, storing the result into odata.
 * All zeroes are discarded.
 *
 * @param n      The number of elements in idata.
 * @param odata  The array into which to store elements.
 * @param idata  The array of elements to compact.
 * @returns      The number of elements remaining after compaction.
 */
int compact(int n, int *odata, const int *idata) {
  if (n <= 0) return n;
  const int n_pad = 1 << (ilog2ceil(n));

  const unsigned int block_size = Common::block_size_efficient;
  int num_scans                 = 1;
  int len                       = n_pad;
  while ((len + block_size - 1) / block_size > 1) {
    ++num_scans;
    len = (len + block_size - 1) / block_size;
  }

  // input data device allocation
  int *dev_idata, *dev_odata, *dev_bools;
  cudaMalloc((void **)&dev_idata, n_pad * sizeof(int));
  cudaMalloc((void **)&dev_odata, n_pad * sizeof(int));
  cudaMalloc((void **)&dev_bools, n_pad * sizeof(int));
  checkCUDAError("cudaMalloc dev_idata, dev_odata, dev_bools failed!");
  cudaMemset(dev_idata, 0, n_pad * sizeof(int));
  checkCUDAError("cudaMemset dev_idata to 0 failed!");
  cudaMemcpy(dev_idata, idata, n * sizeof(int), cudaMemcpyHostToDevice);
  checkCUDAError("cudaMemcpy failed for idata --> dev_idata!");

  int **dev_iIndices = (int **)malloc(num_scans * sizeof(int *));
  int **dev_oIndices = (int **)malloc(num_scans * sizeof(int *));
  int **dev_buffer   = (int **)malloc(num_scans * sizeof(int *));
  int *array_sizes   = (int *)malloc(num_scans * sizeof(int));
  int *grid_sizes    = (int *)malloc(num_scans * sizeof(int));

  len = n_pad;
  for (int i = 0; i < num_scans; ++i) {
    cudaMalloc((void **)&dev_iIndices[i], len * sizeof(int));
    cudaMalloc((void **)&dev_oIndices[i], len * sizeof(int));
    cudaMalloc((void **)&dev_buffer[i], len * sizeof(int));
    checkCUDAError(
        "cudaMalloc failed for dev_iIndices, dev_oIndices, dev_buffer!");
    array_sizes[i] = len;
    len            = (len + block_size - 1) / block_size;
    grid_sizes[i]  = len;
  }

  /******* KERNEL INVOCATION *******/
  dim3 dimGrid{(unsigned int)grid_sizes[0]}, dimBlock{block_size};
  timer().startGpuTimer();

  Common::kernMapToBoolean<<<dimGrid, dimBlock>>>(n_pad, dev_bools, dev_idata);
  cudaMemcpy(dev_iIndices[0], dev_bools, n_pad * sizeof(int),
             cudaMemcpyDeviceToDevice);
  for (int i = 0; i < num_scans; ++i) {
    dim3 dimGrid{(unsigned int)grid_sizes[i]};
    kernScanInclusive<<<dimGrid, dimBlock>>>(array_sizes[i], dev_buffer[i],
                                             dev_iIndices[i]);
    cudaMemcpy(dev_iIndices[i], dev_buffer[i], array_sizes[i] * sizeof(int),
               cudaMemcpyDeviceToDevice);
    if (i < num_scans - 1) {
      Common::kernExtractLastElementPerBlock<<<dimGrid, dimBlock>>>(
          array_sizes[i], dev_iIndices[i + 1], dev_iIndices[i]);
    }
  }
  for (int i = num_scans - 1; i >= 0; --i) {
    dim3 dimGrid{(unsigned int)grid_sizes[i]};
    Common::kernShiftToExclusive<<<dimGrid, dimBlock>>>(
        array_sizes[i], dev_oIndices[i], dev_buffer[i]);
    if (i >= 1) {
      dim3 next_dimGrid{(unsigned int)grid_sizes[i - 1]};
      Common::kernAddOffsetPerBlock<<<next_dimGrid, dimBlock>>>(
          array_sizes[i - 1], dev_buffer[i - 1], dev_oIndices[i],
          dev_iIndices[i - 1]);
    }
  }
  Common::kernScatter<<<dimGrid, dimBlock>>>(n_pad, dev_odata, dev_idata,
                                             dev_bools, dev_oIndices[0]);

  cudaDeviceSynchronize();
  timer().endGpuTimer();
  /*********************************/

  // transfer output data to CPU & analyze
  cudaMemcpy(odata, dev_odata, n * sizeof(int), cudaMemcpyDeviceToHost);
  checkCUDAError("cudaMemcpy odata from dev_odata failed!");

  // calculate num. of elements after compaction
  int *indices = (int *)malloc(n * sizeof(int));
  int *bools   = (int *)malloc(n * sizeof(int));
  cudaMemcpy(indices, dev_oIndices[0], n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(bools, dev_bools, n * sizeof(int), cudaMemcpyDeviceToHost);
  checkCUDAError(
      "cudaMemcpy indices from dev_oIndices, bools from dev_bools failed!");
  int compact_len = indices[n - 1] + bools[n - 1];

  // Free all memory allocations
  free(indices);
  free(bools);

  for (int i = 0; i < num_scans; ++i) {
    cudaFree(dev_iIndices[i]);
    cudaFree(dev_oIndices[i]);
    cudaFree(dev_buffer[i]);
  }
  cudaFree(dev_bools);
  cudaFree(dev_idata);
  cudaFree(dev_odata);
  free(grid_sizes);
  free(array_sizes);
  free(dev_iIndices);
  free(dev_oIndices);
  free(dev_buffer);

  return compact_len;
}
}  // namespace Efficient
}  // namespace StreamCompaction
