#[=======================================================================[.rst:
Coverage
--------

Adds a ``Coverage`` build configuration that is "Debug + instrumentation":

  GCC                 -> gcov  (--coverage)      report: gcovr
  Clang               -> LLVM  (source-based)    report: llvm-cov
  Clang + CLANG_GCOV  -> gcov  (--coverage)      report: gcovr (via llvm-cov gcov)
  clang-cl (Windows)  -> LLVM  (source-based)    report: llvm-cov
  MSVC (Windows)      -> /PROFILE + Microsoft.CodeCoverage.Console (experimental)

Usage (top-level CMakeLists.txt, after ``project()``, before any target)::

  list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
  include(Coverage)
  mz_add_coverage_configuration()            # options: GLOBAL, MCDC, CLANG_GCOV

  add_library(core ...)
  add_library(net ...)
  mz_target_enable_coverage(core net)        # instrument only what you own

  mz_add_coverage_report_target(coverage
      TARGETS unit_tests
      GCOVR_CONFIG cmake/gcovr.cfg.in     # optional, see below
      MSVC_CONFIG  cmake/coverage.config.in
      GENHTML)                            # optional: also a genhtml (lcov) report

Requires CMake 3.21 or later.

Single-config generators: ``cmake -DCMAKE_BUILD_TYPE=Coverage``
Multi-config generators:  ``cmake --build . --config Coverage``
#]=======================================================================]

include_guard(GLOBAL)
include(CheckCompilerFlag)

# --------------------------------------------------------------------------
# Internal: LLVM profile runtime for clang-cl. CMake runs lld-link directly,
# so the clang driver never adds clang_rt.profile for us.
# --------------------------------------------------------------------------
function(_coverage_clang_cl_profile_runtime result_var lang)
    get_filename_component(compiler_dir "${CMAKE_${lang}_COMPILER}" DIRECTORY)
    find_program(clang_driver NAMES clang clang.exe HINTS "${compiler_dir}" NO_DEFAULT_PATH)
    if(NOT clang_driver)
        message(FATAL_ERROR "Coverage: cannot find clang driver next to ${CMAKE_${lang}_COMPILER}")
    endif()

    execute_process(
        COMMAND "${clang_driver}" -print-resource-dir
        OUTPUT_VARIABLE resource_dir
        OUTPUT_STRIP_TRAILING_WHITESPACE
        COMMAND_ERROR_IS_FATAL ANY
    )

    string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" processor)
    if(processor MATCHES "^(amd64|x86_64)$")
        set(arch x86_64)
    elseif(processor MATCHES "^(arm64|aarch64)$")
        set(arch aarch64)
    else()
        set(arch i386)
    endif()

    set(runtime "${resource_dir}/lib/windows/clang_rt.profile-${arch}.lib")
    if(NOT EXISTS "${runtime}")
        message(FATAL_ERROR "Coverage: LLVM profile runtime not found: ${runtime}")
    endif()
    set(${result_var} "${runtime}" PARENT_SCOPE)
endfunction()

# --------------------------------------------------------------------------
# Internal: the compiler the coverage tools must match (CXX if enabled, else
# C). Returns its symlink-resolved file name, the directories to search for
# tools of the same version (resolved one first, so /usr/bin/clang++-22 finds
# /usr/lib/llvm-22/bin), its major version and its compiler ID.
# --------------------------------------------------------------------------
function(_coverage_compiler name_var dirs_var major_var id_var)
    get_property(enabled_languages GLOBAL PROPERTY ENABLED_LANGUAGES)
    if("CXX" IN_LIST enabled_languages)
        set(lang CXX)
    else()
        set(lang C)
    endif()
    set(compiler "${CMAKE_${lang}_COMPILER}")
    file(REAL_PATH "${compiler}" real)
    cmake_path(GET real FILENAME name)
    cmake_path(GET real PARENT_PATH real_dir)
    cmake_path(GET compiler PARENT_PATH dir)
    string(REGEX MATCH "^[0-9]+" major "${CMAKE_${lang}_COMPILER_VERSION}")

    set(${name_var} "${name}" PARENT_SCOPE)
    set(${dirs_var} "${real_dir};${dir}" PARENT_SCOPE)
    set(${major_var} "${major}" PARENT_SCOPE)
    set(${id_var} "${CMAKE_${lang}_COMPILER_ID}" PARENT_SCOPE)
endfunction()

# --------------------------------------------------------------------------
# Internal: find an LLVM tool (llvm-cov, llvm-profdata) of the compiler's
# version, preferring <tool>-<major>. Sets the cache variable <var>.
# --------------------------------------------------------------------------
function(_coverage_find_llvm_tool var tool)
    _coverage_compiler(compiler_name compiler_dirs compiler_major compiler_id)
    find_program(${var} NAMES ${tool}-${compiler_major} ${tool} HINTS ${compiler_dirs})
endfunction()

