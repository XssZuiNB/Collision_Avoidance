#include "point_cloud.hpp"

#include "geometry/cuda_clustering.cuh"
#include "geometry/cuda_estimate_normals.cuh"
#include "geometry/cuda_nn_search.cuh"
#include "geometry/cuda_point_cloud_factory.cuh"
#include "geometry/cuda_voxel_grid_down_sample.cuh"
#include "geometry/geometry_util.cuh"
#include "util/console_color.hpp"

#include <memory>
#include <vector>

#include <cuda_runtime_api.h>
#include <thrust/copy.h>
#include <thrust/device_vector.h>
#include <thrust/host_vector.h>
#include <thrust/pair.h>

namespace gca
{
point_cloud::point_cloud(size_t n_points)
    : m_points(n_points)
    , m_normals(n_points)
{
}

point_cloud::point_cloud(const point_cloud &other)
    : m_points(other.m_points)
    , m_normals(other.m_normals)
    , m_has_normals(other.m_has_normals)
    , m_has_bound(other.m_has_bound)
    , m_min_bound(other.m_min_bound)
    , m_max_bound(other.m_max_bound)
{
}

point_cloud &point_cloud::operator=(const point_cloud &other)
{
    m_points = other.m_points;
    m_normals = other.m_normals;
    m_has_normals = other.m_has_normals;
    m_has_bound = other.m_has_bound;
    m_min_bound = other.m_min_bound;
    m_max_bound = other.m_max_bound;

    return *this;
}

std::vector<gca::point_t> point_cloud::download() const
{
    std::vector<gca::point_t> temp(m_points.size());
    thrust::copy(m_points.begin(), m_points.end(), temp.begin());
    return temp;
}
void point_cloud::download(std::vector<gca::point_t> &dst) const
{
    dst.resize(m_points.size());
    thrust::copy(m_points.begin(), m_points.end(), dst.begin());
}
std::vector<float3> point_cloud::download_normals() const
{
    std::vector<float3> temp(m_normals.size());
    thrust::copy(m_normals.begin(), m_normals.end(), temp.begin());
    return temp;
}

void point_cloud::transform(const mat4x4 &trans_mat)
{
    cuda_transform_point(m_points, trans_mat);
    if (m_has_bound)
    {
        m_has_bound = false;
        compute_min_max_bound();
    }
    if (m_has_normals)
    {
        cuda_transform_normals(m_normals, trans_mat);
    }
}

void point_cloud::compute_min_max_bound() const
{
    if (m_has_bound)
    {
        return;
    }

    auto min_max_bound = cuda_compute_min_max_bound(m_points);

    m_min_bound = min_max_bound.first;
    m_max_bound = min_max_bound.second;
    m_has_bound = true;
    return;
}

const float3 &point_cloud::get_min_bound() const
{
    compute_min_max_bound();
    return m_min_bound;
}

const float3 &point_cloud::get_max_bound() const
{
    compute_min_max_bound();
    return m_max_bound;
}

bool point_cloud::estimate_normals(float search_radius)
{
    if (m_has_normals)
        return true;

    if (!m_has_bound)
    {
        compute_min_max_bound();
    }

    auto padding = 1.5 * search_radius;
    const auto grid_cells_min_bound =
        make_float3(m_min_bound.x - padding, m_min_bound.y - padding, m_min_bound.z - padding);

    const auto grid_cells_max_bound =
        make_float3(m_max_bound.x + padding, m_max_bound.y + padding, m_max_bound.z + padding);

    if (search_radius * std::numeric_limits<int>::max() <
        max(max(grid_cells_max_bound.x - grid_cells_min_bound.x,
                grid_cells_max_bound.y - grid_cells_min_bound.y),
            grid_cells_max_bound.z - grid_cells_min_bound.z))
    {
        std::cout << YELLOW << "Radius is too small!" << std::endl;
        return false;
    }

    auto err = cuda_estimate_normals(m_normals, m_points, grid_cells_min_bound,
                                     grid_cells_max_bound, search_radius);
    if (err != ::cudaSuccess)
    {
        std::cout << YELLOW << "Estimate normals failed! \n" << std::endl;
        return false;
    }

    m_has_normals = true;
    return true;
}

const thrust::device_vector<float3> &point_cloud::get_normals() const
{
    if (m_has_normals)
    {
        return m_normals;
    }
    std::cout << YELLOW << "Estimate normals first! Invalid normals returned! \n" << std::endl;
    return m_normals;
}

const thrust::device_vector<gca::point_t> &point_cloud::get_points() const
{
    return m_points;
}

std::shared_ptr<point_cloud> point_cloud::voxel_grid_down_sample(float voxel_size)
{
    if (voxel_size <= 0.0f)
    {
        std::cout << YELLOW << "Voxel size is less than 0, nullptr returned!" << std::endl;
        return nullptr;
    }

    if (!m_has_bound)
    {
        compute_min_max_bound();
    }

    auto bound_diff = m_max_bound - m_min_bound;

    if (voxel_size * std::numeric_limits<int>::max() <
        max(max(bound_diff.x, bound_diff.y), bound_diff.z))
    {
        std::cout << YELLOW << "Voxel size is too small, nullptr returned!" << std::endl;
        return nullptr;
    }

    auto pts = cuda_voxel_grid_downsample(m_points, m_min_bound, voxel_size);

    auto result = std::make_shared<point_cloud>();
    result->m_points.swap(pts);
    result->m_has_bound = true;
    result->m_min_bound = m_min_bound;
    result->m_max_bound = m_max_bound;

    return result;
}

std::shared_ptr<point_cloud> point_cloud::radius_outlier_removal(
    float radius, gca::counter_t min_neighbors_in_radius)
{
    auto output = std::make_shared<point_cloud>(m_points.size());

    if (radius <= 0.0)
    {
        std::cout << YELLOW << "Radius is less than 0, a empty point cloud returned!" << std::endl;
        return output;
    }

    if (!m_has_bound)
    {
        compute_min_max_bound();
    }

    auto grid_cell_side_len = 2.0f * radius;
    auto padding = 1.5f * grid_cell_side_len;
    const auto grid_cells_min_bound =
        make_float3(m_min_bound.x - padding, m_min_bound.y - padding, m_min_bound.z - padding);

    const auto grid_cells_max_bound =
        make_float3(m_max_bound.x + padding, m_max_bound.y + padding, m_max_bound.z + padding);

    if (grid_cell_side_len * std::numeric_limits<int>::max() <
        max(max(grid_cells_max_bound.x - grid_cells_min_bound.x,
                grid_cells_max_bound.y - grid_cells_min_bound.y),
            grid_cells_max_bound.z - grid_cells_min_bound.z))
    {
        std::cout << YELLOW << "Radius is too small, a empty point cloud returned!" << std::endl;
        return output;
    }

    auto err = cuda_grid_radius_outliers_removal(output->m_points, m_points, grid_cells_min_bound,
                                                 grid_cells_max_bound, grid_cell_side_len, radius,
                                                 min_neighbors_in_radius);
    if (err != ::cudaSuccess)
    {
        std::cout << YELLOW << "Radius outlier removal failed, a invalid point cloud returned ! \n "
                  << std::endl;
        return output;
    }

    return output;
}

std::pair<std::shared_ptr<std::vector<gca::index_t>>, gca::counter_t> point_cloud::
    euclidean_clustering(const float cluster_tolerance, const gca::counter_t min_cluster_size,
                         const gca::counter_t max_cluster_size)
{
    auto cluster_of_point = std::make_shared<std::vector<gca::index_t>>(m_points.size());

    if (cluster_tolerance <= 0.0f)
    {
        std::cout << YELLOW << "Clustering tolerance is less than 0, a empty result returned!"
                  << std::endl;
        return std::make_pair(cluster_of_point, 0);
    }

    if (!m_has_bound)
    {
        compute_min_max_bound();
    }

    auto grid_cell_side_len = cluster_tolerance;
    auto padding = 1.5 * grid_cell_side_len;
    const auto grid_cells_min_bound =
        make_float3(m_min_bound.x - padding, m_min_bound.y - padding, m_min_bound.z - padding);

    const auto grid_cells_max_bound =
        make_float3(m_max_bound.x + padding, m_max_bound.y + padding, m_max_bound.z + padding);

    if (grid_cell_side_len * std::numeric_limits<int>::max() <
        max(max(grid_cells_max_bound.x - grid_cells_min_bound.x,
                grid_cells_max_bound.y - grid_cells_min_bound.y),
            grid_cells_max_bound.z - grid_cells_min_bound.z))
    {
        std::cout << YELLOW << "Cluster tolerance is too small, a empty result returned!"
                  << std::endl;
        return std::make_pair(cluster_of_point, 0);
    }

    gca::counter_t n_clusters;

    auto err = cuda_euclidean_clustering(*cluster_of_point, n_clusters, m_points,
                                         grid_cells_min_bound, grid_cells_max_bound,
                                         cluster_tolerance, min_cluster_size, max_cluster_size);
    if (err != ::cudaSuccess)
    {
        std::cout << YELLOW << "Clustering failed, a invalid result returned ! \n " << std::endl;
        return std::make_pair(cluster_of_point, 0);
    }

    return std::make_pair(cluster_of_point, n_clusters);
}

std ::vector<thrust::host_vector<gca::index_t>> point_cloud::convex_obj_segmentation(
    const float cluster_tolerance, const gca::counter_t min_cluster_size,
    const gca::counter_t max_cluster_size)
{
    std::vector<thrust::host_vector<gca::index_t>> objs;

    if (!m_has_normals)
    {
        std::cout << YELLOW << "Point Cloud does not have normals, a empty result returned!"
                  << std::endl;
        return objs;
    }

    if (cluster_tolerance <= 0.0f)
    {
        std::cout << YELLOW << "Clustering tolerance is less than 0, a empty result returned!"
                  << std::endl;
        return objs;
    }

    if (!m_has_bound)
    {
        compute_min_max_bound();
    }

    auto grid_cell_side_len = cluster_tolerance;
    auto padding = 1.5 * grid_cell_side_len;
    const auto grid_cells_min_bound =
        make_float3(m_min_bound.x - padding, m_min_bound.y - padding, m_min_bound.z - padding);

    const auto grid_cells_max_bound =
        make_float3(m_max_bound.x + padding, m_max_bound.y + padding, m_max_bound.z + padding);

    if (grid_cell_side_len * std::numeric_limits<int>::max() <
        max(max(grid_cells_max_bound.x - grid_cells_min_bound.x,
                grid_cells_max_bound.y - grid_cells_min_bound.y),
            grid_cells_max_bound.z - grid_cells_min_bound.z))
    {
        std::cout << YELLOW << "Cluster tolerance is too small, a empty result returned!"
                  << std::endl;
        return objs;
    }

    auto err = cuda_local_convex_segmentation(objs, m_points, m_normals, grid_cells_min_bound,
                                              grid_cells_max_bound, cluster_tolerance,
                                              min_cluster_size, max_cluster_size);
    if (err != ::cudaSuccess)
    {
        std::cout << YELLOW << "Clustering failed, a invalid result returned ! \n " << std::endl;
        return objs;
    }
    return objs;
}

std::shared_ptr<point_cloud> point_cloud::create_from_rgbd(const gca::cuda_depth_frame &depth,
                                                           const gca::cuda_color_frame &color,
                                                           const gca::cuda_camera_param &param,
                                                           float threshold_min_in_meter,
                                                           float threshold_max_in_meter)
{
    auto pc = std::make_shared<point_cloud>();

    auto depth_frame_format = param.get_depth_frame_format();
    auto color_frame_format = param.get_color_frame_format();
    if (depth_frame_format != gca::Z16 || color_frame_format != gca::BGR8)
    {
        std::cout << YELLOW
                  << "Frame format is not supported right now, A empty point cloud returned! \n"
                  << std::endl;
        return pc;
    }

    if (cuda_make_point_cloud(pc->m_points, depth, color, param, threshold_min_in_meter,
                              threshold_max_in_meter) != ::cudaSuccess)
        std::cout << YELLOW << "CUDA can't make a point cloud, A empty point cloud returned! \n"
                  << std::endl;

    return pc;
}

std::shared_ptr<point_cloud> point_cloud::create_from_pcl(
    const pcl::PointCloud<pcl::PointXYZRGB> &pcl_pc)
{
    thrust::host_vector<gca::point_t> host_pts(pcl_pc.size());
    for (size_t i = 0; i < pcl_pc.size(); i++)
    {
        gca::point_t p;
        auto pcl_p = pcl_pc[i];
        p.coordinates.x = pcl_p.x;
        p.coordinates.y = pcl_p.y;
        p.coordinates.z = pcl_p.z;
        auto scale = 1.0f / 255.0f;
        p.color.r = (float)pcl_p.r * scale;
        p.color.g = (float)pcl_p.g * scale;
        p.color.b = (float)pcl_p.b * scale;
        p.property = gca::point_property::inactive;
        host_pts[i] = p;
    }

    auto pc = std::make_shared<point_cloud>();
    pc->m_points = host_pts;

    return pc;
}

thrust::device_vector<gca::index_t> point_cloud::nn_search(const gca::point_cloud &query_pc,
                                                           const gca::point_cloud &reference_pc,
                                                           float radius)
{
    thrust::device_vector<gca::index_t> result_nn_idx_in_reference(query_pc.points_number());

    if (radius <= 0.0f)
    {
        std::cout << YELLOW << "Radius is less than 0, a empty result returned!" << std::endl;
        return result_nn_idx_in_reference;
    }

    if (!query_pc.m_has_bound)
    {
        query_pc.compute_min_max_bound();
    }

    if (!reference_pc.m_has_bound)
    {
        reference_pc.compute_min_max_bound();
    }

    auto padding = 1.5f * radius;
    const auto grid_cells_min_bound =
        make_float3(min(query_pc.m_min_bound.x, reference_pc.m_min_bound.x) - padding,
                    min(query_pc.m_min_bound.y, reference_pc.m_min_bound.y) - padding,
                    min(query_pc.m_min_bound.z, reference_pc.m_min_bound.z) - padding);

    const auto grid_cells_max_bound =
        make_float3(max(query_pc.m_max_bound.x, reference_pc.m_max_bound.x) + padding,
                    max(query_pc.m_max_bound.y, reference_pc.m_max_bound.y) + padding,
                    max(query_pc.m_max_bound.z, reference_pc.m_max_bound.z) + padding);

    if (radius * std::numeric_limits<int>::max() <
        max(max(grid_cells_max_bound.x - grid_cells_min_bound.x,
                grid_cells_max_bound.y - grid_cells_min_bound.y),
            grid_cells_max_bound.z - grid_cells_min_bound.z))
    {
        std::cout << YELLOW << "Radius is too small, a empty result returned!" << std::endl;
        return result_nn_idx_in_reference;
    }

    auto err = cuda_nn_search(result_nn_idx_in_reference, query_pc.m_points, reference_pc.m_points,
                              grid_cells_min_bound, grid_cells_max_bound, radius);
    if (err != ::cudaSuccess)
    {
        std::cout << YELLOW << "NN search failed, a invalid result returned! \n" << std::endl;
        return result_nn_idx_in_reference;
    }

    return result_nn_idx_in_reference;
}

void point_cloud::nn_search(std::vector<gca::index_t> &result_nn_idx, gca::point_cloud &query_pc,
                            gca::point_cloud &reference_pc, float radius)
{
    auto result_nn_idx_device_vec = point_cloud::nn_search(query_pc, reference_pc, radius);

    result_nn_idx.resize(result_nn_idx_device_vec.size());
    thrust::copy(result_nn_idx_device_vec.begin(), result_nn_idx_device_vec.end(),
                 result_nn_idx.begin());
}
} // namespace gca
