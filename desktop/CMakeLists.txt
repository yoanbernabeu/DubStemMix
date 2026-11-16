# DubStemMix for Linux (then Windows), PRD § 17. A JUCE app; this folder is distributed under the AGPLv3
# (see LICENSE), the rest of the repository under MIT.
# Run desktop/build.sh rather than cmake directly: it fetches Akai's SDK headers the engine is written against.
cmake_minimum_required(VERSION 3.22)
project(DubStemMixDesktop VERSION 0.0.1 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(REPO "${CMAKE_CURRENT_SOURCE_DIR}/..")
set(PLUGIN "${REPO}/mpc/DubStemMix/src")
set(SDK "${REPO}/mpc/.sdk/framework")
if(NOT EXISTS "${SDK}/mpc_plugin.h")
  message(FATAL_ERROR "MPC plugin SDK not found in mpc/.sdk: run desktop/build.sh")
endif()

include(FetchContent)
FetchContent_Declare(JUCE GIT_REPOSITORY https://github.com/juce-framework/JUCE GIT_TAG 8.0.4 GIT_SHALLOW TRUE)
FetchContent_MakeAvailable(JUCE)

juce_add_gui_app(dubstemmix-desktop
  PRODUCT_NAME "DubStemMix"
  COMPANY_NAME "YoanDev"
  BUNDLE_ID "com.yoanbernabeu.DubStemMix.desktop")

# Fonts of the Mac app's look (PRD § 5.11), as fixed instances of the variable fonts in Sources/DubStemMix/Resources.
juce_add_binary_data(DubStemMixAssets SOURCES
  assets/Archivo-Label.ttf
  assets/Archivo-Text.ttf
  assets/JetBrainsMono-Medium.ttf)

# The effect kernels shared with the Mac app and the MPC plugin, built here as the C they are. (The MPC build
# goes through the plugin's dsp_*.cpp wrappers, C compiled as C++: clang takes it, GCC does not.)
file(GLOB DUB_DSP "${REPO}/Sources/DubDSP/*.c")

target_sources(dubstemmix-desktop PRIVATE
  src/Main.cpp
  "${PLUGIN}/DubStemMix.cpp"
  ${DUB_DSP})

target_include_directories(dubstemmix-desktop PRIVATE "${SDK}" "${PLUGIN}" "${REPO}/Sources/DubDSP/include")

target_compile_definitions(dubstemmix-desktop PRIVATE
  JUCE_WEB_BROWSER=0
  JUCE_USE_CURL=0
  JUCE_DISPLAY_SPLASH_SCREEN=0
  JUCE_APPLICATION_NAME_STRING="$<TARGET_PROPERTY:dubstemmix-desktop,JUCE_PRODUCT_NAME>"
  JUCE_APPLICATION_VERSION_STRING="$<TARGET_PROPERTY:dubstemmix-desktop,JUCE_VERSION>")

target_link_libraries(dubstemmix-desktop PRIVATE
  DubStemMixAssets
  juce::juce_audio_utils
  juce::juce_audio_devices
  juce::juce_gui_basics
  juce::juce_recommended_config_flags)
