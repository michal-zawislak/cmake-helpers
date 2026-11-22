include_guard(GLOBAL)

add_library(mz_compile_options INTERFACE)
add_library(mz::compile_options ALIAS mz_compile_options)

if(CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
    target_compile_options(mz_compile_options INTERFACE
        /W4
        /permissive-
        /utf-8
        /Zc:__cplusplus
        /Zc:preprocessor
        /w14062
        /w14265
        /wd4251
        /wd4275
    )
elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND CMAKE_CXX_COMPILER_FRONTEND_VARIANT STREQUAL "MSVC")
    target_compile_options(mz_compile_options INTERFACE
        /W4
        /utf-8
        /Zc:__cplusplus
        /clang:-Wshadow
        /clang:-Wconversion
        /clang:-Wsign-conversion
        /clang:-Wold-style-cast
        /clang:-Wnon-virtual-dtor
        /clang:-Woverloaded-virtual
        /clang:-Wcast-align
        /clang:-Wnull-dereference
        /clang:-Wdouble-promotion
        /clang:-Wimplicit-fallthrough
        /clang:-Wextra-semi
        /clang:-Wswitch
        /clang:-Wswitch-enum
        -Wno-reserved-module-identifier
        -Wno-include-angled-in-module-purview
    )
else()
    target_compile_options(mz_compile_options INTERFACE
        -Wall 
        -Wextra 
        -Wpedantic 
        -Wshadow 
        -Wconversion 
        -Wsign-conversion
        -Wold-style-cast 
        -Wnon-virtual-dtor 
        -Woverloaded-virtual
        -Wcast-align 
        -Wnull-dereference 
        -Wdouble-promotion 
        -Wformat=2
        -Wimplicit-fallthrough 
        -Wextra-semi
    )
endif()