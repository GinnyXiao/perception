#include <stdio.h>
#include <cuda.h>
#include <cublas.h>
#include "cuda_renderer/renderer.h"
#include "cuda_renderer/knncuda.h"
#include <thrust/transform_reduce.h>
#include <thrust/functional.h>

#define BLOCK_DIM 16


/**
 * Computes the squared Euclidean distance matrix between the query points and the reference points.
 *
 * @param ref          refence points stored in the global memory
 * @param ref_width    number of reference points
 * @param ref_pitch    pitch of the reference points array in number of column
 * @param query        query points stored in the global memory
 * @param query_width  number of query points
 * @param query_pitch  pitch of the query points array in number of columns
 * @param height       dimension of points = height of texture `ref` and of the array `query`
 * @param dist         array containing the query_width x ref_width computed distances
 */
 namespace cuda_renderer {
__global__ void compute_distances(float * ref,
                                  int     ref_width,
                                  int     ref_pitch,
                                  float * query,
                                  int     query_width,
                                  int     query_pitch,
                                  int     height,
                                  float * dist) {

    // Declaration of the shared memory arrays As and Bs used to store the sub-matrix of A and B
    __shared__ float shared_A[BLOCK_DIM][BLOCK_DIM];
    __shared__ float shared_B[BLOCK_DIM][BLOCK_DIM];

    // Sub-matrix of A (begin, step, end) and Sub-matrix of B (begin, step)
    __shared__ int begin_A;
    __shared__ int begin_B;
    __shared__ int step_A;
    __shared__ int step_B;
    __shared__ int end_A;

    // Thread index
    int tx = threadIdx.x;
    int ty = threadIdx.y;

    // Initializarion of the SSD for the current thread
    float ssd = 0.f;

    // Loop parameters
    begin_A = BLOCK_DIM * blockIdx.y;
    begin_B = BLOCK_DIM * blockIdx.x;
    step_A  = BLOCK_DIM * ref_pitch;
    step_B  = BLOCK_DIM * query_pitch;
    end_A   = begin_A + (height-1) * ref_pitch;

    // Conditions
    int cond0 = (begin_A + tx < ref_width); // used to write in shared memory
    int cond1 = (begin_B + tx < query_width); // used to write in shared memory & to computations and to write in output array 
    int cond2 = (begin_A + ty < ref_width); // used to computations and to write in output matrix

    // Loop over all the sub-matrices of A and B required to compute the block sub-matrix
    for (int a = begin_A, b = begin_B; a <= end_A; a += step_A, b += step_B) {

        // Load the matrices from device memory to shared memory; each thread loads one element of each matrix
        if (a/ref_pitch + ty < height) {
            shared_A[ty][tx] = (cond0)? ref[a + ref_pitch * ty + tx] : 0;
            shared_B[ty][tx] = (cond1)? query[b + query_pitch * ty + tx] : 0;
        }
        else {
            shared_A[ty][tx] = 0;
            shared_B[ty][tx] = 0;
        }

        // Synchronize to make sure the matrices are loaded
        __syncthreads();

        // Compute the difference between the two matrixes; each thread computes one element of the block sub-matrix
        if (cond2 && cond1) {
            for (int k = 0; k < BLOCK_DIM; ++k){
                float tmp = shared_A[k][ty] - shared_B[k][tx];
                ssd += tmp*tmp;
            }
        }

        // Synchronize to make sure that the preceeding computation is done before loading two new sub-matrices of A and B in the next iteration
        __syncthreads();
    }

    // Write the block sub-matrix to device memory; each thread writes one element
    if (cond2 && cond1) {
        dist[ (begin_A + ty) * query_pitch + begin_B + tx ] = ssd;
    }
}


/**
 * Computes the squared Euclidean distance matrix between the query points and the reference points.
 *
 * @param ref          refence points stored in the texture memory
 * @param ref_width    number of reference points
 * @param query        query points stored in the global memory
 * @param query_width  number of query points
 * @param query_pitch  pitch of the query points array in number of columns
 * @param height       dimension of points = height of texture `ref` and of the array `query`
 * @param dist         array containing the query_width x ref_width computed distances
 */
__global__ void compute_distance_texture(cudaTextureObject_t ref,
                                         int                 ref_width,
                                         float *             query,
                                         int                 query_width,
                                         int                 query_pitch,
                                         int                 height,
                                         float*              dist) {
    unsigned int xIndex = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned int yIndex = blockIdx.y * blockDim.y + threadIdx.y;
    if ( xIndex<query_width && yIndex<ref_width) {
        float ssd = 0.f;
        for (int i=0; i<height; i++) {
            float tmp  = tex2D<float>(ref, (float)yIndex, (float)i) - query[i * query_pitch + xIndex];
            ssd += tmp * tmp;
        }
        dist[yIndex * query_pitch + xIndex] = ssd;
    }
}


/**
 * For each reference point (i.e. each column) finds the k-th smallest distances
 * of the distance matrix and their respective indexes and gathers them at the top
 * of the 2 arrays.
 *
 * Since we only need to locate the k smallest distances, sorting the entire array
 * would not be very efficient if k is relatively small. Instead, we perform a
 * simple insertion sort by eventually inserting a given distance in the first
 * k values.
 *
 * @param dist         distance matrix
 * @param dist_pitch   pitch of the distance matrix given in number of columns
 * @param index        index matrix
 * @param index_pitch  pitch of the index matrix given in number of columns
 * @param width        width of the distance matrix and of the index matrix
 * @param height       height of the distance matrix
 * @param k            number of values to find
 */
__global__ void modified_insertion_sort(float * dist,
                                        int     dist_pitch,
                                        int *   index,
                                        int     index_pitch,
                                        int     width,
                                        int     height,
                                        int     k){

    // Column position
    unsigned int xIndex = blockIdx.x * blockDim.x + threadIdx.x;

    // Do nothing if we are out of bounds
    if (xIndex < width) {

        // Pointer shift
        float * p_dist  = dist  + xIndex;
        int *   p_index = index + xIndex;

        // Initialise the first index
        p_index[0] = 0;

        // Go through all points
        for (int i=1; i<height; ++i) {

            // Store current distance and associated index
            float curr_dist = p_dist[i*dist_pitch];
            int   curr_index  = i;

            // Skip the current value if its index is >= k and if it's higher the k-th slready sorted mallest value
            if (i >= k && curr_dist >= p_dist[(k-1)*dist_pitch]) {
                continue;
            }

            // Shift values (and indexes) higher that the current distance to the right
            int j = min(i, k-1);
            while (j > 0 && p_dist[(j-1)*dist_pitch] > curr_dist) {
                p_dist[j*dist_pitch]   = p_dist[(j-1)*dist_pitch];
                p_index[j*index_pitch] = p_index[(j-1)*index_pitch];
                --j;
            }

            // Write the current distance and index at their position
            p_dist[j*dist_pitch]   = curr_dist;
            p_index[j*index_pitch] = curr_index; 
        }
    }
}


/**
 * Computes the square root of the first k lines of the distance matrix.
 *
 * @param dist   distance matrix
 * @param width  width of the distance matrix
 * @param pitch  pitch of the distance matrix given in number of columns
 * @param k      number of values to consider
 */
__global__ void compute_sqrt(float * dist, int width, int pitch, int k){
    unsigned int xIndex = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned int yIndex = blockIdx.y * blockDim.y + threadIdx.y;
    if (xIndex<width && yIndex<k)
        dist[yIndex*pitch + xIndex] = sqrt(dist[yIndex*pitch + xIndex]);
}


/**
 * Computes the squared norm of each column of the input array.
 *
 * @param array   input array
 * @param width   number of columns of `array` = number of points
 * @param pitch   pitch of `array` in number of columns
 * @param height  number of rows of `array` = dimension of the points
 * @param norm    output array containing the squared norm values
 */
__global__ void compute_squared_norm(float * array, int width, int pitch, int height, float * norm){
    unsigned int xIndex = blockIdx.x * blockDim.x + threadIdx.x;
    if (xIndex<width){
        float sum = 0.f;
        for (int i=0; i<height; i++){
            float val = array[i*pitch+xIndex];
            sum += val*val;
        }
        norm[xIndex] = sum;
    }
}


/**
 * Add the reference points norm (column vector) to each colum of the input array.
 *
 * @param array   input array
 * @param width   number of columns of `array` = number of points
 * @param pitch   pitch of `array` in number of columns
 * @param height  number of rows of `array` = dimension of the points
 * @param norm    reference points norm stored as a column vector
 */
__global__ void add_reference_points_norm(float * array, int width, int pitch, int height, float * norm){
    unsigned int tx = threadIdx.x;
    unsigned int ty = threadIdx.y;
    unsigned int xIndex = blockIdx.x * blockDim.x + tx;
    unsigned int yIndex = blockIdx.y * blockDim.y + ty;
    __shared__ float shared_vec[16];
    if (tx==0 && yIndex<height)
        shared_vec[ty] = norm[yIndex];
    __syncthreads();
    if (xIndex<width && yIndex<height)
        array[yIndex*pitch+xIndex] += shared_vec[ty];
}


/**
 * Adds the query points norm (row vector) to the k first lines of the input
 * array and computes the square root of the resulting values.
 *
 * @param array   input array
 * @param width   number of columns of `array` = number of points
 * @param pitch   pitch of `array` in number of columns
 * @param k       number of neighbors to consider
 * @param norm     query points norm stored as a row vector
 */
__global__ void add_query_points_norm_and_sqrt(float * array, int width, int pitch, int k, float * norm){
    unsigned int xIndex = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned int yIndex = blockIdx.y * blockDim.y + threadIdx.y;
    if (xIndex<width && yIndex<k)
        array[yIndex*pitch + xIndex] = sqrt(array[yIndex*pitch + xIndex] + norm[xIndex]);
}
__global__ void depth_to_mask(
    int32_t* depth, int* mask, int width, int height, int stride, int* pose_occluded)
{
    int n = (int)floorf((blockIdx.x * blockDim.x + threadIdx.x)/(width/stride));
    int x = (blockIdx.x * blockDim.x + threadIdx.x)%(width/stride);
    int y = blockIdx.y*blockDim.y + threadIdx.y;
    x = x*stride;
    y = y*stride;
    if(x >= width) return;
    if(y >= height) return;
    uint32_t idx_depth = n * width * height + x + y*width;
    uint32_t idx_mask = n * width * height + x + y*width;

    if(depth[idx_depth] > 0 && !pose_occluded[n]) 
    {
        mask[idx_mask] = 1;
    }
}

__global__ void depth_to_cloud(
    int32_t* depth, float* cloud, int cloud_rendered_cloud_point_num, int* mask, int width, int height, 
    float kCameraCX, float kCameraCY, float kCameraFX, float kCameraFY, float depth_factor,
    int stride, int* cloud_pose_map)
{
    int n = (int)floorf((blockIdx.x * blockDim.x + threadIdx.x)/(width/stride));
    int x = (blockIdx.x * blockDim.x + threadIdx.x)%(width/stride);
    int y = blockIdx.y * blockDim.y + threadIdx.y;

    // uint32_t x = blockIdx.x*blockDim.x + threadIdx.x;
    // uint32_t y = blockIdx.y*blockDim.y + threadIdx.y;
    x = x*stride;
    y = y*stride;
    if(x >= width) return;
    if(y >= height) return;
    uint32_t idx_depth = n * width * height + x + y*width;

    if(depth[idx_depth] <= 0) return;

    // printf("depth:%d\n", depth[idx_depth]);
    // uchar depth_val = depth[idx_depth];
    float z_pcd = static_cast<float>(depth[idx_depth])/depth_factor;
    float x_pcd = (static_cast<float>(x) - kCameraCX)/kCameraFX * z_pcd;
    float y_pcd = (static_cast<float>(y) - kCameraCY)/kCameraFY * z_pcd;
    // printf("kCameraCX:%f,kCameraFX:%f, kCameraCY:%f, kCameraCY:%f\n", kCameraCX,kCameraFX,kCameraCY, y_pcd, z_pcd);

    // printf("x:%d,y:%d, x_pcd:%f, y_pcd:%f, z_pcd:%f\n", x,y,x_pcd, y_pcd, z_pcd);
    uint32_t idx_mask = n * width * height + x + y*width;
    int cloud_idx = mask[idx_mask];
    cloud[cloud_idx + 0*cloud_rendered_cloud_point_num] = x_pcd;
    cloud[cloud_idx + 1*cloud_rendered_cloud_point_num] = y_pcd;
    cloud[cloud_idx + 2*cloud_rendered_cloud_point_num] = z_pcd;
    cloud_pose_map[cloud_idx] = n;
    // printf("cloud_idx:%d\n", cloud_pose_map[cloud_idx]);

    // cloud[3*cloud_idx + 0] = x_pcd;
    // cloud[3*cloud_idx + 1] = y_pcd;
    // cloud[3*cloud_idx + 2] = z_pcd;
}

bool depth2cloud_global(int32_t* depth_data,
                        float* &result_cloud,
                        int* &dc_index,
                        int &rendered_cloud_point_num,
                        int* &cloud_pose_map,
                        int width, 
                        int height, 
                        int num_poses,
                        int* pose_occluded,
                        float kCameraCX, 
                        float kCameraCY, 
                        float kCameraFX, 
                        float kCameraFY,
                        float depth_factor,
                        int stride,
                        int point_dim)
{
    printf("depth2cloud_global()\n");
    // int size = num_poses * width * height * sizeof(float);
    // int point_dim = 3;
    // int* depth_data = result_depth.data();
    // float* cuda_cloud;
    // // int* mask;

    // cudaMalloc(&cuda_cloud, point_dim*size);
    // cudaMalloc(&mask, size);

    int32_t* depth_data_cuda;
    int* pose_occluded_cuda;
    // int stride = 5;
    cudaMalloc(&depth_data_cuda, num_poses * width * height * sizeof(int32_t));
    cudaMemcpy(depth_data_cuda, depth_data, num_poses * width * height * sizeof(int32_t), cudaMemcpyHostToDevice);
    
    cudaMalloc(&pose_occluded_cuda, num_poses * sizeof(int));
    cudaMemcpy(pose_occluded_cuda, pose_occluded, num_poses * sizeof(int), cudaMemcpyHostToDevice);

    dim3 threadsPerBlock(16, 16);
    dim3 numBlocks((width/stride * num_poses + threadsPerBlock.x - 1)/threadsPerBlock.x, (height/stride + threadsPerBlock.y - 1)/threadsPerBlock.y);

    thrust::device_vector<int> mask(width*height*num_poses, 0);
    int* mask_ptr = thrust::raw_pointer_cast(mask.data());

    depth_to_mask<<<numBlocks, threadsPerBlock>>>(depth_data_cuda, mask_ptr, width, height, stride, pose_occluded_cuda);
    if (cudaGetLastError() != cudaSuccess) 
    {
        printf("ERROR: Unable to execute kernel\n");
        return false;
    }
    cudaDeviceSynchronize();

    // Create mapping from pixel to corresponding index in point cloud
    int mask_back_temp = mask.back();
    thrust::exclusive_scan(mask.begin(), mask.end(), mask.begin(), 0); // in-place scan
    rendered_cloud_point_num = mask.back() + mask_back_temp;
    printf("Actual points in all clouds : %d\n", rendered_cloud_point_num);

    float* cuda_cloud;
    int* cuda_cloud_pose_map;
    cudaMalloc(&cuda_cloud, point_dim * rendered_cloud_point_num * sizeof(float));
    cudaMalloc(&cuda_cloud_pose_map, rendered_cloud_point_num * sizeof(int));

    result_cloud = (float*) malloc(point_dim * rendered_cloud_point_num * sizeof(float));
    dc_index = (int*) malloc(num_poses * width * height * sizeof(int));
    cloud_pose_map = (int*) malloc(rendered_cloud_point_num * sizeof(int));

    depth_to_cloud<<<numBlocks, threadsPerBlock>>>(
                        depth_data_cuda, cuda_cloud, rendered_cloud_point_num, mask_ptr, width, height, 
                        kCameraCX, kCameraCY, kCameraFX, kCameraFY, depth_factor, stride, cuda_cloud_pose_map);
        
    cudaDeviceSynchronize();
    cudaMemcpy(result_cloud, cuda_cloud, point_dim * rendered_cloud_point_num * sizeof(float), cudaMemcpyDeviceToHost);
    cudaMemcpy(dc_index, mask_ptr, num_poses * width * height * sizeof(int), cudaMemcpyDeviceToHost);
    cudaMemcpy(cloud_pose_map, cuda_cloud_pose_map, rendered_cloud_point_num * sizeof(int), cudaMemcpyDeviceToHost);
    // for (int i = 0; i < rendered_cloud_point_num; i++)
    // {
    //     printf("%d ", cloud_pose_map[i]);
    // }
    // printf("\n");
    // for(int n = 0; n < num_poses; n ++)
    // {
    //     for(int i = 0; i < height; i ++)
    //     {
    //         for(int j = 0; j < width; j ++)
    //         {
    //             int index = n*width*height + (i*width + j);
    //             int cloud_index = mask[index];
    //             // printf("cloud_i:%d\n", cloud_index);
    //             if (depth_data[index] > 0)
    //             {
    //                 // printf("x:%f,y:%f,z:%f\n", 
    //                 // result_cloud[3*cloud_index], result_cloud[3*cloud_index + 1], result_cloud[3*cloud_index + 2]);
    //             }
    //         }
    //     }
    // }
    if (cudaGetLastError() != cudaSuccess) 
    {
        printf("ERROR: Unable to execute kernel\n");
        return false;
    }
    printf("depth2cloud_global() Done\n");
    cudaFree(depth_data_cuda);
    cudaFree(cuda_cloud);
    cudaFree(pose_occluded_cuda);
    return true;
}
__global__ void compute_render_cost(
        float* cuda_knn_dist,
        int* cuda_cloud_pose_map,
        int* cuda_poses_occluded,
        float* cuda_rendered_cost,
        float sensor_resolution,
        int rendered_cloud_point_num,
        float* cuda_pose_point_num
    )
{
    size_t point_index = blockIdx.x*blockDim.x + threadIdx.x;
    if(point_index >= rendered_cloud_point_num) return;

    int pose_index = cuda_cloud_pose_map[point_index];
    if (cuda_poses_occluded[pose_index])
    {
        cuda_rendered_cost[pose_index] = -1;
    }
    else
    {
        atomicAdd(&cuda_pose_point_num[pose_index], 1);
        if (cuda_knn_dist[point_index] > sensor_resolution)
        {
            atomicAdd(&cuda_rendered_cost[pose_index], 1);
        }
    }
}
bool compute_cost(
    float &sensor_resolution,
    float* knn_dist,
    int* knn_index,
    int* poses_occluded,
    int* cloud_pose_map,
    float* result_observed_cloud,
    int rendered_cloud_point_num,
    int num_poses,
    float* &rendered_cost
)
{
    // for (int i = 0; i < num_poses; i++)
    // {
    //     printf("%d ", poses_occluded[i]);
    // }
    // printf("\n");
    printf("compute_cost()\n");

    float* cuda_knn_dist;
    // float* cuda_sensor_resolution;
    int* cuda_poses_occluded;
    int* cuda_cloud_pose_map;
    float* cuda_rendered_cost;
    float* cuda_pose_point_num;

    const unsigned int size_of_float = sizeof(float);
    const unsigned int size_of_int   = sizeof(int);

    cudaMalloc(&cuda_knn_dist, rendered_cloud_point_num * size_of_float);
    cudaMalloc(&cuda_cloud_pose_map, rendered_cloud_point_num * size_of_int);
    cudaMalloc(&cuda_poses_occluded, num_poses * size_of_int);
    thrust::device_vector<float> cuda_rendered_cost_vec(num_poses, 0);
    cuda_rendered_cost = thrust::raw_pointer_cast(cuda_rendered_cost_vec.data());
    thrust::device_vector<float> cuda_pose_point_num_vec(num_poses, 0);
    cuda_pose_point_num = thrust::raw_pointer_cast(cuda_pose_point_num_vec.data());

    cudaMemcpy(cuda_knn_dist, knn_dist, rendered_cloud_point_num * size_of_float, cudaMemcpyHostToDevice);
    cudaMemcpy(cuda_cloud_pose_map, cloud_pose_map, rendered_cloud_point_num * size_of_int, cudaMemcpyHostToDevice);
    cudaMemcpy(cuda_poses_occluded, poses_occluded, num_poses * size_of_int, cudaMemcpyHostToDevice);
    // cudaMemcpy(cuda_sensor_resolution, &sensor_resolution, size_of_float, cudaMemcpyHostToDevice);
    // cudaMemset(cuda_rendered_cost, 0, num_poses * size_of_int);

    const size_t threadsPerBlock = 256;
    dim3 numBlocks((rendered_cloud_point_num + threadsPerBlock - 1) / threadsPerBlock, 1);
    compute_render_cost<<<numBlocks, threadsPerBlock>>>(
        cuda_knn_dist,
        cuda_cloud_pose_map,
        cuda_poses_occluded,
        cuda_rendered_cost,
        sensor_resolution,
        rendered_cloud_point_num,
        cuda_pose_point_num
    );

    if (cudaGetLastError() != cudaSuccess) {
        printf("ERROR: Unable to execute kernel\n");
        cudaFree(cuda_knn_dist);
        cudaFree(cuda_cloud_pose_map); 
        cudaFree(cuda_poses_occluded); 
        cudaFree(cuda_rendered_cost); 
        return false;
    }

    thrust::transform(
        cuda_rendered_cost_vec.begin(), cuda_rendered_cost_vec.end(), 
        cuda_pose_point_num_vec.begin(), cuda_rendered_cost_vec.begin(), 
        thrust::divides<float>()
    );
    thrust::device_vector<float> rendered_multiplier_val(num_poses, 100);
    thrust::transform(
        cuda_rendered_cost_vec.begin(), cuda_rendered_cost_vec.end(), 
        rendered_multiplier_val.begin(), cuda_rendered_cost_vec.begin(), 
        thrust::multiplies<float>()
    );
    rendered_cost = (float*) malloc(num_poses * size_of_float);
    cudaMemcpy(rendered_cost, cuda_rendered_cost, num_poses * size_of_float, cudaMemcpyDeviceToHost);

    // for (int i = 0; i < num_poses; i++)
    // {
    //     printf("%f ", rendered_cost[i]);
    // }
    // printf("\n");

    printf("compute_cost() done\n");
    cudaFree(cuda_knn_dist);
    cudaFree(cuda_cloud_pose_map); 
    cudaFree(cuda_poses_occluded); 
    // cudaFree(cuda_rendered_cost); 
    return true;
}
bool knn_cuda_global(const float * ref,
                     int           ref_nb,
                     const float * query,
                     int           query_nb,
                     int           dim,
                     int           k,
                     float *       knn_dist,
                     int *         knn_index) {

    // Constants
    const unsigned int size_of_float = sizeof(float);
    const unsigned int size_of_int   = sizeof(int);

    // Return variables
    cudaError_t err0, err1, err2, err3;

    // Check that we have at least one CUDA device 
    int nb_devices;
    err0 = cudaGetDeviceCount(&nb_devices);
    if (err0 != cudaSuccess || nb_devices == 0) {
        printf("ERROR: No CUDA device found\n");
        return false;
    }

    // Select the first CUDA device as default
    err0 = cudaSetDevice(0);
    if (err0 != cudaSuccess) {
        printf("ERROR: Cannot set the chosen CUDA device\n");
        return false;
    }

    // Allocate global memory
    float * ref_dev   = NULL;
    float * query_dev = NULL;
    float * dist_dev  = NULL;
    int   * index_dev = NULL;
    size_t  ref_pitch_in_bytes;
    size_t  query_pitch_in_bytes;
    size_t  dist_pitch_in_bytes;
    size_t  index_pitch_in_bytes;
    err0 = cudaMallocPitch((void**)&ref_dev,   &ref_pitch_in_bytes,   ref_nb   * size_of_float, dim);
    err1 = cudaMallocPitch((void**)&query_dev, &query_pitch_in_bytes, query_nb * size_of_float, dim);
    err2 = cudaMallocPitch((void**)&dist_dev,  &dist_pitch_in_bytes,  query_nb * size_of_float, ref_nb);
    err3 = cudaMallocPitch((void**)&index_dev, &index_pitch_in_bytes, query_nb * size_of_int,   k);
    if (err0 != cudaSuccess || err1 != cudaSuccess || err2 != cudaSuccess || err3 != cudaSuccess) {
        printf("ERROR: Memory allocation error\n");
        cudaFree(ref_dev);
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev); 
        return false;
    }

    // Deduce pitch values
    size_t ref_pitch   = ref_pitch_in_bytes   / size_of_float;
    size_t query_pitch = query_pitch_in_bytes / size_of_float;
    size_t dist_pitch  = dist_pitch_in_bytes  / size_of_float;
    size_t index_pitch = index_pitch_in_bytes / size_of_int;

    // Check pitch values
    if (query_pitch != dist_pitch || query_pitch != index_pitch) {
        printf("ERROR: Invalid pitch value\n");
        cudaFree(ref_dev);
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev); 
        return false; 
    }

    // Copy reference and query data from the host to the device
    err0 = cudaMemcpy2D(ref_dev,   ref_pitch_in_bytes,   ref,   ref_nb * size_of_float,   ref_nb * size_of_float,   dim, cudaMemcpyHostToDevice);
    err1 = cudaMemcpy2D(query_dev, query_pitch_in_bytes, query, query_nb * size_of_float, query_nb * size_of_float, dim, cudaMemcpyHostToDevice);
    if (err0 != cudaSuccess || err1 != cudaSuccess) {
        printf("ERROR: Unable to copy data from host to device\n");
        cudaFree(ref_dev);
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev); 
        return false; 
    }

    // Compute the squared Euclidean distances
    dim3 block0(BLOCK_DIM, BLOCK_DIM, 1);
    dim3 grid0(query_nb / BLOCK_DIM, ref_nb / BLOCK_DIM, 1);
    if (query_nb % BLOCK_DIM != 0) grid0.x += 1;
    if (ref_nb   % BLOCK_DIM != 0) grid0.y += 1;
    compute_distances<<<grid0, block0>>>(ref_dev, ref_nb, ref_pitch, query_dev, query_nb, query_pitch, dim, dist_dev);
    if (cudaGetLastError() != cudaSuccess) {
        printf("ERROR: Unable to execute kernel\n");
        cudaFree(ref_dev);
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev); 
        return false;
    }

    // Sort the distances with their respective indexes
    dim3 block1(256, 1, 1);
    dim3 grid1(query_nb / 256, 1, 1);
    if (query_nb % 256 != 0) grid1.x += 1;
    modified_insertion_sort<<<grid1, block1>>>(dist_dev, dist_pitch, index_dev, index_pitch, query_nb, ref_nb, k);
    if (cudaGetLastError() != cudaSuccess) {
        printf("ERROR: Unable to execute kernel\n");
        cudaFree(ref_dev);
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev); 
        return false;
    }

    // Compute the square root of the k smallest distances
    dim3 block2(16, 16, 1);
    dim3 grid2(query_nb / 16, k / 16, 1);
    if (query_nb % 16 != 0) grid2.x += 1;
    if (k % 16 != 0)        grid2.y += 1;
    compute_sqrt<<<grid2, block2>>>(dist_dev, query_nb, query_pitch, k);	
    if (cudaGetLastError() != cudaSuccess) {
        printf("ERROR: Unable to execute kernel\n");
        cudaFree(ref_dev);
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev); 
        return false;
    }

    // Copy k smallest distances / indexes from the device to the host
    err0 = cudaMemcpy2D(knn_dist,  query_nb * size_of_float, dist_dev,  dist_pitch_in_bytes,  query_nb * size_of_float, k, cudaMemcpyDeviceToHost);
    err1 = cudaMemcpy2D(knn_index, query_nb * size_of_int,   index_dev, index_pitch_in_bytes, query_nb * size_of_int,   k, cudaMemcpyDeviceToHost);
    if (err0 != cudaSuccess || err1 != cudaSuccess) {
        printf("ERROR: Unable to copy data from device to host\n");
        cudaFree(ref_dev);
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev); 
        return false; 
    }

    // Memory clean-up
    cudaFree(ref_dev);
    cudaFree(query_dev);
    cudaFree(dist_dev);
    cudaFree(index_dev); 

    return true;
}