# --------------------------------------------------------------------------
# Internal: whether <flag> works for <lang> together with the coverage
# options of <mode> (gcov | llvm). Checked with them, because Clang only
# warns about an unused profiling option on its own, which counts as failure.
# The result is cached as COVERAGE_<LANG>_<MODE>_<FLAG>.
# --------------------------------------------------------------------------
function(_coverage_check_flag result_var lang mode flag compile_options link_options)
    string(MAKE_C_IDENTIFIER "COVERAGE_${lang}_${mode}${flag}" cache_var)
    string(TOUPPER "${cache_var}" cache_var)
    list(JOIN compile_options " " CMAKE_REQUIRED_FLAGS)
    set(CMAKE_REQUIRED_LINK_OPTIONS ${link_options})
    check_compiler_flag(${lang} "${flag}" ${cache_var})
    set(${result_var} "${${cache_var}}" PARENT_SCOPE)
endfunction()

# --------------------------------------------------------------------------
# Internal: a report target that can't run. Building it prints the reason
# (the remaining arguments, concatenated) and fails, instead of "unknown
# target" or a silent `cmake -E false`. It has no dependencies, so it fails
# before anything else is built.
# --------------------------------------------------------------------------
function(_coverage_error_target name)
    list(JOIN ARGN "" reason)
    add_custom_target(${name}
        COMMAND "${CMAKE_COMMAND}" -E echo "${name}: ${reason}"
        COMMAND "${CMAKE_COMMAND}" -E false
        VERBATIM)
endfunction()

