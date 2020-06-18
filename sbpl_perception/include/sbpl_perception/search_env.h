#pragma once

/**
 * @file search_env.h
 * @brief Object recognition search environment
 * @author Venkatraman Narayanan
 * Carnegie Mellon University, 2015
 */

#include <cuda_renderer/renderer.h>
// #include <cuda_icp/icp.h>
// #include <cuda_icp/helper.h>
#include <cuda_renderer/knncuda.h>

#include <kinect_sim/model.h>
#include <kinect_sim/scene.h>
#include <kinect_sim/simulation_io.hpp>
#include <perception_utils/pcl_typedefs.h>
#include <sbpl_perch/headers.h>
#include <sbpl_perception/config_parser.h>
#include <sbpl_perception/graph_state.h>
#include <sbpl_perception/mpi_utils.h>
#include <sbpl_perception/object_model.h>
#include <sbpl_perception/rcnn_heuristic_factory.h>
#include <sbpl_perception/utils/utils.h>
#include <sbpl_utils/hash_manager/hash_manager.h>

#include <boost/mpi.hpp>
#include <Eigen/Dense>
#include <opencv/cv.h>
#include <opencv2/core/core.hpp>
#include <pcl/range_image/range_image_planar.h>
#include <pcl/registration/icp.h>
#include <pcl/registration/icp_nl.h>
#include <pcl/registration/transformation_estimation_2D.h>
#include <pcl/surface/texture_mapping.h>
// #include <pcl/registration/transformation_estimation_lm.h>
// #include <pcl/registration/transformation_estimation_svd.h>
// #include <pcl/registration/warp_point_rigid_3d.h>
#include <pcl/PolygonMesh.h>
#include <pcl/search/kdtree.h>
#include <pcl/search/organized.h>
#include <pcl/io/ply_io.h>
#include <pcl/io/pcd_io.h>
#include <pcl/visualization/pcl_visualizer.h>
#include <pcl/visualization/range_image_visualizer.h>
#include <pcl/visualization/image_viewer.h>
#include <pcl/filters/voxel_grid.h>
#include <pcl/filters/statistical_outlier_removal.h>
#include <pcl/registration/gicp.h>
#include <fast_gicp/gicp/fast_vgicp.hpp>
#include <fast_gicp/gicp/fast_gicp.hpp>
#include <fast_gicp/gicp/fast_gicp_st.hpp>
#include <fast_gicp/gicp/fast_gicp_cuda.hpp>

#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include <ros/ros.h>
#include <sbpl_perception/ColorSpace/ColorSpace.h>
#include <sbpl_perception/ColorSpace/Conversion.h>
#include <sbpl_perception/ColorSpace/Comparison.h>
#include <chrono>
#include <thread>
#include <fstream>
#include <algorithm> 
// #include <cuda_icp_custom/kernel.h>
// #include <cuda_icp_custom/kdtree.hpp>
// #include <cuda_icp_custom/pointcloud.h>
#include <numeric>
#include <nlohmann/json.hpp>
#include <sophus/so3.hpp>

