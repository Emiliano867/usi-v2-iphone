cmake_minimum_required(VERSION 3.8)
project(usi_collection_msgs)
find_package(ament_cmake REQUIRED)
find_package(rosidl_default_generators REQUIRED)
find_package(std_msgs REQUIRED)
rosidl_generate_interfaces(${PROJECT_NAME}
  "msg/SourceRecord.msg"
  "msg/FrameRecord.msg"
  "msg/PressureRecord.msg"
  "msg/TriggerRecord.msg"
  "msg/ClockRecord.msg"
  "msg/TrialRecord.msg"
  "msg/HealthRecord.msg"
  DEPENDENCIES std_msgs)
ament_export_dependencies(rosidl_default_runtime)
ament_package()
