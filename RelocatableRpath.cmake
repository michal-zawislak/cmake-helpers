include_guard(GLOBAL)

function(mz_configure_install_rpath)
    if(NOT PROJECT_IS_TOP_LEVEL)
        return()
    endif()

    if(APPLE)
        set(base "@loader_path")
    elseif(NOT WIN32)
        set(base "$ORIGIN")
    else()
        return()
    endif()

    include(GNUInstallDirs)

    file(RELATIVE_PATH bin_to_lib
        "${CMAKE_INSTALL_FULL_BINDIR}" "${CMAKE_INSTALL_FULL_LIBDIR}")
    set(CMAKE_INSTALL_RPATH "${base}" "${base}/${bin_to_lib}" PARENT_SCOPE)
endfunction()