int *difffilter(const cv::Mat& input,const cv::Mat& input1, cv::Mat& output);
namespace sbpl_perception {

struct EnvConfig {
  // Search resolution.
  double res, theta_res;
  // The model-bank.
  ModelBank model_bank;
};

struct EnvParams {
  double table_height;
  Eigen::Isometry3d camera_pose;
  cv::Mat cam_intrinsic;
  cuda_renderer::Model::mat4x4 proj_mat;
  int width;
  int height;
  double x_min, x_max, y_min, y_max;
  double res, theta_res; // Resolution for x,y and theta
  int goal_state_id, start_state_id;
  int num_objects; // This is the number of objects on the table
  int num_models; // This is the number of models available (can be more or less than number of objects on table
  int use_external_render;
  std::string reference_frame_;
  int use_external_pose_list;
  int use_icp;
  int shift_pose_centroid;
  std::string rendered_root_dir;
};

struct PERCHParams {
  bool initialized;
  double sensor_resolution;
  // Number of points that should be near the (x,y,table height) of the object
  // for that state to be considered as valid.
  int min_neighbor_points_for_valid_pose;
  // Minimum number of points in the constraint cloud that should be enclosed
  // by the object's volume for that pose to be considered as valid.
  int min_points_for_constraint_cloud;
  // Maximum number of iteration allowed for ICP refinement.
  int max_icp_iterations;
  // Maximum allowed distance bewteen point correspondences for ICP.
  double icp_max_correspondence;
  // True if precomputed RCNN heuristics should be used.
  bool use_rcnn_heuristic;
  // True if search resolution should be automatically determined based on
  // object dimensions.
  bool use_adaptive_resolution;
  // True if search resolutions specificed in the object meta data XML should
  // be used, instead of the fixed EnvParams::res.
  bool use_model_specific_search_resolution;
  // If true, operates in "under clutter mode", where the algorithm can decide
  // to treat some input cloud points as occluders.
  bool use_clutter_mode;
  // If use_clutter_mode is true, the following is the regularizing multiplier
  // on the num_occluders cost. When this is a small value, the algorithm will
  // freely label input points as occluders if they help minimize the objective
  // function, otherwise, it will carefully balance labeling points as
  // occluders versus minimizing the objective.
  double clutter_regularizer;

  bool use_downsampling;

  double downsampling_leaf_size;

  bool vis_expanded_states;
  bool print_expanded_states;
  bool debug_verbose;
  bool vis_successors;

  bool use_color_cost;
  int gpu_batch_size;
  bool use_gpu;
  double color_distance_threshold;
  double gpu_stride;
  bool use_cylinder_observed;
  double gpu_occlusion_threshold;
  double footprint_tolerance;

  double depth_median_blur;
  int icp_type;

  PERCHParams() : initialized(false) {}

  friend class boost::serialization::access;
  template <typename Ar> void serialize(Ar &ar, const unsigned int) {
    ar &initialized;
    ar &sensor_resolution;
    ar &min_neighbor_points_for_valid_pose;
    ar &min_points_for_constraint_cloud;
    ar &max_icp_iterations;
    ar &icp_max_correspondence;
    ar &use_rcnn_heuristic;
    ar &use_adaptive_resolution;
    ar &use_model_specific_search_resolution;
    ar &vis_expanded_states;
    ar &print_expanded_states;
    ar &debug_verbose;
    ar &use_clutter_mode;
    ar &clutter_regularizer;
    ar &vis_successors;
    ar &use_downsampling;
    ar &downsampling_leaf_size;
    ar &use_color_cost;
    ar &gpu_batch_size;
    ar &use_gpu;
    ar &color_distance_threshold;
    ar &gpu_stride;
    ar &use_cylinder_observed;
    ar &gpu_occlusion_threshold;
    ar &footprint_tolerance;
    ar &depth_median_blur;
    ar &icp_type;
  }
};
// BOOST_IS_MPI_DATATYPE(PERCHParams);
// BOOST_IS_BITWISE_SERIALIZABLE(PERCHParams);

class EnvObjectRecognition : public EnvironmentMHA {
 public:
  explicit EnvObjectRecognition(const std::shared_ptr<boost::mpi::communicator>
                                &comm);
  ~EnvObjectRecognition();

  // Load the object models to be used in the search episode. model_bank contains
  // metadata of *all* models, and model_ids is the list of models that are
  // present in the current scene.
  void LoadObjFiles(const ModelBank &model_bank,
                    const std::vector<std::string> &model_names);

  void PrintState(int state_id, std::string fname);
  void PrintState(int state_id, std::string fname, std::string cname);
  void PrintState(GraphState s, std::string fname);
  void PrintState(GraphState s, std::string fname, std::string cfname);
  void PrintImage(std::string fname,
                  const std::vector<unsigned short> &depth_image);
  void PrintImage(std::string fname,
                  const std::vector<unsigned short> &depth_image,
                  bool show_image_window);

