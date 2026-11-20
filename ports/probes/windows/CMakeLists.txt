cmake_minimum_required(VERSION 3.20)
project(recorder_sdk_probe LANGUAGES CXX)
add_library(wasapi_probe OBJECT wasapi.cpp)
