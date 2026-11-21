include_guard(GLOBAL)

function(mz_configure_output_layout)
    if(NOT PROJECT_IS_TOP_LEVEL)
        return()
    endif()

    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${PROJECT_BINARY_DIR}/bin" PARENT_SCOPE)
    set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${PROJECT_BINARY_DIR}/lib" PARENT_SCOPE)
    set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${PROJECT_BINARY_DIR}/lib" PARENT_SCOPE)
endfunction()