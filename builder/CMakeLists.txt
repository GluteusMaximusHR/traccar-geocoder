cmake_minimum_required(VERSION 3.22)
project(traccar-geocoder-build LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Threads REQUIRED)
find_package(ZLIB REQUIRED)
find_package(BZip2 REQUIRED)
find_package(EXPAT REQUIRED)
include(FetchContent)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(FETCH_ABSEIL ON CACHE BOOL "" FORCE)
FetchContent_Declare(s2geometry
    URL https://codeload.github.com/google/s2geometry/tar.gz/refs/tags/v0.14.0
    URL_HASH SHA256=8c1f0a4b98472ed9df9807f5ec10ee57928cca388e16c13f430b652790d3ad8b
)
FetchContent_MakeAvailable(s2geometry)

add_executable(build-index src/build_index.cpp)

if(EXISTS /opt/homebrew/include)
    target_include_directories(build-index SYSTEM PRIVATE /opt/homebrew/include)
endif()

target_link_libraries(build-index PRIVATE
    s2
    ZLIB::ZLIB
    BZip2::BZip2
    EXPAT::EXPAT
    Threads::Threads
)