  // Return the depth image rendered according to object poses in state s. Will
  // also return the number of points in the input cloud that occlude any of
  // the points in the renderered scene.
  // If kClutterMode is true, then the rendered scene will account for
  // "occluders" in the input scene, i.e, any point in the input cloud which
  // occludes a point in the rendered scene.
  const float *GetDepthImage(GraphState &s,
                             std::vector<unsigned short> *depth_image, 
                             std::vector<std::vector<unsigned char>> *color_image,
                             cv::Mat &cv_depth_image,
                             cv::Mat &cv_color_image,
                             int* num_occluders_in_input_cloud,
                             bool shift_centroid);

  const float *GetDepthImage(GraphState s,
                             std::vector<unsigned short> *depth_image,
                             std::vector<std::vector<unsigned char>> *color_image,
                             cv::Mat *cv_depth_image,
                             cv::Mat *cv_color_image,
                             int* num_occluders_in_input_cloud);

  const float *GetDepthImage(GraphState s,
                             std::vector<unsigned short> *depth_image);

  const float *GetDepthImage(GraphState s,
                        std::vector<unsigned short> *depth_image,
                        std::vector<std::vector<unsigned char>> *color_image,
                        cv::Mat *cv_depth_image,
                        cv::Mat *cv_color_image);

  void depthCVToShort(cv::Mat input_image, vector<unsigned short> *depth_image);
  void colorCVToShort(cv::Mat input_image, vector<vector<unsigned char>> *color_image);
  void CVToShort(cv::Mat *input_color_image,
                 cv::Mat *input_depth_image,
                 vector<unsigned short> *depth_image,
                 vector<vector<unsigned char>> *color_image);

  pcl::simulation::SimExample::Ptr kinect_simulator_;

  void Initialize(const EnvConfig &env_config);
  void SetInput(const RecognitionInput &input);
  void SetStaticInput(const RecognitionInput &input);

  /** Methods to set the observed depth image**/
  void SetObservation(std::vector<int> object_ids,
                      std::vector<ContPose> poses);
  void SetObservation(int num_objects,
                      const std::vector<unsigned short> observed_depth_image);
  void SetCameraPose(Eigen::Isometry3d camera_pose);
  void SetTableHeight(double height);
  double GetTableHeight();
  void SetBounds(double x_min, double x_max, double y_min, double y_max);

  double GetICPAdjustedPose(const PointCloudPtr cloud_in,
                            const ContPose &pose_in, PointCloudPtr &cloud_out, ContPose *pose_out,
                            const std::vector<int> counted_indices = std::vector<int>(0),
                            const PointCloudPtr target_cloud = NULL,
                            const std::string object_name = "");

  double GetVGICPAdjustedPose(const PointCloudPtr cloud_in,
                          const ContPose &pose_in, PointCloudPtr &cloud_out, ContPose *pose_out,
                          const std::vector<int> counted_indices = std::vector<int>(0),
                          const PointCloudPtr target_cloud = NULL,
                          const std::string object_name = "");

  std::vector<unsigned short> GetInputDepthImage() {
    return observed_depth_image_;
  }

  // Greedy ICP planner
  GraphState ComputeGreedyICPPoses();

  void GetSuccs(GraphState source_state, std::vector<GraphState> *succs,
                std::vector<int> *costs);
  bool IsGoalState(GraphState state);
  int GetGoalStateID() {
    return env_params_.goal_state_id;  // Goal state has unique id
  }
  int GetStartStateID() {
    return env_params_.start_state_id;  // Goal state has unique id
  }

  void GetSuccs(int source_state_id, std::vector<int> *succ_ids,
                std::vector<int> *costs);

  void GetLazySuccs(int source_state_id, std::vector<int> *succ_ids,
                    std::vector<int> *costs,
                    std::vector<bool> *true_costs);
  void GetLazyPreds(int source_state_id, std::vector<int> *pred_ids,
                    std::vector<int> *costs,
                    std::vector<bool> *true_costs) {
    throw std::runtime_error("unimplement");
  }

