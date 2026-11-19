# DubStemMix for Linux (then Windows), PRD § 17. A JUCE app; this folder is distributed under the AGPLv3
# (see LICENSE), the rest of the repository under MIT.
# Run desktop/build.sh rather than cmake directly: it fetches Akai's SDK headers the engine is written against
# (the engine, src/DubEngine.cpp, is a fork of the MPC plugin and still uses its framework and its FX.h / Stems.h).
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

# Stem separation (PRD § 12) runs htdemucs_ft with ONNX Runtime (MIT, Microsoft), the version the Mac app uses.
# Its library comes from Microsoft's Maven Central package, which holds one build per system, and its C header
# from the archive the Mac app's Swift package downloads. The library is placed beside the program and loaded
# when a song is split; nothing is linked.
set(ORT_VERSION 1.24.2)
FetchContent_Declare(onnxruntime_libs
  URL "https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime/${ORT_VERSION}/onnxruntime-${ORT_VERSION}.jar"
  URL_HASH SHA256=f429cc9d64b3bcef00bfac921a6aa231b3c280bee2e55c27f2563035b1a44104
  DOWNLOAD_NAME onnxruntime-${ORT_VERSION}.zip)
FetchContent_Declare(onnxruntime_headers
  URL "https://download.onnxruntime.ai/pod-archive-onnxruntime-c-${ORT_VERSION}.zip"
  URL_HASH SHA256=f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54)
FetchContent_MakeAvailable(onnxruntime_libs onnxruntime_headers)
if(APPLE)
  set(ORT_LIBRARY "osx-aarch64/libonnxruntime.dylib")
elseif(WIN32)
  set(ORT_LIBRARY "win-x64/onnxruntime.dll")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
  set(ORT_LIBRARY "linux-aarch64/libonnxruntime.so")
else()
  set(ORT_LIBRARY "linux-x64/libonnxruntime.so")
endif()
set(ORT_LIBRARY "${onnxruntime_libs_SOURCE_DIR}/ai/onnxruntime/native/${ORT_LIBRARY}")
set(ORT_INCLUDE "${onnxruntime_headers_SOURCE_DIR}/Headers")
if(NOT EXISTS "${ORT_LIBRARY}" OR NOT EXISTS "${ORT_INCLUDE}/onnxruntime_c_api.h")
  message(FATAL_ERROR "ONNX Runtime ${ORT_VERSION} not found for this system")
endif()

juce_add_gui_app(dubstemmix-desktop
  PRODUCT_NAME "DubStemMix"
  NEEDS_CURL TRUE
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

# The MP3 encoder of session exports (PRD § 5.9): libmp3lame 3.100, unmodified, LGPL (Sources/LAME/COPYING),
# the same sources the Mac app builds.
file(GLOB LAME_SOURCES "${REPO}/Sources/LAME/*.c")
add_library(dubstemmix-lame STATIC ${LAME_SOURCES})
target_include_directories(dubstemmix-lame PRIVATE "${REPO}/Sources/LAME" PUBLIC "${REPO}/Sources/LAME/include")
target_compile_definitions(dubstemmix-lame PRIVATE STDC_HEADERS HAVE_STDINT_H HAVE_ERRNO_H HAVE_FCNTL_H HAVE_LIMITS_H ieee754_float32_t=float)
target_compile_options(dubstemmix-lame PRIVATE -w)   # third-party code, left as is

target_sources(dubstemmix-desktop PRIVATE
  src/Main.cpp
  src/Sources.cpp
  src/DubEngine.cpp
  ${DUB_DSP})

target_include_directories(dubstemmix-desktop PRIVATE "${SDK}" "${PLUGIN}" "${REPO}/Sources/DubDSP/include")
target_include_directories(dubstemmix-desktop SYSTEM PRIVATE "${ORT_INCLUDE}")
add_custom_command(TARGET dubstemmix-desktop POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "${ORT_LIBRARY}" "$<TARGET_FILE_DIR:dubstemmix-desktop>/"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "${onnxruntime_libs_SOURCE_DIR}/ThirdPartyNotices.txt"
          "$<TARGET_FILE_DIR:dubstemmix-desktop>/onnxruntime-ThirdPartyNotices.txt")

target_compile_definitions(dubstemmix-desktop PRIVATE
  JUCE_WEB_BROWSER=0
  JUCE_USE_MP3AUDIOFORMAT=1
  JUCE_PLUGINHOST_VST3=1
  JUCE_PLUGINHOST_LV2=1
  $<$<PLATFORM_ID:Darwin>:JUCE_PLUGINHOST_AU=1>
  JUCE_DISPLAY_SPLASH_SCREEN=0
  JUCE_APPLICATION_NAME_STRING="$<TARGET_PROPERTY:dubstemmix-desktop,JUCE_PRODUCT_NAME>"
  JUCE_APPLICATION_VERSION_STRING="$<TARGET_PROPERTY:dubstemmix-desktop,JUCE_VERSION>")

target_link_libraries(dubstemmix-desktop PRIVATE
  DubStemMixAssets
  dubstemmix-lame
  juce::juce_audio_utils
  juce::juce_audio_devices
  juce::juce_audio_formats
  juce::juce_cryptography
  juce::juce_gui_basics
  juce::juce_recommended_config_flags)
