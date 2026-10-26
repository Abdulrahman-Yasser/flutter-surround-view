cmake_minimum_required(VERSION 3.16)
project(libcamera-dmabuf-capture LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# When cross-compiling with the Yocto SDK, CMake probes the cross-compiler and
# picks up the host system's /usr/include/c++/11 (x86_64 headers). Those then
# mix with the aarch64 sysroot headers and break compilation.
# Strip only the host /usr/include* entries; keep the SDK-internal GCC dirs
# (e.g. .../13.4.0/include) that contain the stdlib.h wrapper (#include_next).
if(CMAKE_CROSSCOMPILING)
    list(FILTER CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES EXCLUDE REGEX "^/usr/include")
    list(FILTER CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES   EXCLUDE REGEX "^/usr/include")
endif()

find_package(PkgConfig REQUIRED)

pkg_check_modules(LIBCAMERA  REQUIRED IMPORTED_TARGET libcamera)
pkg_check_modules(DRM        REQUIRED IMPORTED_TARGET libdrm)
pkg_check_modules(GBM        REQUIRED IMPORTED_TARGET gbm)
pkg_check_modules(EGL        REQUIRED IMPORTED_TARGET egl)
pkg_check_modules(GLESV2     REQUIRED IMPORTED_TARGET glesv2)
pkg_check_modules(PNG        REQUIRED IMPORTED_TARGET libpng)

# ── Pipeline core ────────────────────────────────────────────────────────────
# The capture and render pipeline behind the ivi-homescreen platform view
# (libbev_view.so, below). Position-independent because the platform view is a
# shared object; hidden so that library exports only its bev_* C ABI.
# bev_config.ini, lens files and the IPM math: pure CPU, shared with the
# calibration library so both read and write the same format.
add_library(bev_conf STATIC
    ipm.cpp
    bev_config.cpp
    bev_setup.cpp
)
set_target_properties(bev_conf PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
)
target_include_directories(bev_conf PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

add_library(bev_core STATIC
    capture_session.cpp
    gpu_renderer.cpp
)
set_target_properties(bev_core PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
)
target_include_directories(bev_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

target_link_libraries(bev_core PUBLIC
    bev_conf
    PkgConfig::LIBCAMERA
    PkgConfig::DRM
    PkgConfig::GBM
    PkgConfig::EGL
    PkgConfig::GLESV2
    PkgConfig::PNG
)

# ── ivi-homescreen platform view (libbev_view.so) ────────────────────────────
# Publishes the pipeline as the "views/bev-view" ihs_pv platform view: it
# renders offscreen, hands the shell one dma-buf per frame, and the shell owns
# compositing. Built by flutter/bev_view's native-assets hook, which turns this
# on; OFF by default so the CLI build never needs an ivi-homescreen tree.
option(ENABLE_IHS_PV "Build libbev_view.so, the ivi-homescreen platform view" OFF)

# The producer always renders with GLES. What differs per shell backend is who
# allocates the buffers it renders into: on a Vulkan backend (wayland-vulkan /
# drm-kms-vulkan) they are exportable images on the shell's own device, so the
# compositor is guaranteed to import them; on an EGL backend they come from gbm.
# Only the Vulkan headers are needed -- every entry point is resolved through
# the shell's interposed loader at run time.
option(ENABLE_IHS_PV_VULKAN "Allocate platform-view buffers on the shell's Vulkan device" ON)

if (ENABLE_IHS_PV)
    # -- ihs_pv: libihs_shared and the ihs/ ABI headers -----------------------
    # Either an ivi-homescreen checkout (IHS_DIR, with its build under
    # IHS_BUILD_DIR) or an installed ivi-homescreen-shared package.
    # An AGL SDK build turns this off: the sibling checkout would win over the
    # sysroot's ivi-homescreen-shared package.
    option(IHS_PROBE_SIBLING "Use a ../ivi-homescreen checkout when IHS_DIR is unset" ON)
    if (IHS_PROBE_SIBLING AND NOT IHS_DIR AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../ivi-homescreen/shared/include/ihs/platform_view.h")
        get_filename_component(IHS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../ivi-homescreen" ABSOLUTE)
    endif ()

    # Under a cross build the shell's build tree is emb's, not the checkout's:
    # <workspace>/cross-build-<triple>-<key>/build-<backend>/. The key moves
    # with the target configuration, so it cannot be written down -- derive the
    # workspace from CMAKE_SYSROOT (<workspace>/cross-<triple>-<key>/sysroot)
    # and take the most recently built shell for this triple. A host build's
    # x86_64 libihs_shared must never be picked up here, so the checkout glob
    # below stays off the cross path entirely.
    if (NOT IHS_BUILD_DIR AND CMAKE_CROSSCOMPILING AND CMAKE_SYSROOT)
        get_filename_component(_ihs_profile "${CMAKE_SYSROOT}" DIRECTORY)
        get_filename_component(_ihs_workspace "${_ihs_profile}" DIRECTORY)
        get_filename_component(_ihs_profile_name "${_ihs_profile}" NAME)
        string(REGEX REPLACE "^cross-(.+)-[0-9a-f]+$" "\\1" _ihs_triple "${_ihs_profile_name}")
        # The toolchain file is <triple>-<build key>-toolchain.cmake, and the
        # shell built under that same key is the one this configuration belongs
        # to. Prefer it: "newest" alone picked another board's build whenever
        # that one had been built more recently.
        set(_ihs_key "")
        if (CMAKE_TOOLCHAIN_FILE)
            get_filename_component(_ihs_tc_name "${CMAKE_TOOLCHAIN_FILE}" NAME)
            string(REGEX MATCH "-([0-9a-f]+)-toolchain\\.cmake$" _ihs_tc_match "${_ihs_tc_name}")
            set(_ihs_key "${CMAKE_MATCH_1}")
        endif ()
        # Newer shells put the library in shell/lib/, older ones in shared/;
        # the generated ihs_export.h is under shared/include either way.
        # Keyed builds first; any build for the triple only if none qualifies.
        set(_ihs_patterns "")
        if (_ihs_key)
            list(APPEND _ihs_patterns "${_ihs_workspace}/cross-build-${_ihs_triple}-${_ihs_key}/build-*")
        endif ()
        list(APPEND _ihs_patterns "${_ihs_workspace}/cross-build-${_ihs_triple}-*/build-*")
        foreach (_pattern ${_ihs_patterns})
            file(GLOB _ihs_cross_builds LIST_DIRECTORIES true "${_pattern}")
            foreach (_cand ${_ihs_cross_builds})
                set(_cand_lib "")
                foreach (_sub shell/lib shared)
                    if (EXISTS "${_cand}/${_sub}/libihs_shared.so")
                        set(_cand_lib "${_cand}/${_sub}/libihs_shared.so")
                        break ()
                    endif ()
                endforeach ()
                if (_cand_lib AND EXISTS "${_cand}/shared/include/ihs/ihs_export.h")
                    if (NOT IHS_BUILD_DIR OR "${_cand_lib}" IS_NEWER_THAN "${_ihs_best_lib}")
                        set(IHS_BUILD_DIR "${_cand}")
                        set(_ihs_best_lib "${_cand_lib}")
                    endif ()
                endif ()
            endforeach ()
            if (IHS_BUILD_DIR)
                break ()
            endif ()
        endforeach ()
        if (IHS_BUILD_DIR)
            message(STATUS "ihs build (emb cross)   = ${IHS_BUILD_DIR}")
        endif ()
    endif ()

    add_library(ihs_pv INTERFACE)
    if (IHS_DIR)
        if (NOT IHS_BUILD_DIR AND NOT CMAKE_CROSSCOMPILING)
            # Prefer whichever build directory actually has libihs_shared in it,
            # rather than pinning one name.
            file(GLOB _ihs_builds LIST_DIRECTORIES true
                "${IHS_DIR}/build-pv" "${IHS_DIR}/cmake-build-*" "${IHS_DIR}/build*")
            foreach (_cand ${_ihs_builds})
                if (EXISTS "${_cand}/shared/include/ihs/ihs_export.h")
                    set(IHS_BUILD_DIR "${_cand}")
                    break ()
                endif ()
            endforeach ()
        endif ()
        if (NOT IHS_BUILD_DIR)
            message(FATAL_ERROR
                "ENABLE_IHS_PV: no build of ihs_shared for this target; build the "
                "shell first (emb cross <ivi-homescreen> --target <t> --build) or "
                "set -DIHS_BUILD_DIR=<ivi-homescreen build dir>")
        endif ()
        # The library sits outside the sysroot, which a cross toolchain's
        # CMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY would otherwise exclude.
        if (EXISTS "${IHS_BUILD_DIR}/shell/lib/libihs_shared.so")
            set(IHS_SHARED_LIB "${IHS_BUILD_DIR}/shell/lib/libihs_shared.so")
        elseif (EXISTS "${IHS_BUILD_DIR}/shared/libihs_shared.so")
            set(IHS_SHARED_LIB "${IHS_BUILD_DIR}/shared/libihs_shared.so")
        else ()
            find_library(IHS_SHARED_LIB ihs_shared
                PATHS "${IHS_BUILD_DIR}/shell/lib" "${IHS_BUILD_DIR}/shared" NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH REQUIRED)
        endif ()
        target_link_libraries(ihs_pv INTERFACE ${IHS_SHARED_LIB})
        # shared/include has ihs/platform_view.h; the build tree has the
        # generated ihs/ihs_export.h.
        target_include_directories(ihs_pv INTERFACE
            "${IHS_DIR}/shared/include"
            "${IHS_BUILD_DIR}/shared/include")
        message(STATUS "ihs_shared (checkout)   = ${IHS_SHARED_LIB}")
    else ()
        find_package(ivi-homescreen-shared CONFIG QUIET)
        if (ivi-homescreen-shared_FOUND)
            target_link_libraries(ihs_pv INTERFACE ivi_homescreen::ihs_shared)
            message(STATUS "ihs_shared (package)    = ${ivi-homescreen-shared_VERSION}")
        else ()
            pkg_check_modules(IHS_SHARED IMPORTED_TARGET ivi-homescreen-shared)
            if (NOT IHS_SHARED_FOUND)
                message(FATAL_ERROR
                    "ENABLE_IHS_PV: ivi-homescreen-shared not found. Install it, or "
                    "set -DIHS_DIR=<ivi-homescreen checkout> (and -DIHS_BUILD_DIR).")
            endif ()
            target_link_libraries(ihs_pv INTERFACE PkgConfig::IHS_SHARED)
            message(STATUS "ihs_shared (pkg-config) = ${IHS_SHARED_VERSION}")
        endif ()
    endif ()

    add_library(bev_view SHARED
        egl_context.cpp
        ihs/bev_ihs_pv.cpp
        ihs/bev_params.cpp
        ihs/bev_pipeline.cpp
        ihs/cpu_frames.cpp
        ihs/dmabuf_ring.cpp
    )
    target_include_directories(bev_view PRIVATE ihs)
    target_link_libraries(bev_view PRIVATE bev_core ihs_pv ${CMAKE_DL_LIBS})
    set_target_properties(bev_view PROPERTIES
        CXX_VISIBILITY_PRESET hidden
        VISIBILITY_INLINES_HIDDEN ON
    )
    # A missing library should fail here, not when the shell dlopens the view.
    # ihs_pv_assets_path is a weak import, which this still permits.
    target_link_options(bev_view PRIVATE "LINKER:--no-undefined")

    if (ENABLE_IHS_PV_VULKAN)
        find_path(VULKAN_HEADERS_DIR vulkan/vulkan.h)
        if (VULKAN_HEADERS_DIR)
            target_sources(bev_view PRIVATE ihs/vk_dmabuf_allocator.cpp)
            target_include_directories(bev_view PRIVATE "${VULKAN_HEADERS_DIR}")
            target_compile_definitions(bev_view PRIVATE BEV_IHS_PV_VULKAN=1)
            message(STATUS "bev_view Vulkan alloc   = ON (${VULKAN_HEADERS_DIR})")
        else ()
            message(WARNING
                "ENABLE_IHS_PV_VULKAN is ON but vulkan/vulkan.h was not found -- "
                "on a Vulkan shell the view will allocate from its render node "
                "instead of the shell's device.")
        endif ()
    endif ()
endif ()

# ── ChArUco calibration (libbev_calib.so) ───────────────────────────────────
# CPU only: OpenCV for board detection and the homography solve. Never runs
# alongside libbev_view.so, so it can own the cameras while it is active.
option(ENABLE_CALIB "Build the ChArUco calibration library and bev-calib CLI" OFF)

if (ENABLE_CALIB)
    find_package(OpenCV REQUIRED COMPONENTS core imgproc imgcodecs calib3d objdetect)
    if (OpenCV_VERSION VERSION_LESS 4.7)
        # Before 4.7 ChArUco lived in opencv_contrib's aruco module.
        find_package(OpenCV REQUIRED COMPONENTS core imgproc imgcodecs calib3d aruco)
    endif ()

    add_library(bev_calib_core STATIC
        calib/calib_layout.cpp
        calib/calib_session.cpp
        calib/charuco_board.cpp
        calib/intrinsics.cpp
        calib/lens.cpp
    )
    set_target_properties(bev_calib_core PROPERTIES
        POSITION_INDEPENDENT_CODE ON
        CXX_VISIBILITY_PRESET hidden
        VISIBILITY_INLINES_HIDDEN ON
    )
    target_include_directories(bev_calib_core PUBLIC calib ${OpenCV_INCLUDE_DIRS})
    target_link_libraries(bev_calib_core PUBLIC bev_conf ${OpenCV_LIBS})

    add_executable(bev-calib calib/bev_calib_cli.cpp)
    target_link_libraries(bev-calib PRIVATE bev_calib_core)
    install(TARGETS bev-calib DESTINATION bin)

    # Built by flutter/bev_calib's native-assets hook.
    add_library(bev_calib SHARED
        calib/bev_calib_api.cpp
        calib/still_camera.cpp
    )
    target_link_libraries(bev_calib PRIVATE bev_calib_core PkgConfig::LIBCAMERA ${CMAKE_DL_LIBS})
    set_target_properties(bev_calib PROPERTIES
        CXX_VISIBILITY_PRESET hidden
        VISIBILITY_INLINES_HIDDEN ON
    )
    target_link_options(bev_calib PRIVATE "LINKER:--no-undefined")
endif ()
