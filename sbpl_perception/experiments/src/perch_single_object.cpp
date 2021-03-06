/**
 * @file perch.cpp
 * @brief Experiments to quantify performance
 * @author Venkatraman Narayanan
 * Carnegie Mellon University, 2015
 */

#include <ros/package.h>
#include <ros/ros.h>
#include <sbpl_perception/config_parser.h>
#include <sbpl_perception/object_recognizer.h>

#include <boost/filesystem.hpp>
#include <pcl/io/pcd_io.h>

using namespace std;
using namespace sbpl_perception;

const string kDebugDir = ros::package::getPath("sbpl_perception") +
                         "/visualization/";

int main(int argc, char **argv) {

  boost::mpi::environment env(argc, argv);
  std::shared_ptr<boost::mpi::communicator> world(new
                                                  boost::mpi::communicator());

  if (IsMaster(world)) {
    ros::init(argc, argv, "perch_experiments");
    ros::NodeHandle nh("~");
  }
  ObjectRecognizer object_recognizer(world);

  if (argc < 4) {
    cerr << "Usage: ./perch <path_to_config_file> <path_output_file_poses> <path_output_file_stats>"
         << endl;
    return -1;
  }

  boost::filesystem::path config_file_path = argv[1];
  boost::filesystem::path output_file_poses = argv[2];
  boost::filesystem::path output_file_stats = argv[3];

  if (!boost::filesystem::is_regular_file(config_file_path)) {
    cerr << "Invalid config file" << endl;
    return -1;
  }

  ofstream fs_poses, fs_stats;

  if (IsMaster(world)) {
    fs_poses.open (output_file_poses.string().c_str(),
                   std::ofstream::out | std::ofstream::app);
    fs_stats.open (output_file_stats.string().c_str(),
                   std::ofstream::out | std::ofstream::app);
  }

  string config_file = config_file_path.string();
  cout << config_file << endl;

  bool image_debug = false;
  string experiment_dir = kDebugDir + output_file_poses.stem().string() + "/";
  string debug_dir = experiment_dir + config_file_path.stem().string() + "/";

  if (IsMaster(world) &&
      !boost::filesystem::is_directory(experiment_dir)) {
    boost::filesystem::create_directory(experiment_dir);
  }

  if (IsMaster(world) &&
      !boost::filesystem::is_directory(debug_dir)) {
    boost::filesystem::create_directory(debug_dir);
  }

  object_recognizer.GetMutableEnvironment()->SetDebugOptions(image_debug);

  // Wait until all processes are ready for the planning phase.
  world->barrier();

  ConfigParser parser;
  parser.Parse(config_file);

  RecognitionInput input;
  input.x_min = parser.min_x;
  input.x_max = parser.max_x;
  input.y_min = parser.min_y;
  input.y_max = parser.max_y;
  input.table_height = parser.table_height;
  input.camera_pose = parser.camera_pose;
  input.heuristics_dir = ros::package::getPath("sbpl_perception") +
                         "/heuristics/" + config_file_path.stem().string();

  const auto &all_models = parser.ConvertModelNamesInFileToIDs(
                        object_recognizer.GetModelBank());

  int total_expands = 0;
  int total_valid_scenes = 0;
  int total_rendered_scenes = 0;
  int total_cost = 0;
  double total_time = 0.0;
  std::vector<ContPose> all_detected_poses;
  all_detected_poses.reserve(all_models.size());
  for (size_t ii = 0; ii < all_models.size(); ++ii) {

    string debug_subdir = debug_dir + std::to_string(ii) + "/";

    if (IsMaster(world) &&
        !boost::filesystem::is_directory(debug_subdir)) {
      boost::filesystem::create_directory(debug_subdir);
    }

    object_recognizer.GetMutableEnvironment()->SetDebugDir(debug_subdir);
    input.model_names = vector<string>{all_models[ii]};


    // Objects for storing the point clouds.
    pcl::PointCloud<PointT>::Ptr cloud_in(new PointCloud);

    // Read the input PCD file from disk.
    if (pcl::io::loadPCDFile<PointT>(parser.pcd_file_path.c_str(),
                                     *cloud_in) != 0) {
      cerr << "Could not find input PCD file!" << endl;
      return -1;
    }

    world->barrier();

    input.cloud = *cloud_in;

    // Should not have more than 1 element.
    vector<ContPose> detected_pose;
    object_recognizer.LocalizeObjects(input, &detected_pose);

    if (IsMaster(world)) {
      auto stats_vector = object_recognizer.GetLastPlanningEpisodeStats();
      EnvStats env_stats = object_recognizer.GetLastEnvStats();
      if (!detected_pose.empty()) {
        total_expands += env_stats.scenes_rendered;
        total_rendered_scenes += env_stats.scenes_rendered;
        total_valid_scenes += env_stats.scenes_valid;
        total_cost += stats_vector[0].cost;
        total_time += stats_vector[0].time;
        all_detected_poses.push_back(detected_pose[0]);
      }

      // cout << endl << "[[[[[[[[  Stats  ]]]]]]]]:" << endl;
      // cout << pcd_file_path << endl;
      // cout << succs_rendered << " " << succs_valid << " "  << stats_vector[0].expands
      //      << " " << stats_vector[0].time << " " << stats_vector[0].cost << endl;
      //
      // for (const auto &pose : object_poses) {
      //   cout << pose.x() << " " << pose.y() << " " << env_obj->GetTableHeight() << " "
      //        << pose.yaw() << endl;
      // }
    }
  }

  // Write output and statistics to file.
  if (IsMaster(world)) {

    // Now write to file
    boost::filesystem::path pcd_file(parser.pcd_file_path);
    string input_id = pcd_file.stem().native();

    fs_poses << input_id << endl;
    fs_stats << input_id << endl;
    fs_stats << total_rendered_scenes << " " << total_valid_scenes << " "
             << total_expands
             << " " << total_time << " " << total_cost << endl;

    for (const auto &pose : all_detected_poses) {
      fs_poses << pose.x() << " " << pose.y() << " " << input.table_height <<
               " " << pose.yaw() << endl;
    }

    fs_poses.close();
    fs_stats.close();
  }

  return 0;
}
