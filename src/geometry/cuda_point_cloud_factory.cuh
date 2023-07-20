#pragma once

#include <cuda.h>
#include <cuda_runtime.h>
#include <memory>
#include <thrust/device_vector.h>

#include "camera/camera_param.hpp"
#include "cuda_container/cuda_container.hpp"
#include "geometry/type.hpp"
#include "util/cuda_util.cuh"

namespace gca
{
/*this overload is only for debug, will be deleted later!*/
bool cuda_make_point_cloud(std::vector<gca::point_t> &result,
                           const gca::cuda_depth_frame &cuda_depth_container,
                           const gca::cuda_color_frame &cuda_color_container,
                           const gca::cuda_camera_param &param, float threshold_min_in_meter = 0.0,
                           float threshold_max_in_meter = 100.0);

bool cuda_make_point_cloud(thrust::device_vector<gca::point_t> &result,
                           const gca::cuda_depth_frame &cuda_depth_container,
                           const gca::cuda_color_frame &cuda_color_container,
                           const gca::cuda_camera_param &param, float threshold_min_in_meter,
                           float threshold_max_in_meter);

::cudaError_t cuda_voxel_grid_downsample(thrust::device_vector<gca::point_t> &result_points,
                                         const thrust::device_vector<gca::point_t> &src_points,
                                         const float3 &point_cloud_min_bound,
                                         const float voxel_size,
                                         const uint32_t min_points_num_in_one_voxel = 0);
} // namespace gca