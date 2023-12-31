#include "camera/realsense_device.hpp"
#include "geometry/point_cloud.hpp"
#include "geometry/type.hpp"
#include "movement_detection/movement_detection.hpp"
#include "registration/color_icp.hpp"
#include "util/gpu_check.hpp"
#include "visualizer/visualizer.hpp"

#include <chrono>
#include <iostream>
#include <memory>
#include <opencv4/opencv2/opencv.hpp>
#include <signal.h>
#include <thread>
#include <unistd.h>

#include <omp.h>

#include <pcl/ModelCoefficients.h>
#include <pcl/features/normal_3d.h>
#include <pcl/filters/extract_indices.h>
#include <pcl/filters/radius_outlier_removal.h>
#include <pcl/filters/statistical_outlier_removal.h>
#include <pcl/filters/voxel_grid.h>
#include <pcl/io/pcd_io.h>
#include <pcl/kdtree/kdtree_flann.h>
#include <pcl/point_types.h>
#include <pcl/registration/icp.h>
#include <pcl/segmentation/extract_clusters.h>
#include <pcl/segmentation/region_growing_rgb.h>
#include <pcl/segmentation/sac_segmentation.h>
#include <pcl/visualization/cloud_viewer.h>
#include <pcl/visualization/pcl_visualizer.h>

using namespace std::chrono_literals;

static bool exit_requested = false; // for ctrl+c exit
static void exit_sig_handler(int param)
{
    exit_requested = true;
}

static constexpr uint32_t n_cameras = 2;

Eigen::Vector3f computeAverageNormal(const pcl::PointCloud<pcl::Normal>::Ptr &normals,
                                     const std::vector<int> &indices)
{
    Eigen::Vector3f avg_normal(0, 0, 0);
    for (int idx : indices)
    {
        avg_normal += normals->points[idx].getNormalVector3fMap();
    }
    avg_normal /= indices.size();
    avg_normal.normalize();
    return avg_normal;
}

Eigen::Vector3i generateRandomColor()
{
    int r = rand() % 256;
    int g = rand() % 256;
    int b = rand() % 256;
    return Eigen::Vector3i(r, g, b);
}