  // For MHA
  void GetSuccs(int q_id, int source_state_id, std::vector<int> *succ_ids,
                std::vector<int> *costs) {
    printf("Expanding %d from %d\n", source_state_id, q_id);
    GetSuccs(source_state_id, succ_ids, costs);
  }

  void GetLazySuccs(int q_id, int source_state_id, std::vector<int> *succ_ids,
                    std::vector<int> *costs,
                    std::vector<bool> *true_costs) {
    // throw std::runtime_error("don't use lazy for now...");
    printf("Lazily expanding %d from %d\n", source_state_id, q_id);
    GetLazySuccs(source_state_id, succ_ids, costs, true_costs);
  }

  void GetLazyPreds(int q_id, int source_state_id, std::vector<int> *pred_ids,
                    std::vector<int> *costs,
                    std::vector<bool> *true_costs) {
    throw std::runtime_error("unimplement");
  }

  int GetTrueCost(int source_state_id, int child_state_id);

  int GetGoalHeuristic(int state_id);
  int GetGoalHeuristic(int q_id, int state_id); // For MHA*
  int SizeofCreatedEnv() {
    return static_cast<int>(hash_manager_.Size());
  }

  // Return the ID of the successor with smallest transition cost for a given
  // parent state ID.
  int GetBestSuccessorID(int state_id);

  // Compute costs of successor states in parallel using MPI. This method must
  // be called by all processors.
  void ComputeCostsInParallel(std::vector<CostComputationInput> &input,
                              std::vector<CostComputationOutput> *output, bool lazy);

  void PrintValidStates();

  void SetDebugOptions(bool image_debug);
  void SetDebugDir(const std::string &debug_dir);
  const std::string &GetDebugDir() {
    return debug_dir_;
  }

  const EnvStats &GetEnvStats();
  void GetGoalPoses(int true_goal_id, std::vector<ContPose> *object_poses);
  std::vector<PointCloudPtr> GetObjectPointClouds(const std::vector<int>
                                                  &solution_state_ids);

  int NumHeuristics() const;

  // TODO: Make these private
  std::unique_ptr<RCNNHeuristicFactory> rcnn_heuristic_factory_;
  Heuristics rcnn_heuristics_;

  void getGlobalPointCV (int u, int v, float range,
                          const Eigen::Isometry3d &pose, Eigen::Vector3f &world_point);

  PointCloudPtr GetGravityAlignedPointCloudCV(cv::Mat depth_image, cv::Mat color_image, cv::Mat predicted_mask_image, double depth_factor);
  PointCloudPtr GetGravityAlignedPointCloudCV(cv::Mat depth_image, cv::Mat color_image, double depth_factor);
  PointCloudPtr GetGravityAlignedPointCloud(
    const vector<unsigned short> &depth_image, uint8_t rgb[3]);

  PointCloudPtr GetGravityAlignedPointCloud(const std::vector<unsigned short> &depth_image);

  PointCloudPtr GetGravityAlignedPointCloud(const std::vector<unsigned short> &depth_image,
                                            const std::vector<std::vector<unsigned char>> &color_image
                                            );
  PointCloudPtr GetGravityAlignedOrganizedPointCloud(const
                                                     std::vector<unsigned short>
                                                     &depth_image);

  void PrintPointCloud(PointCloudPtr gravity_aligned_point_cloud, int state_id, ros::Publisher point_cloud_topic);
  // void PrintPointCloud(PointCloudPtr gravity_aligned_point_cloud, int state_id, ros::Publisher point_cloud_topic);

  //6D stuff
  std::vector<PointCloudPtr> segmented_object_clouds;
  std::vector<std::string> segmented_object_names;
  void GetShiftedCentroidPosesGPU(const vector<ObjectState>& objects,
                                  vector<ObjectState>& modified_objects,
                                  int start_index);
  vector<float> segmented_observed_point_count;
  std::vector<pcl::search::KdTree<PointT>::Ptr> segmented_object_knn;
  std::vector<uint8_t> predicted_mask_image;
  // std::vector<int32_t> input_depth_image_vec;

