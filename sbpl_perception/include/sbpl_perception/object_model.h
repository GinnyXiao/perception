#pragma once

/**
 * @file object_model.h
 * @brief Object model
 * @author Venkatraman Narayanan
 * Carnegie Mellon University, 2015
 */

#include <sbpl_perception/object_state.h>

#include <perception_utils/pcl_typedefs.h>
#include <perception_utils/pcl_conversions.h>

#include <Eigen/Geometry>

#include <pcl/PolygonMesh.h>

class ObjectModel {
 public:
  ObjectModel(const pcl::PolygonMesh &mesh, const std::string name, const bool symmetric, const bool flipped);

  double GetInscribedRadius() const;

  double GetCircumscribedRadius() const;

  pcl::PolygonMeshPtr GetTransformedMesh(const ContPose & p, double table_height) const;

  pcl::PolygonMeshPtr GetTransformedMesh(const Eigen::Matrix4f &transform) const;

  // Returns true if point is within the mesh model, where the model has been
  // transformed by the given pose and height.
  std::vector<bool> PointsInsideMesh(const std::vector<Eigen::Vector3d> &points, const ContPose &pose, double table_height) const;

  // Returns true if point is within the convex hull of the 2D-projected mesh model, where the model has been
  // transformed by the given pose and height.
  std::vector<bool> PointsInsideFootprint(const std::vector<Eigen::Vector2d> &points, const ContPose &pose, double table_height) const;
  static void TransformPolyMesh(const pcl::PolygonMesh::Ptr
                       &mesh_in, pcl::PolygonMesh::Ptr &mesh_out, Eigen::Matrix4f transform);
  // Accessors
  const pcl::PolygonMesh &mesh() const {
    return mesh_;
  }
  std::string name() const {
    return name_;
  }
  bool symmetric() const {
    return symmetric_;
  }
  double min_x() const {
    return min_x_;
  }
  double min_y() const {
    return min_y_;
  }
  double min_z() const {
    return min_z_;
  }
  double max_x() const {
    return max_x_;
  }
  double max_y() const {
    return max_y_;
  }
  double max_z() const {
    return max_z_;
  }
  double GetInflationFactor() const{ 
    return inflation_factor_;
  }


  // Return the internal transform applied to the raw models (i.e, any scaling
  // and translation applied ahead of time before the search runs).
  const Eigen::Affine3f &preprocessing_transform() const {
    return preprocessing_transform_;
  }

  // Return the transform that aligns a raw model (i.e, the one provided to the
  // constructor) to a continuous pose (x,y,table_height,\theta) in the world
  // frame.
  Eigen::Affine3f GetRawModelToSceneTransform(const ContPose &p, double table_height) const;

 private:
  pcl::PolygonMesh mesh_;
  bool symmetric_;
  std::string name_;
  double min_x_, min_y_, min_z_; // Bounding box in default orientation
  double max_x_, max_y_, max_z_;
  pcl::PointCloud<pcl::PointXYZ>::Ptr convex_hull_footprint_; // Convex polygon footprint for the object in default orientation.
  Eigen::Affine3f preprocessing_transform_;
  // Inflation factor for the mesh, which is a function of the inscribed
  // radius. This is used in methods that check if a point is within the
  // footprint or volume of the mesh.
  double inflation_factor_;
  void SetObjectProperties();
};
