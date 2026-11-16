# DubStemMix desktop mock-up (PRD § 17.2): the MPC plugin's engine in a small host with real audio and MIDI.
# Run desktop/build.sh rather than cmake directly: it fetches Akai's SDK headers the plugin is written against.
cmake_minimum_required(VERSION 3.20)
project(DubStemMixDesktop C CXX)

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

# Third-party bricks, pinned. All MIT-compatible (miniaudio: MIT-0, RtMidi: MIT-like, Dear ImGui: MIT, GLFW: zlib).
include(FetchContent)
FetchContent_Declare(miniaudio GIT_REPOSITORY https://github.com/mackron/miniaudio GIT_TAG 0.11.21 GIT_SHALLOW TRUE)
FetchContent_Declare(rtmidi GIT_REPOSITORY https://github.com/thestk/rtmidi GIT_TAG 6.0.0 GIT_SHALLOW TRUE)
FetchContent_Declare(imgui GIT_REPOSITORY https://github.com/ocornut/imgui GIT_TAG v1.91.5 GIT_SHALLOW TRUE)
FetchContent_Declare(glfw GIT_REPOSITORY https://github.com/glfw/glfw GIT_TAG 3.4 GIT_SHALLOW TRUE)

set(RTMIDI_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(RTMIDI_BUILD_STATIC_LIBS ON CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(RTMIDI_API_JACK OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(GLFW_INSTALL OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_WAYLAND OFF CACHE BOOL "" FORCE)

# miniaudio and imgui are used as plain sources: only fetch them.
FetchContent_GetProperties(miniaudio)
if(NOT miniaudio_POPULATED)
  FetchContent_Populate(miniaudio)
endif()
FetchContent_GetProperties(imgui)
if(NOT imgui_POPULATED)
  FetchContent_Populate(imgui)
endif()
FetchContent_MakeAvailable(rtmidi glfw)

find_package(OpenGL REQUIRED)
find_package(Threads REQUIRED)

# The effect kernels shared with the Mac app and the MPC plugin, built here as the C they are. (The MPC build
# goes through the plugin's dsp_*.cpp wrappers, C compiled as C++: clang takes it, GCC does not.)
file(GLOB DUB_DSP "${REPO}/Sources/DubDSP/*.c")

add_executable(dubstemmix-desktop
  src/main.cpp
  "${PLUGIN}/DubStemMix.cpp"
  ${DUB_DSP}
  "${imgui_SOURCE_DIR}/imgui.cpp"
  "${imgui_SOURCE_DIR}/imgui_draw.cpp"
  "${imgui_SOURCE_DIR}/imgui_tables.cpp"
  "${imgui_SOURCE_DIR}/imgui_widgets.cpp"
  "${imgui_SOURCE_DIR}/backends/imgui_impl_glfw.cpp"
  "${imgui_SOURCE_DIR}/backends/imgui_impl_opengl3.cpp")

target_include_directories(dubstemmix-desktop PRIVATE
  "${SDK}" "${PLUGIN}" "${REPO}/Sources/DubDSP/include" "${miniaudio_SOURCE_DIR}" "${imgui_SOURCE_DIR}" "${imgui_SOURCE_DIR}/backends")
target_link_libraries(dubstemmix-desktop PRIVATE rtmidi glfw OpenGL::GL Threads::Threads ${CMAKE_DL_LIBS})
if(APPLE)
  target_compile_definitions(dubstemmix-desktop PRIVATE GL_SILENCE_DEPRECATION)
  target_link_libraries(dubstemmix-desktop PRIVATE "-framework CoreAudio" "-framework AudioToolbox" "-framework CoreFoundation")
endif()
if(UNIX AND NOT APPLE)
  target_link_libraries(dubstemmix-desktop PRIVATE m)
endif()