bool knn_cuda_texture(const float * ref,
                      int           ref_nb,
                      const float * query,
                      int           query_nb,
                      int           dim,
                      int           k,
                      float *       knn_dist,
                      int *         knn_index) {

    // Constants
    unsigned int size_of_float = sizeof(float);
    unsigned int size_of_int   = sizeof(int);   

    // Return variables
    cudaError_t err0, err1, err2;

    // Check that we have at least one CUDA device 
    int nb_devices;
    err0 = cudaGetDeviceCount(&nb_devices);
    if (err0 != cudaSuccess || nb_devices == 0) {
        printf("ERROR: No CUDA device found\n");
        return false;
    }

    // Select the first CUDA device as default
    err0 = cudaSetDevice(0);
    if (err0 != cudaSuccess) {
        printf("ERROR: Cannot set the chosen CUDA device\n");
        return false;
    }

    // Allocate global memory
    float * query_dev = NULL;
    float * dist_dev  = NULL;
    int *   index_dev = NULL;
    size_t  query_pitch_in_bytes;
    size_t  dist_pitch_in_bytes;
    size_t  index_pitch_in_bytes;
    err0 = cudaMallocPitch((void**)&query_dev, &query_pitch_in_bytes, query_nb * size_of_float, dim);
    err1 = cudaMallocPitch((void**)&dist_dev,  &dist_pitch_in_bytes,  query_nb * size_of_float, ref_nb);
    err2 = cudaMallocPitch((void**)&index_dev, &index_pitch_in_bytes, query_nb * size_of_int,   k);
    if (err0 != cudaSuccess || err1 != cudaSuccess || err2 != cudaSuccess) {
        printf("ERROR: Memory allocation error (cudaMallocPitch)\n");
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev); 
        return false;
    }

    // Deduce pitch values
    size_t query_pitch = query_pitch_in_bytes / size_of_float;
    size_t dist_pitch  = dist_pitch_in_bytes  / size_of_float;
    size_t index_pitch = index_pitch_in_bytes / size_of_int;

    // Check pitch values
    if (query_pitch != dist_pitch || query_pitch != index_pitch) {
        printf("ERROR: Invalid pitch value\n");
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev); 
        return false; 
    }

    // Copy query data from the host to the device
    err0 = cudaMemcpy2D(query_dev, query_pitch_in_bytes, query, query_nb * size_of_float, query_nb * size_of_float, dim, cudaMemcpyHostToDevice);
    if (err0 != cudaSuccess) {
        printf("ERROR: Unable to copy data from host to device\n");
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev);        
        return false; 
    }

    // Allocate CUDA array for reference points
    cudaArray* ref_array_dev = NULL;
    cudaChannelFormatDesc channel_desc = cudaCreateChannelDesc(32, 0, 0, 0, cudaChannelFormatKindFloat);
    err0 = cudaMallocArray(&ref_array_dev, &channel_desc, ref_nb, dim);
    if (err0 != cudaSuccess) {
        printf("ERROR: Memory allocation error (cudaMallocArray)\n");
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev);
        return false; 
    }

    // Copy reference points from host to device
    err0 = cudaMemcpyToArray(ref_array_dev, 0, 0, ref, ref_nb * size_of_float * dim, cudaMemcpyHostToDevice);
    if (err0 != cudaSuccess) {
        printf("ERROR: Unable to copy data from host to device\n");
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev);
        cudaFreeArray(ref_array_dev);
        return false; 
    }

    // Resource descriptor
    struct cudaResourceDesc res_desc;
    memset(&res_desc, 0, sizeof(res_desc));
    res_desc.resType         = cudaResourceTypeArray;
    res_desc.res.array.array = ref_array_dev;

    // Texture descriptor
    struct cudaTextureDesc tex_desc;
    memset(&tex_desc, 0, sizeof(tex_desc));
    tex_desc.addressMode[0]   = cudaAddressModeClamp;
    tex_desc.addressMode[1]   = cudaAddressModeClamp;
    tex_desc.filterMode       = cudaFilterModePoint;
    tex_desc.readMode         = cudaReadModeElementType;
    tex_desc.normalizedCoords = 0;

    // Create the texture
    cudaTextureObject_t ref_tex_dev = 0;
    err0 = cudaCreateTextureObject(&ref_tex_dev, &res_desc, &tex_desc, NULL);
    if (err0 != cudaSuccess) {
        printf("ERROR: Unable to create the texture\n");
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev);
        cudaFreeArray(ref_array_dev);
        return false; 
    }

    // Compute the squared Euclidean distances
    dim3 block0(16, 16, 1);
    dim3 grid0(query_nb / 16, ref_nb / 16, 1);
    if (query_nb % 16 != 0) grid0.x += 1;
    if (ref_nb   % 16 != 0) grid0.y += 1;
    compute_distance_texture<<<grid0, block0>>>(ref_tex_dev, ref_nb, query_dev, query_nb, query_pitch, dim, dist_dev);
    if (cudaGetLastError() != cudaSuccess) {
        printf("ERROR: Unable to execute kernel\n");
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev);
        cudaFreeArray(ref_array_dev);
        cudaDestroyTextureObject(ref_tex_dev);
        return false;
    }

    // Sort the distances with their respective indexes
    dim3 block1(256, 1, 1);
    dim3 grid1(query_nb / 256, 1, 1);
    if (query_nb % 256 != 0) grid1.x += 1;
    modified_insertion_sort<<<grid1, block1>>>(dist_dev, dist_pitch, index_dev, index_pitch, query_nb, ref_nb, k);
    if (cudaGetLastError() != cudaSuccess) {
        printf("ERROR: Unable to execute kernel\n");
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev);
        cudaFreeArray(ref_array_dev);
        cudaDestroyTextureObject(ref_tex_dev);
        return false;
    }

    // Compute the square root of the k smallest distances
    dim3 block2(16, 16, 1);
    dim3 grid2(query_nb / 16, k / 16, 1);
    if (query_nb % 16 != 0) grid2.x += 1;
    if (k % 16 != 0)        grid2.y += 1;
    compute_sqrt<<<grid2, block2>>>(dist_dev, query_nb, query_pitch, k);	
    if (cudaGetLastError() != cudaSuccess) {
        printf("ERROR: Unable to execute kernel\n");
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev);
        cudaFreeArray(ref_array_dev);
        cudaDestroyTextureObject(ref_tex_dev);
        return false;
    }

    // Copy k smallest distances / indexes from the device to the host
    err0 = cudaMemcpy2D(knn_dist,  query_nb * size_of_float, dist_dev,  dist_pitch_in_bytes,  query_nb * size_of_float, k, cudaMemcpyDeviceToHost);
    err1 = cudaMemcpy2D(knn_index, query_nb * size_of_int,   index_dev, index_pitch_in_bytes, query_nb * size_of_int,   k, cudaMemcpyDeviceToHost);
    if (err0 != cudaSuccess || err1 != cudaSuccess) {
        printf("ERROR: Unable to copy data from device to host\n");
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev);
        cudaFreeArray(ref_array_dev);
        cudaDestroyTextureObject(ref_tex_dev);
        return false; 
    }

    // Memory clean-up
    cudaFree(query_dev);
    cudaFree(dist_dev);
    cudaFree(index_dev);
    cudaFreeArray(ref_array_dev);
    cudaDestroyTextureObject(ref_tex_dev);

    return true;
}