# --------------------------------------------------------------------------
# mz_add_coverage_configuration([LANGUAGES <lang>...] [GLOBAL] [MCDC] [CLANG_GCOV])
#
# * Registers the Coverage configuration.
# * Gives it the same base flags as Debug.
# * Creates the interface library coverage::options carrying the
#   instrumentation flags (active in the Coverage configuration only).
#
# By default nothing is instrumented until you call mz_target_enable_coverage().
# With GLOBAL, the instrumentation flags are also put into
# CMAKE_<LANG>_FLAGS_COVERAGE / CMAKE_*_LINKER_FLAGS_COVERAGE so that every
# target in the build (including in-tree third-party code) is instrumented.
# Do not combine GLOBAL with mz_target_enable_coverage().
#
# Where the compiler supports them, these are added too:
#   -fprofile-update=prefer-atomic  (GCC, Clang) counters stay exact when
#       tests use threads. GCC only switches to atomic counters by itself
#       with -pthread, which CMake doesn't pass on glibc 2.34 and later.
#   -fprofile-abs-path              (GCC) absolute paths in the .gcno files,
#       so gcovr finds the sources even if something (e.g. ccache base_dir)
#       made the compiler's paths relative.
#
# MCDC        Also measure MC/DC (condition) coverage: -fcondition-coverage
#             with GCC 14+, -fcoverage-mcdc with Clang 18+ (source-based
#             only). Configuration fails if the compiler can't do it.
# CLANG_GCOV  With Clang, use GCC's gcov format (--coverage) instead of
#             source-based coverage. The report then comes from gcovr, like
#             for GCC: Cobertura/SonarQube output and GCOVR_CONFIG work for
#             Clang too. Source-based coverage is more precise (regions in a
#             line, MC/DC). Not available with clang-cl.
#
# Sets in the caller's scope: COVERAGE_BACKEND (gcov | llvm | msvc) and
# COVERAGE_MCDC.
# --------------------------------------------------------------------------
function(mz_add_coverage_configuration)
    cmake_parse_arguments(PARSE_ARGV 0 ARG "GLOBAL;MCDC;CLANG_GCOV" "" "LANGUAGES")
    if(NOT ARG_LANGUAGES)
        set(ARG_LANGUAGES C CXX)
    endif()
    if(ARG_UNPARSED_ARGUMENTS)
        message(FATAL_ERROR "mz_add_coverage_configuration: unknown arguments: ${ARG_UNPARSED_ARGUMENTS}")
    endif()

    # --- Register the configuration ---------------------------------------
    get_property(is_multi_config GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
    if(is_multi_config)
        if(NOT "Coverage" IN_LIST CMAKE_CONFIGURATION_TYPES)
            list(APPEND CMAKE_CONFIGURATION_TYPES Coverage)
            set(CMAKE_CONFIGURATION_TYPES "${CMAKE_CONFIGURATION_TYPES}"
                CACHE STRING "Available build configurations" FORCE)
        endif()
    elseif(DEFINED CACHE{CMAKE_BUILD_TYPE})
        set_property(CACHE CMAKE_BUILD_TYPE APPEND PROPERTY STRINGS Coverage)
    endif()
    # Treat Coverage like Debug for the legacy debug/optimized keywords.
    # Unset means "Debug only", so keep Debug when adding Coverage.
    get_property(debug_configs GLOBAL PROPERTY DEBUG_CONFIGURATIONS)
    if(NOT debug_configs)
        set(debug_configs Debug)
    endif()
    if(NOT "Coverage" IN_LIST debug_configs)
        set_property(GLOBAL PROPERTY DEBUG_CONFIGURATIONS ${debug_configs} Coverage)
    endif()

    # --- Toolchain detection ----------------------------------------------
    get_property(enabled_languages GLOBAL PROPERTY ENABLED_LANGUAGES)
    set(languages "")
    set(compile_options "")
    set(link_options "")
    set(backend "")

    foreach(lang IN LISTS ARG_LANGUAGES)
        if(NOT lang IN_LIST enabled_languages)
            continue()
        endif()
        list(APPEND languages ${lang})

        set(id       "${CMAKE_${lang}_COMPILER_ID}")
        set(frontend "${CMAKE_${lang}_COMPILER_FRONTEND_VARIANT}")
        set(extra_base_flags "")
        set(optional_flags "")
        set(mcdc_flag "")

        if(id STREQUAL "GNU")
            set(this_backend gcov)
            set(lang_compile --coverage)
            set(lang_link    --coverage)
            set(extra_base_flags -O0)
            set(optional_flags -fprofile-update=prefer-atomic -fprofile-abs-path)
            set(mcdc_flag -fcondition-coverage)
            set(mcdc_needs "GCC 14 or later")

        elseif(id MATCHES "^(Clang|AppleClang)$" AND NOT frontend STREQUAL "MSVC")
            if(ARG_CLANG_GCOV)
                # gcov-format data, reported by gcovr through `llvm-cov gcov`
                set(this_backend gcov)
                set(lang_compile --coverage)
                set(lang_link    --coverage)
                set(mcdc_needs "source-based coverage (without CLANG_GCOV)")
            else()
                set(this_backend llvm)
                set(lang_compile -fprofile-instr-generate -fcoverage-mapping)
                set(lang_link    -fprofile-instr-generate)
                set(mcdc_flag -fcoverage-mcdc)
                set(mcdc_needs "Clang 18 or later")
            endif()
            set(extra_base_flags -O0)
            set(optional_flags -fprofile-update=prefer-atomic)

        elseif(id STREQUAL "Clang" AND frontend STREQUAL "MSVC")   # clang-cl
            if(ARG_CLANG_GCOV)
                message(FATAL_ERROR "Coverage: CLANG_GCOV is not supported with clang-cl")
            endif()
            set(this_backend llvm)
            _coverage_clang_cl_profile_runtime(profile_runtime ${lang})
            set(lang_compile -fprofile-instr-generate -fcoverage-mapping)
            set(lang_link    /DEBUG "/defaultlib:${profile_runtime}")
            set(optional_flags -fprofile-update=prefer-atomic)
            set(mcdc_flag -fcoverage-mcdc)
            set(mcdc_needs "Clang 18 or later")

        elseif(id STREQUAL "MSVC")
            # Microsoft.CodeCoverage.Console instruments the linked binary;
            # it needs /PROFILE (implies /DEBUG) and a PDB.
            set(this_backend msvc)
            set(lang_compile "")
            set(lang_link    /PROFILE)
            set(mcdc_needs "GCC or Clang (MSVC has no MC/DC coverage)")

        else()
            message(FATAL_ERROR
                "Coverage: unsupported ${lang} compiler '${id}' (frontend '${frontend}')")
        endif()

        foreach(flag IN LISTS optional_flags)
            _coverage_check_flag(supported ${lang} ${this_backend} ${flag}
                                 "${lang_compile}" "${lang_link}")
            if(supported)
                list(APPEND lang_compile ${flag})
            endif()
        endforeach()
        if(ARG_MCDC)
            set(supported OFF)
            if(mcdc_flag)
                _coverage_check_flag(supported ${lang} ${this_backend} ${mcdc_flag}
                                     "${lang_compile}" "${lang_link}")
            endif()
            if(NOT supported)
                message(FATAL_ERROR "Coverage: MCDC needs ${mcdc_needs} - the ${lang} "
                                    "compiler is ${id} ${CMAKE_${lang}_COMPILER_VERSION}")
            endif()
            list(APPEND lang_compile ${mcdc_flag})
        endif()

        if(backend AND NOT backend STREQUAL this_backend)
            message(FATAL_ERROR "Coverage: all languages must use the same coverage "
                                "toolchain (found ${backend} and ${this_backend})")
        endif()
        set(backend ${this_backend})
        list(APPEND compile_options ${lang_compile})
        list(APPEND link_options    ${lang_link})

        # Base flags: as close to Debug as possible
        set(flags "${CMAKE_${lang}_FLAGS_DEBUG} ${extra_base_flags}")
        if(ARG_GLOBAL)
            list(JOIN lang_compile " " lang_compile_string)
            string(APPEND flags " ${lang_compile_string}")
        endif()
        string(STRIP "${flags}" flags)
        set(CMAKE_${lang}_FLAGS_COVERAGE "${flags}" PARENT_SCOPE)
    endforeach()

    if(NOT backend)
        message(FATAL_ERROR "Coverage: none of the languages '${ARG_LANGUAGES}' is enabled")
    endif()
    list(REMOVE_DUPLICATES compile_options)
    list(REMOVE_DUPLICATES link_options)

    # --- Linker flag variables (GLOBAL only; Debug's /INCREMENTAL etc. are
    #     deliberately not inherited, they conflict with /PROFILE) ----------
    set(link_string "")
    if(ARG_GLOBAL)
        foreach(opt IN LISTS link_options)
            if(opt MATCHES " ")
                set(opt "\"${opt}\"")
            endif()
            string(APPEND link_string " ${opt}")
        endforeach()
        string(STRIP "${link_string}" link_string)
    endif()
    foreach(kind IN ITEMS EXE SHARED MODULE)
        set(CMAKE_${kind}_LINKER_FLAGS_COVERAGE "${link_string}" PARENT_SCOPE)
    endforeach()

    # --- Debug-like CRT / debug info on MSVC ------------------------------
    if(MSVC AND NOT DEFINED CMAKE_MSVC_RUNTIME_LIBRARY)
        # Same as CMake's default, with Coverage treated like Debug
        set(CMAKE_MSVC_RUNTIME_LIBRARY
            "MultiThreaded$<$<CONFIG:Debug,Coverage>:Debug>DLL" PARENT_SCOPE)
    endif()
    if(MSVC AND POLICY CMP0141)
        cmake_policy(GET CMP0141 policy_cmp0141)
        if(policy_cmp0141 STREQUAL "NEW" AND NOT DEFINED CMAKE_MSVC_DEBUG_INFORMATION_FORMAT)
            # With CMP0141 NEW, /Zi is no longer part of the CMAKE_*_FLAGS_DEBUG
            # defaults. Same as CMake's default (Debug, RelWithDebInfo) plus
            # Coverage. If you set this variable yourself, include Coverage.
            set(CMAKE_MSVC_DEBUG_INFORMATION_FORMAT
                "$<$<CONFIG:Debug,RelWithDebInfo,Coverage>:ProgramDatabase>" PARENT_SCOPE)
        endif()
    endif()
    if(NOT DEFINED CMAKE_MAP_IMPORTED_CONFIG_COVERAGE)
        # Prefer Debug builds of imported packages. Without a match the target
        # counts as not found, so also accept the other standard configs, the
        # None/NoConfig configs of distro packages and (trailing empty element)
        # the config-less IMPORTED_LOCATION.
        set(CMAKE_MAP_IMPORTED_CONFIG_COVERAGE
            "Debug;RelWithDebInfo;Release;MinSizeRel;None;NoConfig;" PARENT_SCOPE)
    endif()

    # --- coverage::options -------------------------------------------------
    if(NOT TARGET coverage_options)
        add_library(coverage_options INTERFACE)
        add_library(coverage::options ALIAS coverage_options)
        list(JOIN languages "," language_list)
        if(compile_options)
            target_compile_options(coverage_options INTERFACE
                "$<$<AND:$<CONFIG:Coverage>,$<COMPILE_LANGUAGE:${language_list}>>:${compile_options}>")
        endif()
        target_link_options(coverage_options INTERFACE
            "$<$<CONFIG:Coverage>:${link_options}>")
    endif()

    set(COVERAGE_BACKEND ${backend} PARENT_SCOPE)
    set(COVERAGE_MCDC ${ARG_MCDC} PARENT_SCOPE)
    list(JOIN compile_options " " shown_options)
    message(STATUS "Coverage configuration enabled (backend: ${backend}, flags: ${shown_options})")
endfunction()

# --------------------------------------------------------------------------
# mz_target_enable_coverage(<target>... [PRIVATE|PUBLIC|INTERFACE])
#
# Instruments each <target> in the Coverage configuration. With the default
# PRIVATE, only <target>'s own sources are compiled with instrumentation,
# while the link options still propagate to whatever finally links it
# (via $<LINK_ONLY:>), so static libraries just work.
#
# For an INTERFACE (header-only) library the default is INTERFACE: the code
# is compiled in its consumers (e.g. the test sources), so those get
# instrumented too; filter the report with EXCLUDE or a config template.
#
# An explicit scope keyword applies to every target in the call.
#
# The dependency is build-only ($<BUILD_INTERFACE:>), so install(EXPORT) of
# an instrumented target works.
# --------------------------------------------------------------------------
function(mz_target_enable_coverage)
    cmake_parse_arguments(PARSE_ARGV 0 ARG "PRIVATE;PUBLIC;INTERFACE" "" "")
    if(NOT TARGET coverage::options)
        message(FATAL_ERROR "mz_target_enable_coverage: call mz_add_coverage_configuration() first")
    endif()
    if(NOT ARG_UNPARSED_ARGUMENTS)
        message(FATAL_ERROR "mz_target_enable_coverage: no targets given")
    endif()
    set(scope "")
    foreach(keyword IN ITEMS PRIVATE PUBLIC INTERFACE)
        if(ARG_${keyword})
            if(scope)
                message(FATAL_ERROR "mz_target_enable_coverage: give only one of PRIVATE, PUBLIC, INTERFACE")
            endif()
            set(scope ${keyword})
        endif()
    endforeach()

    foreach(target IN LISTS ARG_UNPARSED_ARGUMENTS)
        if(NOT TARGET ${target})
            message(FATAL_ERROR "mz_target_enable_coverage: '${target}' is not a target")
        endif()
        set(target_scope "${scope}")
        if(NOT target_scope)
            get_target_property(type ${target} TYPE)
            if(type STREQUAL "INTERFACE_LIBRARY")
                set(target_scope INTERFACE)
            else()
                set(target_scope PRIVATE)
            endif()
        endif()
        target_link_libraries(${target} ${target_scope} $<BUILD_INTERFACE:coverage::options>)
    endforeach()
endfunction()

# --------------------------------------------------------------------------
# mz_add_coverage_report_target(<name>
#     TARGETS <target>...        # executables / shared libs to analyse
#     [TEST_COMMAND <cmd>...]    # default: ctest -C Coverage --output-on-failure
#     [GCOVR_CONFIG <file.in>]   # GCC: template of a gcovr config file
#     [MSVC_CONFIG <file.in>]    # MSVC: template of a settings XML file
#     [EXCLUDE <regex>...]       # files to leave out of the report
#     [GENHTML]                  # also render coverage.lcov with genhtml
#     [OUTPUT_DIRECTORY <dir>])  # default: <build>/coverage
#
# Outputs in <dir>:
#   gcov (gcovr)  coverage.xml (Cobertura), coverage.lcov, index.html
#   llvm          coverage.lcov, html/index.html
#   msvc          coverage.xml (Cobertura)
#   GENHTML       genhtml/index.html (gcov and llvm; needs lcov's genhtml)
# Without GCOVR_CONFIG, gcovr also gets --exclude-throw-branches: branches
# the compiler adds for exception handling don't count.
#
# EXCLUDE: gcovr matches a relative regex against the path relative to the
# build directory, llvm-cov searches the absolute path; a pattern like
# "(^|.*/)tests/" works for both. Both also exclude _deps/ (FetchContent
# sources). With GCOVR_CONFIG, these are added to the file's own excludes.
# On MSVC, EXCLUDE is ignored (with a warning): use MSVC_CONFIG.
#
# GCOVR_CONFIG: a gcovr config file template (gcovr's own format, e.g.
# `cobertura = @COVERAGE_OUTPUT_DIR@/cobertura.xml`). It replaces the
# module's default outputs and options; the module still passes the build
# tree to search, the excludes, and the gcov to use unless the template sets
# gcov-executable itself.
#
# Templates go through configure_file(@ONLY). Available variables:
#   @COVERAGE_SOURCE_DIR@ @COVERAGE_BINARY_DIR@ @COVERAGE_OUTPUT_DIR@
#   @COVERAGE_GCOV_EXECUTABLE@     (gcov only: the gcov matching the compiler,
#                                  `llvm-cov-<N> gcov` with CLANG_GCOV)
#   @COVERAGE_MODULE_DIRECTORIES@  (MSVC only: <Directory> elements for TARGETS)
# Generator expressions in an MSVC template are evaluated.
#
# The target always exists. When it can't produce a report (a tool is
# missing, or a single-config tree isn't configured as Coverage), building
# it prints the reason and fails, without building anything first. In a
# multi-config tree, building it in another configuration fails with a
# message (after TARGETS are built, as the configuration is only known then).
# --------------------------------------------------------------------------
function(mz_add_coverage_report_target name)
    cmake_parse_arguments(PARSE_ARGV 1 ARG "GENHTML"
        "OUTPUT_DIRECTORY;GCOVR_CONFIG;MSVC_CONFIG" "TARGETS;TEST_COMMAND;EXCLUDE")

    if(NOT COVERAGE_BACKEND)
        message(FATAL_ERROR "mz_add_coverage_report_target: call mz_add_coverage_configuration() first")
    endif()
    if(NOT ARG_TARGETS)
        message(FATAL_ERROR "mz_add_coverage_report_target: TARGETS is required")
    endif()
    if(NOT ARG_OUTPUT_DIRECTORY)
        set(ARG_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/coverage")
    endif()
    if(NOT ARG_TEST_COMMAND)
        set(ARG_TEST_COMMAND "${CMAKE_CTEST_COMMAND}" -C Coverage --output-on-failure)
    endif()
    if(COVERAGE_BACKEND STREQUAL "msvc")
        if(ARG_EXCLUDE)
            message(WARNING "mz_add_coverage_report_target(${name}): EXCLUDE is not supported "
                            "by the MSVC backend - put the excludes in MSVC_CONFIG")
        endif()
        if(ARG_GENHTML)
            message(WARNING "mz_add_coverage_report_target(${name}): GENHTML is not supported "
                            "by the MSVC backend (it writes Cobertura only) - ignored")
            set(ARG_GENHTML OFF)
        endif()
    endif()
    # Matches both relative (gcovr) and absolute (llvm-cov) paths
    list(APPEND ARG_EXCLUDE "(^|.*/)_deps/")

    set(out "${ARG_OUTPUT_DIRECTORY}")
    set(COVERAGE_SOURCE_DIR "${CMAKE_SOURCE_DIR}")
    set(COVERAGE_BINARY_DIR "${CMAKE_BINARY_DIR}")
    set(COVERAGE_OUTPUT_DIR "${out}")

    # Single-config tree in another build type: there is nothing to measure,
    # so don't look for tools or build TARGETS, just explain
    get_property(is_multi_config GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
    string(TOUPPER "${CMAKE_BUILD_TYPE}" build_type)
    if(NOT is_multi_config AND NOT build_type STREQUAL "COVERAGE")
        if(CMAKE_BUILD_TYPE)
            set(current "as '${CMAKE_BUILD_TYPE}'")
        else()
            set(current "without a build type")
        endif()
        _coverage_error_target(${name} "this build tree is configured ${current} - "
            "configure one with -DCMAKE_BUILD_TYPE=Coverage")
        return()
    endif()

    # Multi-config: the configuration is only known at build time
    set(config_guard
        COMMAND "${CMAKE_COMMAND}" -E $<IF:$<CONFIG:Coverage>,true,echo>
                "${name}: built in configuration '$<CONFIG>' - build with --config Coverage"
        COMMAND "${CMAKE_COMMAND}" -E $<IF:$<CONFIG:Coverage>,true,false>)

    # genhtml (from lcov) renders the coverage.lcov that gcovr / llvm-cov write
    set(genhtml_command "")
    if(ARG_GENHTML)
        find_program(COVERAGE_GENHTML_EXECUTABLE genhtml)
        if(NOT COVERAGE_GENHTML_EXECUTABLE)
            string(CONCAT reason "genhtml not found - install lcov "
                                 "or set COVERAGE_GENHTML_EXECUTABLE")
            message(WARNING "Coverage: ${reason}")
            _coverage_error_target(${name} "${reason}")
            return()
        endif()
        # gcovr writes hex MD5 line checksums, genhtml 2.x expects base64 and
        # stops at the first source page (even with --no-checksum), so it
        # gets a copy without them
        file(WRITE "${out}/genhtml-input.cmake" [==[
file(READ "${IN}" content)
string(REGEX REPLACE "(\nDA:[0-9]+,-?[0-9]+),[^\n]*" "\\1" content "${content}")
file(WRITE "${OUT}" "${content}")
]==])
        set(genhtml_command
            COMMAND "${CMAKE_COMMAND}" "-DIN=${out}/coverage.lcov" "-DOUT=${out}/genhtml.lcov"
                    -P "${out}/genhtml-input.cmake"
            COMMAND "${COVERAGE_GENHTML_EXECUTABLE}" "${out}/genhtml.lcov"
                    --output-directory "${out}/genhtml"
                    --branch-coverage --demangle-cpp --quiet)
    endif()

    # ---- gcov (GCC, or Clang with CLANG_GCOV) + gcovr --------------------
    if(COVERAGE_BACKEND STREQUAL "gcov")
        find_program(COVERAGE_GCOVR_EXECUTABLE gcovr)
        if(NOT COVERAGE_GCOVR_EXECUTABLE)
            string(CONCAT reason "gcovr not found - install it (pip install gcovr) "
                                 "or set COVERAGE_GCOVR_EXECUTABLE")
            message(WARNING "Coverage: ${reason}")
            _coverage_error_target(${name} "${reason}")
            return()
        endif()

        # The gcov must match the compiler version
        _coverage_compiler(compiler_name compiler_dirs compiler_major compiler_id)
        if(compiler_id MATCHES "Clang")
            # CLANG_GCOV: llvm-cov of the same version, run as `llvm-cov gcov`
            _coverage_find_llvm_tool(COVERAGE_LLVM_COV llvm-cov)
            if(NOT COVERAGE_LLVM_COV)
                string(CONCAT reason "no llvm-cov matching ${compiler_name} found "
                                     "- set COVERAGE_LLVM_COV")
                message(WARNING "Coverage: ${reason}")
                _coverage_error_target(${name} "${reason}")
                return()
            endif()
            set(COVERAGE_GCOV_EXECUTABLE "${COVERAGE_LLVM_COV} gcov")
        else()
            # g++-13 -> gcov-13, x86_64-linux-gnu-g++-13 -> x86_64-linux-gnu-gcov-13
            set(gcov_names "")
            if(compiler_name MATCHES "^(.*)(g\\+\\+|gcc|c\\+\\+|cc)(-[0-9.]+)?(\\.exe)?$")
                list(APPEND gcov_names "${CMAKE_MATCH_1}gcov${CMAKE_MATCH_3}")
            endif()
            list(APPEND gcov_names gcov-${compiler_major} gcov)
            find_program(COVERAGE_GCOV_EXECUTABLE NAMES ${gcov_names} HINTS ${compiler_dirs})
            if(NOT COVERAGE_GCOV_EXECUTABLE)
                list(JOIN gcov_names ", " tried)
                string(CONCAT reason "no gcov matching ${compiler_name} found (tried ${tried}) "
                                     "- set COVERAGE_GCOV_EXECUTABLE")
                message(WARNING "Coverage: ${reason}")
                _coverage_error_target(${name} "${reason}")
                return()
            endif()
        endif()

        # .gcda counters add up across runs (and keep the coverage of tests
        # that have since changed), so every run starts from zero
        file(WRITE "${out}/gcov-reset.cmake" [==[
file(GLOB_RECURSE gcda "${DIR}/*.gcda")
if(gcda)
    file(REMOVE ${gcda})
endif()
]==])

        if(ARG_GCOVR_CONFIG)
            configure_file("${ARG_GCOVR_CONFIG}" "${out}/gcovr.cfg" @ONLY)
            set(gcovr_args --config "${out}/gcovr.cfg")
            # A gcov-executable set in the template wins; otherwise use ours
            file(STRINGS "${out}/gcovr.cfg" gcov_key REGEX "^[ \t]*gcov-executable[ \t]*=")
            if(NOT gcov_key)
                list(APPEND gcovr_args --gcov-executable "${COVERAGE_GCOV_EXECUTABLE}")
            endif()
            if(ARG_GENHTML)
                list(APPEND gcovr_args --lcov "${out}/coverage.lcov")
            endif()
        else()
            # --txt prints the per-file table, like `llvm-cov report` does
            set(gcovr_args --root "${CMAKE_SOURCE_DIR}" --object-directory "${CMAKE_BINARY_DIR}"
                           --gcov-executable "${COVERAGE_GCOV_EXECUTABLE}"
                           --exclude-throw-branches
                           --cobertura "${out}/coverage.xml" --lcov "${out}/coverage.lcov"
                           --html-details "${out}/index.html" --txt --print-summary)
        endif()
        # With a config file, these add to the file's own excludes
        foreach(rx IN LISTS ARG_EXCLUDE)
            list(APPEND gcovr_args --exclude "${rx}")
        endforeach()
        # Search the build tree: gcovr's default (the root) misses the
        # coverage data when the build tree is outside the source tree
        list(APPEND gcovr_args "${CMAKE_BINARY_DIR}")

        add_custom_target(${name}
            ${config_guard}
            COMMAND "${CMAKE_COMMAND}" -E make_directory "${out}"
            COMMAND "${CMAKE_COMMAND}" "-DDIR=${CMAKE_BINARY_DIR}" -P "${out}/gcov-reset.cmake"
            COMMAND ${ARG_TEST_COMMAND}
            COMMAND "${COVERAGE_GCOVR_EXECUTABLE}" ${gcovr_args}
            ${genhtml_command}
            WORKING_DIRECTORY "${CMAKE_BINARY_DIR}"
            COMMENT "Running tests and generating gcov report in ${out}"
            USES_TERMINAL COMMAND_EXPAND_LISTS VERBATIM)

    # ---- Clang / clang-cl: llvm-profdata + llvm-cov ----------------------
    elseif(COVERAGE_BACKEND STREQUAL "llvm")
        # The tools must match the compiler version (profile format)
        _coverage_compiler(compiler_name compiler_dirs compiler_major compiler_id)
        _coverage_find_llvm_tool(COVERAGE_LLVM_PROFDATA llvm-profdata)
        _coverage_find_llvm_tool(COVERAGE_LLVM_COV llvm-cov)
        if(NOT COVERAGE_LLVM_PROFDATA OR NOT COVERAGE_LLVM_COV)
            string(CONCAT reason "no llvm-profdata/llvm-cov matching ${compiler_name} found "
                                 "- set COVERAGE_LLVM_PROFDATA and COVERAGE_LLVM_COV")
            message(WARNING "Coverage: ${reason}")
            _coverage_error_target(${name} "${reason}")
            return()
        endif()

        # Helper script (a custom command can't glob *.profraw portably)
        file(WRITE "${out}/llvm-report.cmake" [==[
string(REPLACE "@@" ";" BINARIES "${BINARIES}")
string(REPLACE "@@" ";" EXCLUDE  "${EXCLUDE}")
file(GLOB_RECURSE raw "${RAW_DIR}/*.profraw")
if(NOT raw)
    message(FATAL_ERROR "No .profraw files found in ${RAW_DIR}")
endif()
execute_process(COMMAND "${PROFDATA}" merge -sparse ${raw} -o "${OUT_DIR}/merged.profdata"
                COMMAND_ERROR_IS_FATAL ANY)
list(POP_FRONT BINARIES first)
set(objects "${first}")
foreach(b IN LISTS BINARIES)
    list(APPEND objects -object "${b}")
endforeach()
set(common "-instr-profile=${OUT_DIR}/merged.profdata")
foreach(rx IN LISTS EXCLUDE)
    list(APPEND common "-ignore-filename-regex=${rx}")
endforeach()
set(report_mcdc "")
set(show_mcdc "")
if(MCDC)
    set(report_mcdc -show-mcdc-summary)
    set(show_mcdc -show-mcdc)
endif()
execute_process(COMMAND "${COV}" report ${objects} ${common} ${report_mcdc}
                COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND "${COV}" show ${objects} ${common} ${show_mcdc} -format=html
                        "-output-dir=${OUT_DIR}/html" COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND "${COV}" export ${objects} ${common} -format=lcov
                OUTPUT_FILE "${OUT_DIR}/coverage.lcov" COMMAND_ERROR_IS_FATAL ANY)
]==])

        set(binaries "")
        foreach(t IN LISTS ARG_TARGETS)
            list(APPEND binaries "$<TARGET_FILE:${t}>")
        endforeach()
        list(JOIN binaries "@@" binaries_joined)
        list(JOIN ARG_EXCLUDE "@@" excludes_joined)

        add_custom_target(${name}
            ${config_guard}
            COMMAND "${CMAKE_COMMAND}" -E rm -rf "${out}/raw"
            COMMAND "${CMAKE_COMMAND}" -E make_directory "${out}/raw"
            COMMAND "${CMAKE_COMMAND}" -E env "LLVM_PROFILE_FILE=${out}/raw/%p-%m.profraw"
                    ${ARG_TEST_COMMAND}
            COMMAND "${CMAKE_COMMAND}"
                    "-DPROFDATA=${COVERAGE_LLVM_PROFDATA}" "-DCOV=${COVERAGE_LLVM_COV}"
                    "-DRAW_DIR=${out}/raw" "-DOUT_DIR=${out}"
                    "-DBINARIES=${binaries_joined}" "-DEXCLUDE=${excludes_joined}"
                    "-DMCDC=${COVERAGE_MCDC}"
                    -P "${out}/llvm-report.cmake"
            ${genhtml_command}
            WORKING_DIRECTORY "${CMAKE_BINARY_DIR}"
            COMMENT "Running tests and generating LLVM coverage report in ${out}"
            USES_TERMINAL COMMAND_EXPAND_LISTS VERBATIM)

    # ---- MSVC: Microsoft.CodeCoverage.Console ----------------------------
    elseif(COVERAGE_BACKEND STREQUAL "msvc")
        find_program(COVERAGE_MS_CONSOLE
            NAMES Microsoft.CodeCoverage.Console
            HINTS "$ENV{VSINSTALLDIR}" "${CMAKE_GENERATOR_INSTANCE}"
            PATH_SUFFIXES "Common7/IDE/Extensions/Microsoft/CodeCoverage.Console")
        if(NOT COVERAGE_MS_CONSOLE)
            string(CONCAT reason "Microsoft.CodeCoverage.Console not found (VS 2022 ships it "
                                 "with Enterprise only) - configure from a Developer Prompt or set "
                                 "COVERAGE_MS_CONSOLE")
            message(WARNING "Coverage: ${reason}")
            _coverage_error_target(${name} "${reason}")
            return()
        endif()

        set(COVERAGE_MODULE_DIRECTORIES "")
        foreach(t IN LISTS ARG_TARGETS)
            string(APPEND COVERAGE_MODULE_DIRECTORIES
                "    <Directory>$<TARGET_FILE_DIR:${t}></Directory>\n")
        endforeach()

        if(ARG_MSVC_CONFIG)
            configure_file("${ARG_MSVC_CONFIG}" "${out}/coverage.config.in" @ONLY)
        else()
            file(WRITE "${out}/coverage.config.in"
                "<ModulePaths>\n  <IncludeDirectories>\n${COVERAGE_MODULE_DIRECTORIES}  </IncludeDirectories>\n</ModulePaths>\n")
        endif()
        file(GENERATE OUTPUT "${out}/coverage.config"
             INPUT "${out}/coverage.config.in" CONDITION $<CONFIG:Coverage>)

        # The tool takes the command to run as one string
        list(JOIN ARG_TEST_COMMAND " " test_command_string)

        add_custom_target(${name}
            ${config_guard}
            COMMAND "${CMAKE_COMMAND}" -E make_directory "${out}"
            COMMAND "${COVERAGE_MS_CONSOLE}" collect
                    --settings "${out}/coverage.config"
                    --output-format cobertura
                    --output "${out}/coverage.xml"
                    "${test_command_string}"
            WORKING_DIRECTORY "${CMAKE_BINARY_DIR}"
            COMMENT "Running tests under Microsoft.CodeCoverage.Console -> ${out}/coverage.xml"
            USES_TERMINAL VERBATIM)
    endif()

    # Make sure everything is (re)built with instrumentation before running
    add_dependencies(${name} ${ARG_TARGETS})
endfunction()