  // CUDA GPU stuff
  std::unordered_map<int, std::vector<int32_t>> gpu_depth_image_cache_;
  std::unordered_map<int, std::vector<std::vector<uint8_t>>> gpu_color_image_cache_;
  void ComputeCostsInParallelGPU(std::vector<CostComputationInput> &input,
                              std::vector<CostComputationOutput> *output, bool lazy);
  void ComputeGreedyCostsInParallelGPU(const std::vector<int32_t> &source_result_depth,
                                      const std::vector<ObjectState> &last_object_states,
                                      std::vector<CostComputationOutput> &output,
                                      int batch_index);
  vector<int> tris_model_count;
  vector<cuda_renderer::Model::Triangle> tris;
  float gpu_depth_factor = 100.0;
  float input_depth_factor;
  int gpu_point_dim = 3;
  // Stride should divide width exactly
  int gpu_stride = 5;
  float* result_observed_cloud;
  Eigen::Vector3f* result_observed_cloud_eigen;
  uint8_t* result_observed_cloud_color;
  int observed_point_num;
  int* observed_dc_index;
  int32_t* observed_depth_data;
  int* unfiltered_depth_data;
  int* result_observed_cloud_label;
  vector<int32_t> input_depth_image_vec;

  cv::Mat cv_input_filtered_depth_image, cv_input_filtered_color_image, cv_input_unfiltered_depth_image;
  vector<vector<uint8_t>> cv_input_filtered_color_image_vec;
  void PrintGPUImages(vector<int32_t>& result_depth, 
                      vector<vector<uint8_t>>& result_color, 
                      int num_poses, string suffix, 
                      vector<int> pose_occluded,
                      const vector<int> cost = vector<int>());

  void GetICPAdjustedPosesCPU(const vector<ObjectState>& objects,
                              int num_poses,
                              float* result_cloud,
                              uint8_t* result_cloud_color,
                              int rendered_point_num,
                              int* cloud_pose_map,
                              int* pose_occluded,
                              vector<ObjectState>& modified_objects,
                              bool do_icp,
                              ros::Publisher render_point_cloud_topic,
                              bool print_cloud);

  void PrintGPUClouds(const vector<ObjectState>& objects,
                      float* cloud, 
                      uint8_t* cloud_color,
                      int* result_depth, 
                      int* dc_index, 
                      int num_poses, 
                      int cloud_point_num, 
                      int stride,
                      int* pose_occluded,
                      string suffix,
                      vector<ObjectState>& modified_objects,
                      bool do_icp,
                      ros::Publisher render_point_cloud_topic,
                      bool print_cloud);

  void GetStateImagesGPU(const vector<ObjectState>& objects,
                        const vector<vector<uint8_t>>& source_result_color,
                        const vector<int32_t>& source_result_depth,
                        vector<vector<uint8_t>>& result_color,
                        vector<int32_t>& result_depth,
                        vector<int>& pose_occluded,
                        int single_result_image,
                        vector<int>& pose_occluded_other,
                        vector<float>& pose_clutter_cost,
                        const vector<int>& pose_segmentation_label = vector<int>());

  void GetStateImagesUnifiedGPU(const string stage,
                      const vector<ObjectState>& objects,
                      const vector<vector<uint8_t>>& source_result_color,
                      const vector<int32_t>& source_result_depth,
                      vector<vector<uint8_t>>& result_color,
                      vector<int32_t>& result_depth,
                      int single_result_image,
                      vector<float>& pose_clutter_cost,
                      float* &result_cloud,
                      uint8_t* &result_cloud_color,
                      int& result_cloud_point_num,
                      int* &dc_index,
                      int* &cloud_pose_map,
                      // GPU  ICP 
                      std::vector<cuda_renderer::Model::mat4x4>& adjusted_poses,
                      // Costs
                      float* &rendered_cost,
                      float* &observed_cost,
                      float* &points_diff_cost,
                      float sensor_resolution,
                      bool do_gpu_icp,
                      int cost_type = 0,
                      bool calculate_observed_cost = false);

