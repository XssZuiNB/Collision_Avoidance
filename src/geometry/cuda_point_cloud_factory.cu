#include "cuda_point_cloud_factory.cuh"

#include "camera/camera_param.hpp"
#include "cuda_container/cuda_container.hpp"
#include "geometry/geometry_util.cuh"
#include "geometry/type.hpp"
#include "util/cuda_util.cuh"

#include <cuda.h>
#include <cuda_runtime.h>
#include <cuda_runtime_api.h>
#include <thrust/device_vector.h>
#include <thrust/transform.h>

namespace gca
{
/************************************ CUDA bilateral_filter  ************************************/

__forceinline__ __device__ static float __gaussian(float x, float sigma)
{
    return expf(-(x * x) / (sigma * sigma));
}

__forceinline__ __device__ static float __gaussian_square(float x_square, float sigma)
{
    return expf(-x_square / (sigma * sigma));
}

__forceinline__ __device__ static float __bilateral_filter(const uint16_t *input,
                                                           uint32_t input_width,
                                                           uint32_t input_height, int index_x,
                                                           int index_y, int filter_radius,
                                                           float sigma_space, float sigma_depth)
{
    float sum_weight = 0.0f;
    float sum = 0.0f;

    auto depth_value = __ldg(&input[index_y * input_width + index_x]);

    for (int dy = -filter_radius; dy <= filter_radius; ++dy)
    {
        for (int dx = -filter_radius; dx <= filter_radius; ++dx)
        {
            int nx = index_x + dx;
            int ny = index_y + dy;

            if (nx < 0 || nx >= input_width || ny < 0 || ny >= input_height)
            {
                continue;
            }

            auto neighbor = __ldg(&input[ny * input_width + nx]);
            float weight = __gaussian_square((dx * dx + dy * dy), sigma_space) *
                           __gaussian(abs(depth_value - neighbor), sigma_depth);

            sum_weight += weight;
            sum += weight * neighbor;
        }
    }

    return sum / sum_weight;
}

__forceinline__ __device__ static float __bilateral_filter(
    const uint16_t *input, uint32_t input_width, uint32_t input_height, int index_x, int index_y,
    uint16_t this_depth_data, int filter_radius, float sigma_space, float sigma_depth)
{
    float sum_weight = 0.0f;
    float sum = 0.0f;

    auto depth_data = this_depth_data;

    for (int dy = -filter_radius; dy <= filter_radius; ++dy)
    {
        for (int dx = -filter_radius; dx <= filter_radius; ++dx)
        {
            int nx = index_x + dx;
            int ny = index_y + dy;

            if (nx < 0 || nx >= input_width || ny < 0 || ny >= input_height)
            {
                continue;
            }

            auto neighbor = __ldg(&input[ny * input_width + nx]);
            if (!neighbor)
                continue;

            float weight = __gaussian_square((dx * dx + dy * dy), sigma_space) *
                           __gaussian(abs(depth_data - neighbor), sigma_depth);

            sum_weight += weight;
            sum += weight * neighbor;
        }
    }

    return sum / sum_weight;
}

__forceinline__ __device__ static float __adaptive_bilateral_filter(
    const uint16_t *input, uint32_t input_width, uint32_t input_height, float depth_scale,
    int index_x, int index_y, float threshold_min_in_meter, float threshold_max_in_meter,
    uint32_t steps_num = 5, float step_len = 0.5f, float min_filter_radius = 1.0f)
{
    auto steps = steps_num;
    auto min_filter_r = min_filter_radius;
    constexpr auto sigma_space = 8.0f;
    constexpr auto sigma_depth = 100.0f;

    auto depth_data = __ldg(&input[index_y * input_width + index_x]);

    // set filter parameter
    auto depth_value = depth_data * depth_scale;
    if (depth_value < threshold_min_in_meter || depth_value > threshold_max_in_meter)
    {
        return depth_data;
    }

    auto step = static_cast<uint32_t>((depth_value - threshold_min_in_meter) / step_len);
    if (step > steps)
        step = steps;

    auto new_sigma_space = sigma_space + step * 1.0f;
    auto new_sigma_depth = sigma_depth + step * 10.0f;
    auto filter_r = min_filter_r * step;

    return __bilateral_filter(input, input_width, input_height, index_x, index_y, depth_data,
                              filter_r, new_sigma_space, new_sigma_depth);
}

/************************************** Filter out eddges ***************************************/
/* See: https://github.com/raluca-scona/Joint-VO-SF/blob/master/segmentation_background.cpp     */
/* line 56 to 69. NOT USED!!! For realsense nothing can fix the noise... */
/*
__forceinline__ __device__ static float __edges_filter(const uint16_t *depth, uint32_t input_width,
                                                       uint32_t input_height, int index_x,
                                                       int index_y, float depth_scale)
{
    static constexpr float threshold_edge = 0.3f;

    auto depth_value = __ldg(&depth[index_y * input_width + index_x]);

    if (index_x < 1 || index_x > input_width - 2 || index_y < 1 || index_y > input_height - 2)
    {
        return depth_value * depth_scale;
    }

    const float sum_diff_depth =
        abs(__ldg(&depth[index_y * input_width + (index_x - 1)]) - depth_value) +
        abs(__ldg(&depth[index_y * input_width + (index_x + 1)]) - depth_value) +
        abs(__ldg(&depth[(index_y - 1) * input_width + index_x]) - depth_value) +
        abs(__ldg(&depth[(index_y + 1) * input_width + index_x]) - depth_value);

    return (sum_diff_depth * depth_scale < threshold_edge) * depth_value * depth_scale;
}
*/

/****************** Create point cloud from rgbd, include invalid point remove ******************/

__forceinline__ __device__ static void __transform_point_to_point(float to_point[3],
                                                                  const float from_point[3],
                                                                  const gca::extrinsics &extrin)
{
    to_point[0] = extrin.rotation[0] * from_point[0] + extrin.rotation[3] * from_point[1] +
                  extrin.rotation[6] * from_point[2] + extrin.translation[0];
    to_point[1] = extrin.rotation[1] * from_point[0] + extrin.rotation[4] * from_point[1] +
                  extrin.rotation[7] * from_point[2] + extrin.translation[1];
    to_point[2] = extrin.rotation[2] * from_point[0] + extrin.rotation[5] * from_point[1] +
                  extrin.rotation[8] * from_point[2] + extrin.translation[2];
}

__forceinline__ __device__ static void __depth_uv_to_xyz(const float uv[2], const float depth,
                                                         float xyz[3],
                                                         const gca::intrinsics &depth_intrin)
{
    auto z = depth;
    xyz[2] = z;
    xyz[0] = (uv[0] - depth_intrin.cx) * z / depth_intrin.fx;
    xyz[1] = (uv[1] - depth_intrin.cy) * z / depth_intrin.fy;
}

__forceinline__ __device__ static void __xyz_to_color_uv(const float xyz[3], float uv[2],
                                                         const gca::intrinsics &color_intrin)
{
    uv[0] = (xyz[0] * color_intrin.fx / xyz[2]) + color_intrin.cx;
    uv[1] = (xyz[1] * color_intrin.fy / xyz[2]) + color_intrin.cy;
}

template <bool if_bilateral_filter>
__global__ static void __kernel_make_pointcloud_Z16_BGR8(
    gca::point_t *point_set_out, const uint32_t width, const uint32_t height,
    const uint16_t *depth_frame_data, const uint8_t *color_frame_data,
    const gca::intrinsics *depth_intrin_ptr, const gca::intrinsics *color_intrin_ptr,
    const gca::extrinsics *depth_to_color_extrin_ptr, const float depth_scale, float threshold_min,
    float threshold_max)
{

    __shared__ gca::intrinsics depth_intrin_shared;
    __shared__ gca::intrinsics color_intrin_shared;
    __shared__ gca::extrinsics depth_to_color_extrin_shared;

    if (threadIdx.x == 0 && threadIdx.y == 0)
    {
        depth_intrin_shared = *depth_intrin_ptr;
        color_intrin_shared = *color_intrin_ptr;
        depth_to_color_extrin_shared = *depth_to_color_extrin_ptr;
    }

    __syncthreads();

    auto depth_x = blockIdx.x * blockDim.x + threadIdx.x;
    auto depth_y = blockIdx.y * blockDim.y + threadIdx.y;
    auto depth_pixel_index = depth_y * width + depth_x;

    if (depth_x < width && depth_y < height)
    {
        float depth_value;
        if (if_bilateral_filter)
            depth_value =
                __adaptive_bilateral_filter(depth_frame_data, width, height, depth_scale, depth_x,
                                            depth_y, threshold_min, threshold_max) *
                depth_scale;
        else
            depth_value = __ldg(&depth_frame_data[depth_pixel_index]) * depth_scale;

        if (depth_value < threshold_min || depth_value > threshold_max)
        {
            point_set_out[depth_pixel_index].property = gca::point_property::invalid;
            return;
        }

        float depth_uv[2] = {depth_x - 0.5f, depth_y - 0.5f};
        float depth_xyz[3];
        __depth_uv_to_xyz(depth_uv, depth_value, depth_xyz, depth_intrin_shared);

        float color_xyz[3];
        __transform_point_to_point(color_xyz, depth_xyz, depth_to_color_extrin_shared);

        float color_uv[2];
        __xyz_to_color_uv(color_xyz, color_uv, color_intrin_shared);

        const int target_x = static_cast<int>(color_uv[0] + 0.5f);
        const int target_y = static_cast<int>(color_uv[1] + 0.5f);
        if (target_x < 0 || target_x >= width || target_y < 0 || target_y >= height)
        {
            point_set_out[depth_pixel_index].property = gca::point_property::invalid;
            return;
        }

        gca::point_t p;

        p.coordinates.x = depth_xyz[0];
        p.coordinates.y = depth_xyz[1];
        p.coordinates.z = depth_xyz[2];

        const int color_index = 3 * (target_y * width + target_x);

        float scale = 1.0f / 255.0f;
        p.color.b = float(__ldg(&color_frame_data[color_index + 0])) * scale;
        p.color.g = float(__ldg(&color_frame_data[color_index + 1])) * scale;
        p.color.r = float(__ldg(&color_frame_data[color_index + 2])) * scale;

        p.property = gca::point_property::inactive;

        point_set_out[depth_pixel_index] = p;
    }
}

::cudaError_t cuda_make_point_cloud(thrust::device_vector<gca::point_t> &result,
                                    const gca::cuda_depth_frame &cuda_depth_container,
                                    const gca::cuda_color_frame &cuda_color_container,
                                    const gca::cuda_camera_param &param,
                                    float threshold_min_in_meter, float threshold_max_in_meter)
{
    auto depth_intrin_ptr = param.get_depth_intrinsics_ptr();
    auto color_intrin_ptr = param.get_color_intrinsics_ptr();
    auto depth2color_extrin_ptr = param.get_depth2color_extrinsics_ptr();
    auto width = param.get_width();
    auto height = param.get_height();
    auto depth_scale = param.get_depth_scale();
    auto depth_frame_cuda_ptr =
        thrust::raw_pointer_cast(cuda_depth_container.get_depth_frame_vec().data());
    auto color_frame_cuda_ptr =
        thrust::raw_pointer_cast(cuda_color_container.get_color_frame_vec().data());

    if (!depth_intrin_ptr || !color_intrin_ptr || !depth2color_extrin_ptr || !width || !height)
        return ::cudaErrorInvalidValue;

    if (depth_scale <= 0.0f)
        return ::cudaErrorInvalidValue;

    auto depth_pixel_count = width * height;
    result.resize(depth_pixel_count);

    dim3 threads(32, 32);
    dim3 depth_blocks(div_up(width, threads.x), div_up(height, threads.y));

    __kernel_make_pointcloud_Z16_BGR8<true><<<depth_blocks, threads>>>(
        thrust::raw_pointer_cast(result.data()), width, height, depth_frame_cuda_ptr,
        color_frame_cuda_ptr, depth_intrin_ptr, color_intrin_ptr, depth2color_extrin_ptr,
        depth_scale, threshold_min_in_meter, threshold_max_in_meter);

    auto err = cudaDeviceSynchronize();
    if (err != ::cudaSuccess)
        return err;

    remove_invalid_points(result);
    err = cudaGetLastError();
    if (err != ::cudaSuccess)
        return err;

    return ::cudaSuccess;
}
} // namespace gca