int main(int argc, char *argv[])
{
    signal(SIGINT, exit_sig_handler); // for ctrl+c exit

    cuda_print_devices();
    cuda_warm_up_gpu(0);

    auto rs_cam_0 = gca::realsense_device(0, 640, 480, 30);
    if (!rs_cam_0.device_start())
        return 1;

    gca::cuda_camera_param cu_param_0(rs_cam_0);

    typedef pcl::PointXYZRGBA PointT;
    typedef pcl::PointCloud<PointT> PointCloud;

    PointCloud::Ptr cloud_0(new PointCloud);
    PointCloud::Ptr cloud_1(new PointCloud);
    pcl::PointCloud<pcl::Normal>::Ptr normals(new pcl::PointCloud<pcl::Normal>());
    pcl::visualization::CloudViewer viewer_0("viewer0");

    gca::cuda_color_frame gpu_color_0(rs_cam_0.get_width(), rs_cam_0.get_height());
    gca::cuda_depth_frame gpu_depth_0(rs_cam_0.get_width(), rs_cam_0.get_height());

    bool if_first_frame = true;
    gca::color_icp color_icp(10, 0.05f, 0.02f);
    std::shared_ptr<gca::point_cloud> last_frame_ptr;

    auto detector = gca::movement_detection();
    // gca::visualizer v;

    std::shared_ptr<gca::point_cloud> src_pc;
    std::shared_ptr<gca::point_cloud> tgt_pc;
    while (!exit_requested)
    {
        rs_cam_0.receive_data();
        auto color_0 = rs_cam_0.get_color_raw_data();
        auto depth_0 = rs_cam_0.get_depth_raw_data();
        auto start = std::chrono::steady_clock::now();
        gpu_color_0.upload((uint8_t *)color_0, rs_cam_0.get_width(), rs_cam_0.get_height());
        gpu_depth_0.upload((uint16_t *)depth_0, rs_cam_0.get_width(), rs_cam_0.get_height());

        auto pc_0 =
            gca::point_cloud::create_from_rgbd(gpu_depth_0, gpu_color_0, cu_param_0, 0.3, 1.5);

        auto pc_downsampling_0 = pc_0->voxel_grid_down_sample(0.005f);
        auto pc_remove_noise_0 = pc_downsampling_0->radius_outlier_removal(0.007f, 3);
        pc_remove_noise_0->estimate_normals(0.03f);

        auto objs = pc_remove_noise_0->convex_obj_segmentation(
            0.007f, pc_remove_noise_0->points_number() / 500,
            pc_remove_noise_0->points_number() / 2);
        auto end = std::chrono::steady_clock::now();
        std::cout << objs.size() << std::endl;

        // v.update(pc_remove_noise_0);
        std::cout << "pc size: " << pc_0->points_number() << std::endl;
        std::cout << "Total cuda time in milliseconds: "
                  << std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count()
                  << "ms" << std::endl;

        auto points_0 = pc_remove_noise_0->download();
        auto number_of_points = points_0.size();
        cloud_1->clear();
        cloud_1->points.resize(number_of_points);
        for (const auto &obj : objs)
        {
            auto c = generateRandomColor();
            for (const auto &i : obj)
            {
                PointT p;
                p.x = points_0[i].coordinates.x;
                p.y = -points_0[i].coordinates.y;
                p.z = -points_0[i].coordinates.z;
                p.r = c(0);
                p.g = c(1);
                p.b = c(2);
                cloud_1->points[i] = p;
            }
        }
        viewer_0.showCloud(cloud_1);
        std::this_thread::sleep_for(1000ms);

        /*
        if (if_first_frame)
        {
            src_pc = pc_remove_noise_0;
            if_first_frame = false;
            auto objs = src_pc->convex_obj_segmentation(0.3, 50, 50000);
            std::cout << objs.size() << std::endl;
            continue;
        }
        color_icp.set_source_point_cloud(src_pc);
        // auto cluster = pc_downsampling_0->euclidean_clustering(0.04f, 100, 200000);

        color_icp.set_target_point_cloud(pc_remove_noise_0);
        color_icp.align();

        src_pc = pc_remove_noise_0;

        std::cout << color_icp.get_RSME() << std::endl;
        auto end = std::chrono::steady_clock::now();
        std::cout << "Total cuda time in milliseconds: "
                  << std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count()
                  << "ms" << std::endl;
        */
        /*
        detector.update_point_cloud(pc_downsampling_0);

        auto moving_pc = detector.moving_objects_detection();
        auto end = std::chrono::steady_clock::now();
        std::cout << "Total cuda time in microseconds: "
                  << std::chrono::duration_cast<std::chrono::microseconds>(end - start).count()
                  << "us" << std::endl;
        std::cout << "Total cuda time in milliseconds: "
                  << std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count()
                  << "ms" << std::endl;

        std::cout << "GPU pc1 number: " << pc_0->points_number() << std::endl;
        std::cout << "GPU pc1 after remove noise number: " << pc_remove_noise_0->points_number()
                  << std::endl;
        std::cout << "GPU pc1 Voxel number: " << pc_downsampling_0->points_number() << std::endl;


        if (if_first_frame)
        {
            auto points_0 = pc_downsampling_0->download();
            auto number_of_points = points_0.size();

            cloud_0->points.resize(number_of_points);
            for (size_t i = 0; i < number_of_points; i++)
            {
                PointT p;
                p.x = points_0[i].coordinates.x;
                p.y = -points_0[i].coordinates.y;
                p.z = -points_0[i].coordinates.z;
                p.r = 255;
                p.g = 0;
                p.b = 0;
                cloud_0->points[i] = p;
            }
            if_first_frame = false;
            continue;
        }

        auto points_0 = pc_downsampling_0->download();
        auto number_of_points = points_0.size();

        cloud_1->points.resize(number_of_points);
        for (size_t i = 0; i < number_of_points; i++)
        {
            PointT p;
            p.x = points_0[i].coordinates.x;
            p.y = -points_0[i].coordinates.y;
            p.z = -points_0[i].coordinates.z;
            p.r = 0;
            p.g = 255;
            p.b = 0;
            cloud_1->points[i] = p;
        }

        *cloud_1 += *cloud_0;
        std::cout << cloud_0->size();
        viewer_0.showCloud(cloud_0);

        while (!exit_requested)
        {
            sleep(.01);
        }
        */
        /*
        if (moving_pc)
        {
            auto points_0 = moving_pc->download();
            auto normals_0 = pc_downsampling_0->download_normals();
            auto number_of_points = points_0.size();

            cloud_1->points.resize(number_of_points);
            for (size_t i = 0; i < number_of_points; i++)
            {
                PointT p;
                p.x = points_0[i].coordinates.x;
                p.y = -points_0[i].coordinates.y;
                p.z = -points_0[i].coordinates.z;
                p.r = points_0[i].color.r * 255;
                p.g = points_0[i].color.g * 255;
                p.b = points_0[i].color.b * 255;
                cloud_1->points[i] = p;
            }
            viewer_0.showCloud(cloud_1);
        }
        */
        /*
        auto points_0 = pc_downsampling_0->download();
        auto number_of_points = points_0.size();
        cloud_0->points.resize(number_of_points);
        for (size_t i = 0; i < number_of_points; i++)
        {
            PointT p;
            p.x = points_0[i].coordinates.x;
            p.y = -points_0[i].coordinates.y;
            p.z = -points_0[i].coordinates.z;
            p.r = points_0[i].color.r * 255;
            p.g = points_0[i].color.g * 255;
            p.b = points_0[i].color.b * 255;
            cloud_0->points[i] = p;
        }
        viewer_0.showCloud(cloud_0);
        */
        /* RANSAC Seg plane
        /
        start = std::chrono::steady_clock::now();
        pcl::ModelCoefficients::Ptr coefficients(new pcl::ModelCoefficients);
        pcl::PointIndices::Ptr inliers(new pcl::PointIndices);
        pcl::SACSegmentation<pcl::PointXYZRGBA> seg;

        seg.setOptimizeCoefficients(true);
        seg.setModelType(pcl::SACMODEL_PLANE);
        seg.setMethodType(pcl::SAC_RANSAC);
        seg.setMaxIterations(1000);
        seg.setDistanceThreshold(0.01);

        seg.setInputCloud(cloud_1);
        seg.segment(*inliers, *coefficients);

        end = std::chrono::steady_clock::now();

        std::cout << "RANSAC seg: "
                  << std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count()
                  << "ms" << std::endl;

        if (inliers->indices.size() == 0)
        {
            PCL_ERROR("Could not estimate a planar model for the given dataset.");
            return -1;
        }

        for (int index : inliers->indices)
        {
            cloud_1->points[index].r = 0;
            cloud_1->points[index].g = 255;
            cloud_1->points[index].b = 0;
        }
        */

        /*
        auto points_0 = pc_downsampling_0->download();
        auto number_of_points = points_0.size();
        cloud_1->points.resize(number_of_points);
        for (size_t i = 0; i < number_of_points; i++)
        {
            PointT p;
            p.x = points_0[i].coordinates.x;
            p.y = -points_0[i].coordinates.y;
            p.z = -points_0[i].coordinates.z;
            p.r = points_0[i].color.r * 255;
            p.g = points_0[i].color.g * 255;
            p.b = points_0[i].color.b * 255;
            cloud_1->points[i] = p;
        }
        pcl::search::Search<pcl::PointXYZRGBA>::Ptr tree =
            std::shared_ptr<pcl::search::Search<pcl::PointXYZRGBA>>(
                new pcl::search::KdTree<pcl::PointXYZRGBA>);
        */
        /* clustering using normals */
        /*
        pcl::RegionGrowing<pcl::PointXYZRGBA, pcl::Normal> reg;
        reg.setMinClusterSize(50);
        reg.setMaxClusterSize(1000000);
        reg.setSearchMethod(tree);
        reg.setNumberOfNeighbours(30);
        reg.setInputCloud(cloud_1);
        // reg.setIndices (indices);
        reg.setInputNormals(normals);
        reg.setSmoothnessThreshold(3.0 / 180.0 * M_PI);
        reg.setCurvatureThreshold(1.0);
        */
        /*
        pcl::RegionGrowingRGB<pcl::PointXYZRGBA> reg;
        reg.setInputCloud(cloud_1);
        reg.setSearchMethod(tree);
        reg.setDistanceThreshold(0.04);
        reg.setPointColorThreshold(5);
        reg.setMinClusterSize(50);

        std::vector<pcl::PointIndices> cluster_indices;
        reg.extract(cluster_indices);

        std::cout << "clusters: " << cluster_indices.size() << std::endl;

        start = std::chrono::steady_clock::now();
        for (std::vector<pcl::PointIndices>::const_iterator it = cluster_indices.begin();
             it != cluster_indices.end(); ++it)
        {
            pcl::PointCloud<pcl::PointXYZRGBA>::Ptr cloud_cluster(
                new pcl::PointCloud<pcl::PointXYZRGBA>);
            for (std::vector<int>::const_iterator pit = it->indices.begin();
                 pit != it->indices.end(); ++pit)
                cloud_cluster->points.push_back(cloud_1->points[*pit]);
            cloud_cluster->width = cloud_cluster->points.size();
            cloud_cluster->height = 1;
            cloud_cluster->is_dense = true;

            pcl::IterativeClosestPoint<pcl::PointXYZRGBA, pcl::PointXYZRGBA> icp;
            icp.setMaximumIterations(3);
            icp.setInputSource(cloud_cluster);
            icp.setInputTarget(cloud_0);
            icp.setMaxCorrespondenceDistance(0.1);
            pcl::PointCloud<pcl::PointXYZRGBA> Final;
            icp.align(Final);

            double avg_residual = icp.getFitnessScore();
            std::cout << "residual: " << avg_residual << std::endl;

            if (icp.hasConverged())
            {
                std::cout << "ICP has converged." << std::endl;
                std::cout << "The transformation matrix is:" << std::endl;
                std::cout << (icp.getFinalTransformation().block<3, 1>(0, 3)).norm() << std::endl;
                if ((icp.getFinalTransformation().block<3, 1>(0, 3)).norm() > 0.03)
                {
                    for (std::vector<int>::const_iterator pit = it->indices.begin();
                         pit != it->indices.end(); ++pit)
                    {
                        cloud_1->points[*pit].r = 255;
                        cloud_1->points[*pit].g = 0;
                        cloud_1->points[*pit].b = 0;
                    }
                }
            }
            else
            {
                std::cout << "ICP did not converge." << std::endl;
            }
        }
        end = std::chrono::steady_clock::now();

        std::cout << "residual: "
                  << std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count()
                  << "ms" << std::endl;

        viewer_0.showCloud(cloud_1);
        *cloud_0 = *cloud_1;
        */
        /* PCL Over seg*/
        /*
        pcl::NormalEstimation<pcl::PointXYZRGBA, pcl::Normal> ne;
        ne.setInputCloud(cloud_0);
        pcl::search::KdTree<pcl::PointXYZRGBA>::Ptr tree(
            new pcl::search::KdTree<pcl::PointXYZRGBA>());
        ne.setSearchMethod(tree);
        pcl::PointCloud<pcl::Normal>::Ptr normals(new pcl::PointCloud<pcl::Normal>);
        ne.setRadiusSearch(0.05);
        ne.compute(*normals);

        pcl::RegionGrowingRGB<pcl::PointXYZRGBA, pcl::Normal> reg;
        reg.setInputCloud(cloud_0);
        reg.setInputNormals(normals);
        reg.setSearchMethod(tree);
        reg.setDistanceThreshold(0.05);
        reg.setMinClusterSize(200);
        reg.setPointColorThreshold(15);
        reg.setSmoothnessThreshold(1.0 / 180.0 * M_PI);
        reg.setMinClusterSize(0);
        std::vector<pcl::PointIndices> clusters;
        reg.extract(clusters);

        pcl::PointCloud<pcl::PointXYZRGBA>::Ptr surfels(new pcl::PointCloud<pcl::PointXYZRGBA>);
        for (const auto &cluster : clusters)
        {
            auto color = generateRandomColor();
            for (int idx : cluster.indices)
            {
                auto p = cloud_0->points[idx];
                p.r = color(0);
                p.g = color(1);
                p.b = color(2);
                surfels->push_back(p);
            }
        }
        */
        /*
        pcl::PointCloud<pcl::Normal>::Ptr normals(new pcl::PointCloud<pcl::Normal>);
        pcl::NormalEstimation<pcl::PointXYZRGBA, pcl::Normal> normal_estimator;
        normal_estimator.setSearchMethod(tree);
        normal_estimator.setInputCloud(cloud_1);
        normal_estimator.setRadiusSearch(0.04);
        normal_estimator.compute(*normals);

        auto normal_gpu = pc_downsampling_0->download_normals();

        for (size_t i = 0; i < normals->size(); i++)
        {
            if (abs(normals->points[i].normal_x) - abs(normal_gpu[i].x) > 0.01 ||
                abs(normals->points[i].normal_y) - abs(normal_gpu[i].y) > 0.01 ||
                abs(normals->points[i].normal_z) - abs(normal_gpu[i].z) > 0.01)
            {
                std::cout << "normals false: " << i << std::endl;
                std::cout << "Normal for point " << i << ": " << normals->points[i].normal_x <<
        ", "
                          << normals->points[i].normal_y << ", " << normals->points[i].normal_z
                          << std::endl;
                std::cout << "gpu Normal       " << i << ": " << normal_gpu[i].x << ", "
                          << normal_gpu[i].y << ", " << normal_gpu[i].z << std::endl;
            }
        }
        */
        /*
        start = std::chrono::steady_clock::now();
        pcl::search::Search<pcl::PointXYZRGBA>::Ptr tree(
            new pcl::search::KdTree<pcl::PointXYZRGBA>);

        pcl::RegionGrowingRGB<pcl::PointXYZRGBA> reg;
        reg.setInputCloud(cloud_0);
        reg.setSearchMethod(tree);

        reg.setDistanceThreshold(10);
        reg.setPointColorThreshold(6);
        reg.setRegionColorThreshold(5);

        std::vector<pcl::PointIndices> clusters;
        reg.extract(clusters);
        end = std::chrono::steady_clock::now();
        std::cout << "region: "
                  << std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count()
                  << std::endl;
        pcl::PointCloud<pcl::PointXYZRGB>::Ptr colored_cloud = reg.getColoredCloud();
        */
        /* PCL Radius search Test */
        /*
        start = std::chrono::steady_clock::now();
        pcl::KdTreeFLANN<pcl::PointXYZRGBA> kdtree;
        kdtree.setInputCloud(cloud_0);

        float radius = 0.06f;
        auto n = 0;

        for (size_t i = 0; i < cloud_0->points.size(); ++i)
        {
            std::vector<int> pointIdxRadiusSearch;
            std::vector<float> pointRadiusSquaredDistance;

            if (kdtree.radiusSearch(cloud_0->points[i], radius, pointIdxRadiusSearch,
                                    pointRadiusSquaredDistance) > 0)
            {
                for (size_t j = 0; j < pointIdxRadiusSearch.size(); ++j)
                    ++n;
            }
        }
        end = std::chrono::steady_clock::now();
        std::cout << "PCL search radius time: "
                  << std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count()
                  << "ms" << std::endl;
        std::cout << "PCL neighbor total number: " << n << std::endl;
        */
        /* PCL Clustering test */
        /*
        start = std::chrono::steady_clock::now();
        pcl::search::KdTree<pcl::PointXYZRGBA>::Ptr tree(
            new pcl::search::KdTree<pcl::PointXYZRGBA>);
        tree->setInputCloud(cloud_0);

        std::vector<pcl::PointIndices> cluster_indices;
        pcl::EuclideanClusterExtraction<pcl::PointXYZRGBA> ec;
        ec.setClusterTolerance(0.04f);
        ec.setMinClusterSize(100);
        ec.setMaxClusterSize(200000);
        ec.setSearchMethod(tree);
        ec.setInputCloud(cloud_0);
        ec.extract(cluster_indices);
        end = std::chrono::steady_clock::now();
        int j = 0;
        for (std::vector<pcl::PointIndices>::const_iterator it = cluster_indices.begin();
             it != cluster_indices.end(); ++it)
        {
            j += 1;
        }

        if (j != cluster.second)
        {
            return 0;
        }

        std::cout << "PCL clustering time in microseconds: "
                  << std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count()
                  << "ms" << std::endl;
        std::cout << "PCL clustering num: " << j << std::endl;
        */
        /* PCL NN Search Test */
        /*
        pcl::KdTreeFLANN<pcl::PointXYZRGBA> kdtree;
        kdtree.setInputCloud(cloud_0);

        std::vector<int> nearest_indices_pcl;

        for (size_t i = 0; i < cloud_1->points.size(); ++i)
        {
            std::vector<int> pointIdxNKNSearch(1);
            std::vector<float> pointNKNSquaredDistance(1);

            if (kdtree.nearestKSearch(cloud_1->points[i], 1, pointIdxNKNSearch,
                                      pointNKNSquaredDistance) > 0)
            {
                nearest_indices_pcl.push_back(pointIdxNKNSearch[0]);
            }
            else
            {
                nearest_indices_pcl.push_back(-1);
            }
        }

        if (result_nn_idx_cuda.size() != nearest_indices_pcl.size())
        {
            std::cout << "NN HAS PROBLEM!!!" << std::endl;
        }

        auto different = 0;

        for (size_t i = 0; i < result_nn_idx_cuda.size(); i++)
        {
            if (result_nn_idx_cuda[i] != nearest_indices_pcl[i] && result_nn_idx_cuda[i] != -1)
            {
                // std::cout << "Wrong NN!!! at " << i << std::endl;
                std::cout << "cuda " << result_nn_idx_cuda[i] << std::endl;
                std::cout << "pcl " << nearest_indices_pcl[i] << std::endl;
                different += 1;
            }
        }
        std::cout << "different num " << different << std::endl;
        */

        /* PCL Radius Outlier removal test */
        /*
        auto points_0 = pc_0->download();
        auto number_of_points = points_0.size();

        cloud_0->points.resize(number_of_points);
        for (size_t i = 0; i < number_of_points; i++)
        {
            PointT p;
            p.x = points_0[i].coordinates.x;
            p.y = -points_0[i].coordinates.y;
            p.z = -points_0[i].coordinates.z;
            p.r = points_0[i].color.r * 255;
            p.g = points_0[i].color.g * 255;
            p.b = points_0[i].color.b * 255;
            cloud_0->points[i] = p;
        }
        pcl::PointCloud<pcl::PointXYZRGBA>::Ptr cloud_filtered(
            new pcl::PointCloud<pcl::PointXYZRGBA>);

        pcl::RadiusOutlierRemoval<pcl::PointXYZRGBA> sor_radius;
        sor_radius.setInputCloud(cloud_0);
        sor_radius.setRadiusSearch(0.02);
        sor_radius.setMinNeighborsInRadius(6);

        start = std::chrono::steady_clock::now();
        sor_radius.filter(*cloud_filtered);
        end = std::chrono::steady_clock::now();

        std::cout << "PCL radius outlier removal time in microseconds: "
                  << std::chrono::duration_cast<std::chrono::microseconds>(end - start).count()
                  << "us" << std::endl;
        std::cout << "PCL radius outlier removal time in milliseconds: "
                  << std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count()
                  << "ms" << std::endl;

        std::cout << "Points number after PCL filter: " << cloud_filtered->size() << std::endl;
        */
        /* Voxel Grid PCL */
        auto points_1 = pc_0->download();
        number_of_points = points_1.size();

        cloud_0->points.resize(number_of_points);
        for (size_t i = 0; i < number_of_points; i++)
        {
            PointT p;
            p.x = points_1[i].coordinates.x;
            p.y = -points_1[i].coordinates.y;
            p.z = -points_1[i].coordinates.z;
            p.r = points_1[i].color.r * 255;
            p.g = points_1[i].color.g * 255;
            p.b = points_1[i].color.b * 255;
            cloud_0->points[i] = p;
        }

        start = std::chrono::steady_clock::now();
        pcl::PointCloud<pcl::PointXYZRGBA>::Ptr cloud_filtered(
            new pcl::PointCloud<pcl::PointXYZRGBA>);

        pcl::VoxelGrid<pcl::PointXYZRGBA> sor;
        sor.setInputCloud(cloud_0);
        sor.setLeafSize(0.005f, 0.005f, 0.005f);
        sor.filter(*cloud_filtered);
        end = std::chrono::steady_clock::now();
        std::cout << "PCL radius outlier removal time in milliseconds: "
                  << std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count()
                  << "ms" << std::endl;
        std::cout << "Filtered cloud size: " << cloud_filtered->size() << std::endl;

        std::cout << "__________________________________________________" << std::endl;
    }

    // v.close();

    return 0;
}