  void GetICPAdjustedPosesGPU(float* result_rendered_clouds,
                              int* dc_index,
                              int32_t* depth_data,
                              int num_poses,
                              float* result_observed_cloud,
                              int* observed_dc_index,
                              int total_rendered_points,
                              int* poses_occluded);

  GraphState ComputeGreedyRenderPoses();
  void PrintStateGPU(GraphState state);

  // We should get rid of this eventually.
  friend class ObjectRecognizer;

 private:

  ros::Publisher render_point_cloud_topic;
  ros::Publisher downsampled_input_point_cloud_topic;
  ros::Publisher downsampled_mesh_cloud_topic;
  ros::Publisher input_point_cloud_topic;
  ros::Publisher gpu_input_point_cloud_topic;
  cv::Mat cv_input_color_image;
  std::string input_depth_image_path;

  
  std::vector<ObjectModel> obj_models_;
  std::vector<cuda_renderer::Model> render_models_;
  pcl::simulation::Scene::Ptr scene_;

  EnvParams env_params_;
  PERCHParams perch_params_;

  // Config parser.
  ConfigParser parser_;

  // Model bank.
  ModelBank model_bank_;

  // The MPI communicator.
  std::shared_ptr<boost::mpi::communicator> mpi_comm_;

  /**@brief The hash manager**/
  sbpl_utils::HashManager<GraphState> hash_manager_;
  /**@brief Mapping from state IDs to states for those states that were changed
   * after evaluating true cost**/
  std::unordered_map<int, GraphState> adjusted_states_;

  // The rendering cost (or TargetCost) incurred while adding the last object
  // in this state.
  std::unordered_map<int, int> last_object_rendering_cost_;

  /**@brief Mapping from State to State ID**/
  std::unordered_map<int, std::vector<unsigned short>> depth_image_cache_;
  std::unordered_map<int, std::vector<int>> succ_cache;
  std::unordered_map<int, std::vector<int>> cost_cache;
  std::unordered_map<int, std::vector<ObjectState>> valid_succ_cache;
  std::unordered_map<int, unsigned short> minz_map_;
  std::unordered_map<int, unsigned short> maxz_map_;
  std::unordered_map<int, int> g_value_map_;
  // Keep track of the observed pixels we have accounted for in cost computation for a given state.
  // This includes all points in the observed point cloud that fall within the volume of objects assigned
  // so far in the state. For the last level states, this *does not* include the points that
  // lie outside the union volumes of all assigned objects.
  std::unordered_map<int, std::vector<int>> counted_pixels_map_;
  // Maps state hash to depth image.
  std::unordered_map<GraphState, std::vector<unsigned short>>
                                                           unadjusted_single_object_depth_image_cache_;
  std::unordered_map<GraphState, std::vector<unsigned short>>
                                                           adjusted_single_object_depth_image_cache_;
  std::unordered_map<GraphState, GraphState> adjusted_single_object_state_cache_;
  // Maps state hash to color image.
  std::unordered_map<GraphState, std::vector<std::vector<unsigned char>>>
                                                           unadjusted_single_object_color_image_cache_;
  std::unordered_map<GraphState, std::vector<std::vector<unsigned char>>>
                                                           adjusted_single_object_color_image_cache_;
  std::unordered_map<GraphState, double>
                                    adjusted_single_object_histogram_score_cache_;
  // pcl::search::OrganizedNeighbor<PointT>::Ptr knn;
  pcl::search::KdTree<PointT>::Ptr knn;
  pcl::search::KdTree<PointT>::Ptr projected_knn_;
  pcl::search::KdTree<PointT>::Ptr downsampled_projected_knn_;
  std::vector<int> valid_indices_;

