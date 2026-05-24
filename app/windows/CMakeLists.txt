# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(fh_radio_studio LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "fh-radio-studio")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100" /utf-8)
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")
set(FH_RADIO_STUDIO_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../..")
set(FH_RADIO_STUDIO_RUNTIME_DIR "${CMAKE_INSTALL_PREFIX}/runtime")
set(FH_RADIO_STUDIO_TOOLCHAIN_DIR "${CMAKE_INSTALL_PREFIX}/toolchain")
set(FH_RADIO_STUDIO_BUNDLED_UV_EXE "" CACHE FILEPATH
  "Optional uv executable to bundle next to the FH Radio Studio app.")
set(FH_RADIO_STUDIO_RELEASE_RUNTIME_INPUT_DIR "" CACHE PATH
  "Prepared release runtime project to bundle next to the FH Radio Studio app.")
set(FH_RADIO_STUDIO_RELEASE_TOOLCHAIN_INPUT_DIR "" CACHE PATH
  "Prepared release toolchain cache/Python directory to bundle next to the FH Radio Studio app.")
option(FH_RADIO_STUDIO_REQUIRE_BUNDLED_UV
  "Fail the Windows bundle build when a bundled uv executable is unavailable."
  OFF)
option(FH_RADIO_STUDIO_REQUIRE_RELEASE_RUNTIME
  "Fail the Windows bundle build when the prepared release runtime is unavailable."
  OFF)
option(FH_RADIO_STUDIO_REQUIRE_RELEASE_TOOLCHAIN
  "Fail the Windows bundle build when the prepared release toolchain is unavailable."
  OFF)
option(FH_RADIO_STUDIO_REQUIRE_RELEASE_AUDIO_TOOLS
  "Fail the Windows bundle build when prepared audio tools are unavailable."
  OFF)

if(NOT FH_RADIO_STUDIO_BUNDLED_UV_EXE AND DEFINED ENV{FH_RADIO_STUDIO_BUNDLED_UV_EXE})
  set(FH_RADIO_STUDIO_BUNDLED_UV_EXE "$ENV{FH_RADIO_STUDIO_BUNDLED_UV_EXE}")
endif()

if(NOT FH_RADIO_STUDIO_BUNDLED_UV_EXE)
  set(FH_RADIO_STUDIO_BUNDLED_UV_EXE
    "${FH_RADIO_STUDIO_REPO_ROOT}/.fh-radio-studio-dev/release-inputs/uv/windows/uv.exe")
endif()

if(NOT FH_RADIO_STUDIO_RELEASE_RUNTIME_INPUT_DIR)
  set(FH_RADIO_STUDIO_RELEASE_RUNTIME_INPUT_DIR
    "${FH_RADIO_STUDIO_REPO_ROOT}/.fh-radio-studio-dev/release-inputs/runtime")
endif()

if(NOT FH_RADIO_STUDIO_RELEASE_TOOLCHAIN_INPUT_DIR)
  set(FH_RADIO_STUDIO_RELEASE_TOOLCHAIN_INPUT_DIR
    "${FH_RADIO_STUDIO_REPO_ROOT}/.fh-radio-studio-dev/release-inputs/toolchain")
endif()

set(FH_RADIO_STUDIO_RELEASE_AUDIO_TOOLS_INPUT_DIR
  "${FH_RADIO_STUDIO_RELEASE_TOOLCHAIN_INPUT_DIR}/tools/audio")
if(EXISTS "${FH_RADIO_STUDIO_RELEASE_AUDIO_TOOLS_INPUT_DIR}/ffmpeg/ffmpeg.exe"
    AND EXISTS "${FH_RADIO_STUDIO_RELEASE_AUDIO_TOOLS_INPUT_DIR}/vgmstream/vgmstream-cli.exe"
    AND EXISTS "${FH_RADIO_STUDIO_RELEASE_AUDIO_TOOLS_INPUT_DIR}/fmod/fsbankcl.exe")
  set(FH_RADIO_STUDIO_RELEASE_AUDIO_TOOLS_READY TRUE)
else()
  set(FH_RADIO_STUDIO_RELEASE_AUDIO_TOOLS_READY FALSE)
endif()

if(NOT FH_RADIO_STUDIO_RELEASE_AUDIO_TOOLS_READY)
  if(FH_RADIO_STUDIO_REQUIRE_RELEASE_AUDIO_TOOLS)
    message(FATAL_ERROR
      "Prepared release audio tools not found; run uv run python tools/prepare_release_runtime.py or set FH_RADIO_STUDIO_RELEASE_TOOLCHAIN_INPUT_DIR.")
  else()
    message(STATUS
      "Prepared release audio tools not found; install-tools can repair them at runtime if network is available.")
  endif()
endif()

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

install(CODE "
  file(REMOVE_RECURSE \"${FH_RADIO_STUDIO_RUNTIME_DIR}\")
  " COMPONENT Runtime)

if(EXISTS "${FH_RADIO_STUDIO_RELEASE_RUNTIME_INPUT_DIR}/pyproject.toml")
  install(DIRECTORY "${FH_RADIO_STUDIO_RELEASE_RUNTIME_INPUT_DIR}/"
    DESTINATION "${FH_RADIO_STUDIO_RUNTIME_DIR}"
    COMPONENT Runtime
    PATTERN "__pycache__" EXCLUDE
    PATTERN "*.pyc" EXCLUDE
    PATTERN ".venv" EXCLUDE)
elseif(FH_RADIO_STUDIO_REQUIRE_RELEASE_RUNTIME)
  message(FATAL_ERROR
    "Prepared release runtime not found; run uv run python tools/prepare_release_runtime.py or set FH_RADIO_STUDIO_RELEASE_RUNTIME_INPUT_DIR.")
else()
  message(STATUS
    "Prepared release runtime not found; falling back to source runtime copy for local builds.")
  install(FILES
    "${FH_RADIO_STUDIO_REPO_ROOT}/pyproject.toml"
    "${FH_RADIO_STUDIO_REPO_ROOT}/uv.lock"
    DESTINATION "${FH_RADIO_STUDIO_RUNTIME_DIR}"
    COMPONENT Runtime)
  install(DIRECTORY "${FH_RADIO_STUDIO_REPO_ROOT}/backend"
    DESTINATION "${FH_RADIO_STUDIO_RUNTIME_DIR}"
    COMPONENT Runtime
    PATTERN "__pycache__" EXCLUDE
    PATTERN "*.pyc" EXCLUDE)
endif()

if(EXISTS "${FH_RADIO_STUDIO_RELEASE_TOOLCHAIN_INPUT_DIR}")
  install(CODE "
    file(REMOVE_RECURSE \"${FH_RADIO_STUDIO_TOOLCHAIN_DIR}\")
    " COMPONENT Runtime)
  install(DIRECTORY "${FH_RADIO_STUDIO_RELEASE_TOOLCHAIN_INPUT_DIR}/"
    DESTINATION "${FH_RADIO_STUDIO_TOOLCHAIN_DIR}"
    COMPONENT Runtime
    PATTERN "__pycache__" EXCLUDE
    PATTERN "*.pyc" EXCLUDE
    PATTERN "envs" EXCLUDE
    PATTERN ".seed-env" EXCLUDE
    PATTERN ".tool-install-env" EXCLUDE)
elseif(FH_RADIO_STUDIO_REQUIRE_RELEASE_TOOLCHAIN)
  message(FATAL_ERROR
    "Prepared release toolchain not found; run uv run python tools/prepare_release_runtime.py or set FH_RADIO_STUDIO_RELEASE_TOOLCHAIN_INPUT_DIR.")
else()
  message(STATUS
    "Prepared release toolchain not found; local builds may initialize toolchain on first run.")
endif()

if(FH_RADIO_STUDIO_BUNDLED_UV_EXE AND EXISTS "${FH_RADIO_STUDIO_BUNDLED_UV_EXE}")
  install(FILES "${FH_RADIO_STUDIO_BUNDLED_UV_EXE}"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/tools/uv"
    COMPONENT Runtime)
elseif(FH_RADIO_STUDIO_REQUIRE_BUNDLED_UV)
  message(FATAL_ERROR
    "Bundled uv executable not found; set FH_RADIO_STUDIO_BUNDLED_UV_EXE or prepare .fh-radio-studio-dev/release-inputs/uv/windows/uv.exe.")
else()
  message(STATUS
    "Bundled uv executable not found; set FH_RADIO_STUDIO_BUNDLED_UV_EXE to package uv.exe.")
endif()

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
