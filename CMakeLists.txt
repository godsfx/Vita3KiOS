# Vita3KiOS - CMake Target Patch for iOS 16.5
cmake_minimum_required(VERSION 3.22)
project(Vita3K LANGUAGES C CXX ASM)

# iOS 16.5 Deployment Target & JIT Flags
if(IOS)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "16.5" CACHE STRING "Minimum iOS Version" FORCE)
    set(CMAKE_OSX_SYSROOT "iphoneos")
    set(CMAKE_XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2") # iPhone & iPad
    set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_CURRENT_SOURCE_DIR}/Vita3KiOS.entitlements")
    
    # Compiler options for iOS 16.5 ARM64 and JIT page protection support
    add_compile_options("-miphoneos-version-min=16.5" "-O3" "-ffast-math")
    add_definitions(-D__IOS__ -DMAP_JIT)
endif()