  std::vector<unsigned short> observed_depth_image_;
  PointCloudPtr original_input_cloud_, observed_cloud_, downsampled_observed_cloud_,
                observed_organized_cloud_, projected_cloud_, downsampled_projected_cloud_;
  // Refer RecognitionInput::constraint_cloud for details.
  // This is an unorganized point cloud.
  PointCloudPtr constraint_cloud_, projected_constraint_cloud_;

  bool image_debug_;
  // Print outputs/debug info to this directory. Assumes that directory exists.
  std::string debug_dir_;
  unsigned short min_observed_depth_, max_observed_depth_;

  Eigen::Matrix4f gl_inverse_transform_;
  Eigen::Isometry3d cam_to_world_;

  EnvStats env_stats_;

  cv::Mat cv_color_image, cv_depth_image;

  void ResetEnvironmentState();

  void GenerateSuccessorStates(const GraphState &source_state,
                               std::vector<GraphState> *succ_states);

  // Returns true if a valid depth image was composed.
  static bool GetComposedDepthImage(const std::vector<unsigned short>
                                    &source_depth_image, const std::vector<unsigned short>
                                    &last_object_depth_image, std::vector<unsigned short> *composed_depth_image);

  bool GetComposedDepthImage(const std::vector<unsigned short> &source_depth_image,
                                  const std::vector<std::vector<unsigned char>> &source_color_image,
                                  const std::vector<unsigned short> &last_object_depth_image,
                                  const std::vector<std::vector<unsigned char>> &last_object_color_image,
                                  std::vector<unsigned short> *composed_depth_image,
                                  std::vector<std::vector<unsigned char>> *composed_color_image);

  bool GetSingleObjectDepthImage(const GraphState &single_object_graph_state,
                                 std::vector<unsigned short> *single_object_depth_image, bool after_refinement);

  bool GetSingleObjectHistogramScore(const GraphState &single_object_graph_state,
                                      double &histogram_score);

  // Computes the cost for the parent-child edge. Returns the adjusted child state, where the pose
  // of the last added object is adjusted using ICP and the computed state properties.
  int GetCost(const GraphState &source_state, const GraphState &child_state,
              const std::vector<unsigned short> &source_depth_image,
              const std::vector<std::vector<unsigned char>> &source_color_image,
              const std::vector<int> &parent_counted_pixels,
              std::vector<int> *child_counted_pixels,
              GraphState *adjusted_child_state,
              GraphStateProperties *state_properties,
              std::vector<unsigned short> *adjusted_child_depth_image,
              std::vector<std::vector<unsigned char>> *adjusted_child_color_image,
              std::vector<unsigned short> *unadjusted_child_depth_image,
              std::vector<std::vector<unsigned char>> *unadjusted_child_color_image,
              double &histogram_score);

  int GetColorOnlyCost(const GraphState &source_state, const GraphState &child_state,
              const std::vector<unsigned short> &source_depth_image,
              const std::vector<std::vector<unsigned char>> &source_color_image,
              const std::vector<int> &parent_counted_pixels,
              std::vector<int> *child_counted_pixels,
              GraphState *adjusted_child_state,
              GraphStateProperties *state_properties,
              std::vector<unsigned short> *adjusted_child_depth_image,
              std::vector<std::vector<unsigned char>> *adjusted_child_color_image,
              std::vector<unsigned short> *unadjusted_child_depth_image,
              std::vector<std::vector<unsigned char>> *unadjusted_child_color_image);

  double getColorDistanceCMC(uint32_t rgb_1, uint32_t rgb_2) const;
  double getColorDistance(uint32_t rgb_1, uint32_t rgb_2) const;
  double getColorDistance(uint8_t r1,uint8_t g1,uint8_t b1,uint8_t r2,uint8_t g2,uint8_t b2) const;
  int getNumColorNeighboursCMC(PointT point, const PointCloudPtr point_cloud) const;
  int getNumColorNeighbours(PointT point, vector<int> indices, const PointCloudPtr point_cloud) const;