bool knn_cublas(const float * ref,
                int           ref_nb,
                const float * query,
                int           query_nb,
                int           dim, 
                int           k, 
                float *       knn_dist,
                int *         knn_index) {

    // Constants
    const unsigned int size_of_float = sizeof(float);
    const unsigned int size_of_int   = sizeof(int);

    // Return variables
    cudaError_t  err0, err1, err2, err3, err4, err5;

    // Check that we have at least one CUDA device 
    int nb_devices;
    err0 = cudaGetDeviceCount(&nb_devices);
    if (err0 != cudaSuccess || nb_devices == 0) {
        printf("ERROR: No CUDA device found\n");
        return false;
    }

    // Select the first CUDA device as default
    err0 = cudaSetDevice(0);
    if (err0 != cudaSuccess) {
        printf("ERROR: Cannot set the chosen CUDA device\n");
        return false;
    }

    // Initialize CUBLAS
    cublasInit();

    // Allocate global memory
    float * ref_dev        = NULL;
    float * query_dev      = NULL;
    float * dist_dev       = NULL;
    int   * index_dev      = NULL;
    float * ref_norm_dev   = NULL;
    float * query_norm_dev = NULL;
    size_t  ref_pitch_in_bytes;
    size_t  query_pitch_in_bytes;
    size_t  dist_pitch_in_bytes;
    size_t  index_pitch_in_bytes;
    err0 = cudaMallocPitch((void**)&ref_dev,   &ref_pitch_in_bytes,   ref_nb   * size_of_float, dim);
    err1 = cudaMallocPitch((void**)&query_dev, &query_pitch_in_bytes, query_nb * size_of_float, dim);
    err2 = cudaMallocPitch((void**)&dist_dev,  &dist_pitch_in_bytes,  query_nb * size_of_float, ref_nb);
    err3 = cudaMallocPitch((void**)&index_dev, &index_pitch_in_bytes, query_nb * size_of_int,   k);
    err4 = cudaMalloc((void**)&ref_norm_dev,   ref_nb   * size_of_float);
    err5 = cudaMalloc((void**)&query_norm_dev, query_nb * size_of_float);
    if (err0 != cudaSuccess || err1 != cudaSuccess || err2 != cudaSuccess || err3 != cudaSuccess || err4 != cudaSuccess || err5 != cudaSuccess) {
        printf("ERROR: Memory allocation error\n");
        cudaFree(ref_dev);
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev);
        cudaFree(ref_norm_dev);
        cudaFree(query_norm_dev);
        cublasShutdown();
        return false;
    }

    // Deduce pitch values
    size_t ref_pitch   = ref_pitch_in_bytes   / size_of_float;
    size_t query_pitch = query_pitch_in_bytes / size_of_float;
    size_t dist_pitch  = dist_pitch_in_bytes  / size_of_float;
    size_t index_pitch = index_pitch_in_bytes / size_of_int;

    // Check pitch values
    if (query_pitch != dist_pitch || query_pitch != index_pitch) {
        printf("ERROR: Invalid pitch value\n");
        cudaFree(ref_dev);
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev);
        cudaFree(ref_norm_dev);
        cudaFree(query_norm_dev);
        cublasShutdown();
        return false; 
    }

    // Copy reference and query data from the host to the device
    err0 = cudaMemcpy2D(ref_dev,   ref_pitch_in_bytes,   ref,   ref_nb * size_of_float,   ref_nb * size_of_float,   dim, cudaMemcpyHostToDevice);
    err1 = cudaMemcpy2D(query_dev, query_pitch_in_bytes, query, query_nb * size_of_float, query_nb * size_of_float, dim, cudaMemcpyHostToDevice);
    if (err0 != cudaSuccess || err1 != cudaSuccess) {
        printf("ERROR: Unable to copy data from host to device\n");
        cudaFree(ref_dev);
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev);
        cudaFree(ref_norm_dev);
        cudaFree(query_norm_dev);
        cublasShutdown();
        return false; 
    }

    // Compute the squared norm of the reference points
    dim3 block0(256, 1, 1);
    dim3 grid0(ref_nb / 256, 1, 1);
    if (ref_nb % 256 != 0) grid0.x += 1;
    compute_squared_norm<<<grid0, block0>>>(ref_dev, ref_nb, ref_pitch, dim, ref_norm_dev);
    if (cudaGetLastError() != cudaSuccess) {
        printf("ERROR: Unable to execute kernel\n");
        cudaFree(ref_dev);
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev);
        cudaFree(ref_norm_dev);
        cudaFree(query_norm_dev);
        cublasShutdown();
        return false;
    }

    // Compute the squared norm of the query points
    dim3 block1(256, 1, 1);
    dim3 grid1(query_nb / 256, 1, 1);
    if (query_nb % 256 != 0) grid1.x += 1;
    compute_squared_norm<<<grid1, block1>>>(query_dev, query_nb, query_pitch, dim, query_norm_dev);
    if (cudaGetLastError() != cudaSuccess) {
        printf("ERROR: Unable to execute kernel\n");
        cudaFree(ref_dev);
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev);
        cudaFree(ref_norm_dev);
        cudaFree(query_norm_dev);
        cublasShutdown();
        return false;
    }

    // Computation of query*transpose(reference)
    cublasSgemm('n', 't', (int)query_pitch, (int)ref_pitch, dim, (float)-2.0, query_dev, query_pitch, ref_dev, ref_pitch, (float)0.0, dist_dev, query_pitch);
    if (cublasGetError() != CUBLAS_STATUS_SUCCESS) {
        printf("ERROR: Unable to execute cublasSgemm\n");
        cudaFree(ref_dev);
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev);
        cudaFree(ref_norm_dev);
        cudaFree(query_norm_dev);
        cublasShutdown();
        return false;       
    }

    // Add reference points norm
    dim3 block2(16, 16, 1);
    dim3 grid2(query_nb / 16, ref_nb / 16, 1);
    if (query_nb % 16 != 0) grid2.x += 1;
    if (ref_nb   % 16 != 0) grid2.y += 1;
    add_reference_points_norm<<<grid2, block2>>>(dist_dev, query_nb, dist_pitch, ref_nb, ref_norm_dev);
    if (cudaGetLastError() != cudaSuccess) {
        printf("ERROR: Unable to execute kernel\n");
        cudaFree(ref_dev);
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev);
        cudaFree(ref_norm_dev);
        cudaFree(query_norm_dev);
        cublasShutdown();
        return false;
    }

    // Sort each column
    modified_insertion_sort<<<grid1, block1>>>(dist_dev, dist_pitch, index_dev, index_pitch, query_nb, ref_nb, k);
    if (cudaGetLastError() != cudaSuccess) {
        printf("ERROR: Unable to execute kernel\n");
        cudaFree(ref_dev);
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev);
        cudaFree(ref_norm_dev);
        cudaFree(query_norm_dev);
        cublasShutdown();
        return false;
    }

    // Add query norm and compute the square root of the of the k first elements
    dim3 block3(16, 16, 1);
    dim3 grid3(query_nb / 16, k / 16, 1);
    if (query_nb % 16 != 0) grid3.x += 1;
    if (k        % 16 != 0) grid3.y += 1;
    add_query_points_norm_and_sqrt<<<grid3, block3>>>(dist_dev, query_nb, dist_pitch, k, query_norm_dev);
    if (cudaGetLastError() != cudaSuccess) {
        printf("ERROR: Unable to execute kernel\n");
        cudaFree(ref_dev);
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev);
        cudaFree(ref_norm_dev);
        cudaFree(query_norm_dev);
        cublasShutdown();
        return false;
    }

    // Copy k smallest distances / indexes from the device to the host
    err0 = cudaMemcpy2D(knn_dist,  query_nb * size_of_float, dist_dev,  dist_pitch_in_bytes,  query_nb * size_of_float, k, cudaMemcpyDeviceToHost);
    err1 = cudaMemcpy2D(knn_index, query_nb * size_of_int,   index_dev, index_pitch_in_bytes, query_nb * size_of_int,   k, cudaMemcpyDeviceToHost);
    if (err0 != cudaSuccess || err1 != cudaSuccess) {
        printf("ERROR: Unable to copy data from device to host\n");
        cudaFree(ref_dev);
        cudaFree(query_dev);
        cudaFree(dist_dev);
        cudaFree(index_dev);
        cudaFree(ref_norm_dev);
        cudaFree(query_norm_dev);
        cublasShutdown();
        return false; 
    }

    // Memory clean-up and CUBLAS shutdown
    cudaFree(ref_dev);
    cudaFree(query_dev);
    cudaFree(dist_dev);
    cudaFree(index_dev);
    cudaFree(ref_norm_dev);
    cudaFree(query_norm_dev);
    cublasShutdown();

    return true;
}

    /**
     * Computes the Euclidean distance between a reference point and a query point.
     *
     * @param ref          refence points
     * @param ref_nb       number of reference points
     * @param query        query points
     * @param query_nb     number of query points
     * @param dim          dimension of points
     * @param ref_index    index to the reference point to consider
     * @param query_index  index to the query point to consider
     * @return computed distance
     */
    float compute_distance(const float * ref,
                        int           ref_nb,
                        const float * query,
                        int           query_nb,
                        int           dim,
                        int           ref_index,
                        int           query_index) {
        float sum = 0.f;
        for (int d=0; d<dim; ++d) {
            const float diff = ref[d * ref_nb + ref_index] - query[d * query_nb + query_index];
            sum += diff * diff;
        }
        return sqrtf(sum);
    }


    /**
     * Gathers at the beginning of the `dist` array the k smallest values and their
     * respective index (in the initial array) in the `index` array. After this call,
     * only the k-smallest distances are available. All other distances might be lost.
     *
     * Since we only need to locate the k smallest distances, sorting the entire array
     * would not be very efficient if k is relatively small. Instead, we perform a
     * simple insertion sort by eventually inserting a given distance in the first
     * k values.
     *
     * @param dist    array containing the `length` distances
     * @param index   array containing the index of the k smallest distances
     * @param length  total number of distances
     * @param k       number of smallest distances to locate
     */
    void  modified_insertion_sort_cpu(float *dist, int *index, int length, int k){

        // Initialise the first index
        index[0] = 0;

        // Go through all points
        for (int i=1; i<length; ++i) {

            // Store current distance and associated index
            float curr_dist  = dist[i];
            int   curr_index = i;

            // Skip the current value if its index is >= k and if it's higher the k-th slready sorted mallest value
            if (i >= k && curr_dist >= dist[k-1]) {
                continue;
            }

            // Shift values (and indexes) higher that the current distance to the right
            int j = std::min(i, k-1);
            while (j > 0 && dist[j-1] > curr_dist) {
                dist[j]  = dist[j-1];
                index[j] = index[j-1];
                --j;
            }

            // Write the current distance and index at their position
            dist[j]  = curr_dist;
            index[j] = curr_index; 
        }
    }


    /*
    * For each input query point, locates the k-NN (indexes and distances) among the reference points.
    *
    * @param ref        refence points
    * @param ref_nb     number of reference points
    * @param query      query points
    * @param query_nb   number of query points
    * @param dim        dimension of points
    * @param k          number of neighbors to consider
    * @param knn_dist   output array containing the query_nb x k distances
    * @param knn_index  output array containing the query_nb x k indexes
    */
    bool knn_c(const float * ref,
            int           ref_nb,
            const float * query,
            int           query_nb,
            int           dim,
            int           k,
            float *       knn_dist,
            int *         knn_index) {

        // Allocate local array to store all the distances / indexes for a given query point 
        float * dist  = (float *) malloc(ref_nb * sizeof(float));
        int *   index = (int *)   malloc(ref_nb * sizeof(int));

        // Allocation checks
        if (!dist || !index) {
            printf("Memory allocation error\n");
            free(dist);
            free(index);
            return false;
        }

        // Process one query point at the time
        for (int i=0; i<query_nb; ++i) {

            // Compute all distances / indexes
            for (int j=0; j<ref_nb; ++j) {
                dist[j]  = compute_distance(ref, ref_nb, query, query_nb, dim, j, i);
                index[j] = j;
            }

            // Sort distances / indexes
            modified_insertion_sort_cpu(dist, index, ref_nb, k);

            // Copy k smallest distances and their associated index
            for (int j=0; j<k; ++j) {
                knn_dist[j * query_nb + i]  = dist[j];
                knn_index[j * query_nb + i] = index[j];
            }
        }

        // Memory clean-up
        free(dist);
        free(index);

        return true;

    }


    /**
     * Test an input k-NN function implementation by verifying that its output
     * results (distances and corresponding indexes) are similar to the expected
     * results (ground truth).
     *
     * Since the k-NN computation might end-up in slightly different results
     * compared to the expected one depending on the considered implementation,
     * the verification consists in making sure that the accuracy is high enough.
     *
     * The tested function is ran several times in order to have a better estimate
     * of the processing time.
     *
     * @param ref            reference points
     * @param ref_nb         number of reference points
     * @param query          query points
     * @param query_nb       number of query points
     * @param dim            dimension of reference and query points
     * @param k              number of neighbors to consider
     * @param gt_knn_dist    ground truth distances
     * @param gt_knn_index   ground truth indexes
     * @param knn            function to test
     * @param name           name of the function to test (for display purpose)
     * @param nb_iterations  number of iterations
     * return false in case of problem, true otherwise
     */
    bool knn_test(const float * ref,
            int           ref_nb,
            const float * query,
            int           query_nb,
            int           dim,
            int           k,
            float *       knn_dist,
            int *         knn_index) {

        // Parameters
        const float precision    = 0.001f; // distance error max
        const float min_accuracy = 0.999f; // percentage of correct values required
        

        // Compute the ground truth k-NN distances and indexes for each query point
        printf("Ground truth computation in progress...\n\n");
        if (!knn_c(ref, ref_nb, query, query_nb, dim, k, knn_dist, knn_index)) {
            // free(ref);
            // free(query);
            // free(knn_dist);
            // free(knn_index);
            return EXIT_FAILURE;
        }

        // Display k-NN function name
        // printf("- %-17s : ", name);

        // Allocate memory for computed k-NN neighbors
        float * test_knn_dist  = (float*) malloc(query_nb * k * sizeof(float));
        int   * test_knn_index = (int*)   malloc(query_nb * k * sizeof(int));

        // Allocation check
        if (!test_knn_dist || !test_knn_index) {
            printf("ALLOCATION ERROR\n");
            free(test_knn_dist);
            free(test_knn_index);
            return false;
        }

        // Start timer
        struct timeval tic;
        gettimeofday(&tic, NULL);

        // Compute k-NN several times
        for (int i=0; i<1; ++i) {
            if (!knn_cuda_global(ref, ref_nb, query, query_nb, dim, k, test_knn_dist, test_knn_index)) {
                free(test_knn_dist);
                free(test_knn_index);
                return false;
            }
        }

        // Stop timer
        struct timeval toc;
        gettimeofday(&toc, NULL);

        // Elapsed time in ms
        double elapsed_time = toc.tv_sec - tic.tv_sec;
        elapsed_time += (toc.tv_usec - tic.tv_usec) / 1000000.;

        // Verify both precisions and indexes of the k-NN values
        int nb_correct_precisions = 0;
        int nb_correct_indexes    = 0;
        for (int i=0; i<query_nb*k; ++i) {
            if (fabs(test_knn_dist[i] - knn_dist[i]) <= precision) {
                nb_correct_precisions++;
            }
            if (test_knn_index[i] == knn_index[i]) {
                nb_correct_indexes++;
            }
        }

        // Compute accuracy
        float precision_accuracy = nb_correct_precisions / ((float) query_nb * k);
        float index_accuracy     = nb_correct_indexes    / ((float) query_nb * k);

        // Display report
        if (precision_accuracy >= min_accuracy && index_accuracy >= min_accuracy ) {
            printf("PASSED in %8.5f seconds (averaged over %3d iterations)\n", elapsed_time / 1, 1);
        }
        else {
            printf("FAILED\n");
        }

        // Free memory
        free(test_knn_dist);
        free(test_knn_index);

        return true;
    }
}
