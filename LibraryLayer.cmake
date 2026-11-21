include_guard(GLOBAL)

include(GenerateExportHeader)

# mz_add_layer(PREFIX <prefix> LAYER <layer>)
#
# Creates the layer library `<prefix>_<layer>` (alias `<prefix>::<layer>`) and
# applies the policy shared by all layers:
#
#   * C++23 and `import std;`;
#   * hidden symbol visibility: only declarations marked <PREFIX>_<LAYER>_EXPORT
#     leave a shared library. The module keyword `export` controls *name*
#     visibility for importers; it does not export *symbols* from a DSO/DLL;
#   * a generated <prefix/<layer>/export.hpp> defining that macro. Module units
#     include it in their global module fragment;
#   * shared library versioning;
#   * install rules for the binaries, the module interface sources and the
#     export header.
#
function(mz_add_layer)
    cmake_parse_arguments(PARSE_ARGV 0 ARG "" "PREFIX;LAYER" "")
    if(ARG_UNPARSED_ARGUMENTS)
        message(FATAL_ERROR "mz_add_layer: unknown arguments: ${ARG_UNPARSED_ARGUMENTS}")
    endif()
    if(NOT ARG_PREFIX)
        message(FATAL_ERROR "mz_add_layer: PREFIX is required")
    endif()
    if(NOT ARG_LAYER)
        message(FATAL_ERROR "mz_add_layer: LAYER is required")
    endif()
    if(NOT PROJECT_VERSION)
        message(FATAL_ERROR "mz_add_layer: project() must specify VERSION")
    endif()

    set(target "${ARG_PREFIX}_${ARG_LAYER}")
    string(TOUPPER "${target}" macro_prefix)

    add_library(${target})
    add_library(${ARG_PREFIX}::${ARG_LAYER} ALIAS ${target})

    set_target_properties(${target} PROPERTIES
        CXX_VISIBILITY_PRESET hidden
        VISIBILITY_INLINES_HIDDEN ON
        VERSION ${PROJECT_VERSION}
        SOVERSION ${PROJECT_VERSION_MAJOR}
        EXPORT_NAME ${ARG_LAYER}
    )

    set(include_dir "${CMAKE_CURRENT_BINARY_DIR}/include")
    set(export_header "${include_dir}/library/${ARG_LAYER}/export.hpp")
    generate_export_header(${target} EXPORT_FILE_NAME "${export_header}")
    target_sources(${target}
        PUBLIC
            FILE_SET HEADERS
            BASE_DIRS "${include_dir}"
            FILES "${export_header}"
    )

    get_target_property(type ${target} TYPE)
    if(type STREQUAL "STATIC_LIBRARY")
        target_compile_definitions(${target} PUBLIC ${macro_prefix}_STATIC_DEFINE)
    elseif(type STREQUAL "SHARED_LIBRARY" AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
        target_link_options(${target} PRIVATE LINKER:--no-undefined)
        target_link_options(${target} PRIVATE LINKER:--exclude-libs,ALL)
    endif()
endfunction()