  // Cost for newly rendered object. Input cloud must contain only newly rendered points.
  int GetTargetCost(const PointCloudPtr
                    partial_rendered_cloud);
  // Cost for points in observed cloud that can be computed based on the rendered cloud.
  int GetSourceCost(const PointCloudPtr full_rendered_cloud,
                    const ObjectState &last_object, const bool last_level,
                    const std::vector<int> &parent_counted_pixels,
                    std::vector<int> *child_counted_pixels);
  // NOTE: updated_counted_pixels should always be equal to the number of
  // points in the input point cloud.
  int GetLastLevelCost(const PointCloudPtr full_rendered_cloud,
                       const ObjectState &last_object,
                       const std::vector<int> &counted_pixels,
                       std::vector<int> *updated_counted_pixels);
  int GetColorCost(cv::Mat *cv_depth_image,cv::Mat *cv_color_image);

  // Computes the cost for the lazy parent-child edge. This is an admissible estimate of the true parent-child edge cost, computed without any
  // additional renderings. This requires the true source depth image and
  // unadjusted child depth image (pre-ICP).
  int GetLazyCost(const GraphState &source_state, const GraphState &child_state,
                  const std::vector<unsigned short> &source_depth_image,
                  const std::vector<std::vector<unsigned char>> &source_color_image,                  
                  const std::vector<unsigned short> &unadjusted_last_object_depth_image,
                  const std::vector<unsigned short> &adjusted_last_object_depth_image,
                  const GraphState &adjusted_last_object_state,
                  const std::vector<int> &parent_counted_pixels,
                  const double adjusted_last_object_histogram_score,
                  GraphState *adjusted_child_state,
                  GraphStateProperties *state_properties,
                  std::vector<unsigned short> *final_depth_image);

  // Returns true if parent is occluded by successor. Additionally returns min and max depth for newly rendered pixels
  // when occlusion-free.
  static bool IsOccluded(const std::vector<unsigned short> &parent_depth_image,
                         const std::vector<unsigned short> &succ_depth_image,
                         std::vector<int> *new_pixel_indices, unsigned short *min_succ_depth,
                         unsigned short *max_succ_depth);

  bool IsValidPose(GraphState s, int model_id, ContPose p,
                   bool after_refinement, int required_object_id) const;

  int rejected_histogram_count = 0;
  bool IsValidHistogram(int object_model_id, cv::Mat last_cv_obj_color_image, double threshold, double &base_distance);

  void LabelEuclideanClusters();
  std::vector<unsigned short> GetDepthImageFromPointCloud(
    const PointCloudPtr &cloud);

  // Sets a pixel of input_depth_image to max_range if the corresponding pixel
  // in masking_depth_image occludes the pixel in input_depth_image. Otherwise,
  // the value is retained.
  static std::vector<unsigned short> ApplyOcclusionMask(const
                                                        std::vector<unsigned short> input_depth_image,
                                                        const
                                                        std::vector<unsigned short> masking_depth_image);
  // Unused base class methods.
 public:
  bool InitializeEnv(const char *sEnvFile) {
    return false;
  };
  bool InitializeMDPCfg(MDPConfig *MDPCfg) {
    return true;
  };
  int  GetFromToHeuristic(int FromStateID, int ToStateID) {
    throw std::runtime_error("unimplement");
  };
  int  GetStartHeuristic(int stateID) {
    throw std::runtime_error("unimplement");
  };
  int  GetStartHeuristic(int q_id, int stateID) {
    throw std::runtime_error("unimplement");
  };
  void GetPreds(int TargetStateID, std::vector<int> *PredIDV,
                std::vector<int> *CostV) {};
  void SetAllActionsandAllOutcomes(CMDPSTATE *state) {};
  void SetAllPreds(CMDPSTATE *state) {};
  void PrintState(int stateID, bool bVerbose, FILE *fOut = NULL) {};
  void PrintEnv_Config(FILE *fOut) {};

};
} // namespace
