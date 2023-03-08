!> Define tests for the `fpm_dependency` module
module test_package_dependencies
  use fpm_filesystem, only: get_temp_filename
  use testsuite, only: new_unittest, unittest_t, error_t, test_failed
  use fpm_filesystem, only: is_dir, join_path, filewrite, mkdir, os_delete_dir, exists
  use fpm_environment, only: os_is_unix
  use fpm_os, only: get_current_directory
  use fpm_dependency
  use fpm_manifest_dependency
  use fpm_toml
  use fpm_settings, only: fpm_global_settings, get_registry_settings
  use fpm_downloader, only: downloader_t
  use fpm_versioning, only: version_t
  use jonquil, only: json_object, json_value, json_loads, cast_to_object

  implicit none
  private

  public :: collect_package_dependencies

  character(*), parameter :: tmp_folder = 'tmp'
  character(*), parameter :: config_file_name = 'config.toml'

  type, extends(dependency_tree_t) :: mock_dependency_tree_t
  contains
    procedure, private :: resolve_dependency => resolve_dependency_once
  end type mock_dependency_tree_t

  type, extends(downloader_t) :: mock_downloader_t
  contains
    procedure, nopass :: get_pkg_data, get_file, unpack => unpack_mock_package
  end type mock_downloader_t

contains

  !> Collect all exported unit tests
  subroutine collect_package_dependencies(tests)

    !> Collection of tests
    type(unittest_t), allocatable, intent(out) :: tests(:)

    tests = [ &
        & new_unittest("cache-load-dump", test_cache_load_dump), &
        & new_unittest("cache-dump-load", test_cache_dump_load), &
        & new_unittest("status-after-load", test_status), &
        & new_unittest("add-dependencies", test_add_dependencies), &
        & new_unittest("registry-dir-not-found", registry_dir_not_found, should_fail=.true.), &
        & new_unittest("no-versions-in-registry", no_versions_in_registry, should_fail=.true.), &
        & new_unittest("version-not-found-in-registry", version_not_found_in_registry, should_fail=.true.), &
        & new_unittest("version-found-without-manifest", version_found_without_manifest, should_fail=.true.), &
        & new_unittest("version-found-with-manifest", version_found_with_manifest), &
        & new_unittest("not-a-dir", not_a_dir, should_fail=.true.), &
        & new_unittest("no-versions-found", no_versions_found, should_fail=.true.), &
        & new_unittest("newest-version-without-manifest", newest_version_without_manifest, should_fail=.true.), &
        & new_unittest("newest-version-with-manifest", newest_version_with_manifest), &
        & new_unittest("get-newest-version-from-registry", get_newest_version_from_registry), &
        & new_unittest("version-found-in-cache", version_found_in_cache), &
        & new_unittest("no-version-in-default-cache", no_version_in_default_cache), &
        & new_unittest("no-version-in-cache-or-registry", no_version_in_cache_or_registry, should_fail=.true.), &
        & new_unittest("other-versions-in-default-cache", other_versions_in_default_cache), &
        & new_unittest("pkg-data-no-code", pkg_data_no_code, should_fail=.true.), &
        & new_unittest("pkg-data-corrupt-code", pkg_data_corrupt_code, should_fail=.true.), &
        & new_unittest("pkg-data-missing-error-message", pkg_data_missing_error_msg, should_fail=.true.), &
        & new_unittest("pkg-data-error-reading-message", pkg_data_error_reading_msg, should_fail=.true.), &
        & new_unittest("pkg-data-error-has-message", pkg_data_error_has_msg, should_fail=.true.), &
        & new_unittest("pkg-data-error-no-data", pkg_data_no_data, should_fail=.true.), &
        & new_unittest("pkg-data-error-reading-data", pkg_data_error_reading_data, should_fail=.true.), &
        & new_unittest("pkg-data-requested-version-wrong-key", pkg_data_requested_version_wrong_key, should_fail=.true.), &
        & new_unittest("pkg-data-no-version-requested-wrong-key", pkg_data_no_version_requested_wrong_key, should_fail=.true.), &
        & new_unittest("pkg-data-error-reading-latest-version", pkg_data_error_reading_latest_version, should_fail=.true.), &
        & new_unittest("pkg-data-no-download-url", pkg_data_no_download_url, should_fail=.true.), &
        & new_unittest("pkg-data-error-reading-donwload-url", pkg_data_error_reading_download_url, should_fail=.true.), &
        & new_unittest("pkg-data-no-version", pkg_data_no_version, should_fail=.true.), &
        & new_unittest("pkg-data-error-reading-version", pkg_data_error_reading_version, should_fail=.true.), &
        & new_unittest("pkg-data-invalid-version", pkg_data_invalid_version, should_fail=.true.) &
        & ]

  end subroutine collect_package_dependencies

  !> Round trip of the dependency cache from a dependency tree to a TOML document
  !> to a dependency tree
  subroutine test_cache_dump_load(error)

    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    type(dependency_tree_t) :: deps
    type(dependency_config_t) :: dep
    integer :: unit

    call new_dependency_tree(deps)
    call resize(deps%dep, 5)
    deps%ndep = 3
    dep%name = "dep1"
    dep%path = "fpm-tmp1-dir"
    call new_dependency_node(deps%dep(1), dep, proj_dir=dep%path)
    dep%name = "dep2"
    dep%path = "fpm-tmp2-dir"
    call new_dependency_node(deps%dep(2), dep, proj_dir=dep%path)
    dep%name = "dep3"
    dep%path = "fpm-tmp3-dir"
    call new_dependency_node(deps%dep(3), dep, proj_dir=dep%path)

    open (newunit=unit, status='scratch')
    call deps%dump(unit, error)
    if (.not. allocated(error)) then
      rewind (unit)

      call new_dependency_tree(deps)
      call resize(deps%dep, 2)
      call deps%load(unit, error)
      close (unit)
    end if
    if (allocated(error)) return

    if (deps%ndep /= 3) then
      call test_failed(error, "Expected three dependencies in loaded cache")
      return
    end if

  end subroutine test_cache_dump_load

  !> Round trip of the dependency cache from a TOML data structure to
  !> a dependency tree to a TOML data structure
  subroutine test_cache_load_dump(error)

    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    type(toml_table) :: table
    type(toml_table), pointer :: ptr
    type(toml_key), allocatable :: list(:)
    type(dependency_tree_t) :: deps

    table = toml_table()
    call add_table(table, "dep1", ptr)
    call set_value(ptr, "version", "1.1.0")
    call set_value(ptr, "proj-dir", "fpm-tmp1-dir")
    call add_table(table, "dep2", ptr)
    call set_value(ptr, "version", "0.55.3")
    call set_value(ptr, "proj-dir", "fpm-tmp2-dir")
    call set_value(ptr, "git", "https://github.com/fortran-lang/dep2")
    call add_table(table, "dep3", ptr)
    call set_value(ptr, "version", "20.1.15")
    call set_value(ptr, "proj-dir", "fpm-tmp3-dir")
    call set_value(ptr, "git", "https://gitlab.com/fortran-lang/dep3")
    call set_value(ptr, "rev", "c0ffee")
    call add_table(table, "dep4", ptr)
    call set_value(ptr, "proj-dir", "fpm-tmp4-dir")

    call new_dependency_tree(deps)
    call deps%load(table, error)
    if (allocated(error)) return

    if (deps%ndep /= 4) then
      call test_failed(error, "Expected four dependencies in loaded cache")
      return
    end if

    call table%destroy
    table = toml_table()

    call deps%dump(table, error)
    if (allocated(error)) return

    call table%get_keys(list)

    if (size(list) /= 4) then
      call test_failed(error, "Expected four dependencies in dumped cache")
      return
    end if

  end subroutine test_cache_load_dump

  subroutine test_status(error)

    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    type(toml_table) :: table
    type(toml_table), pointer :: ptr
    type(dependency_tree_t) :: deps

    table = toml_table()
    call add_table(table, "dep1", ptr)
    call set_value(ptr, "version", "1.1.0")
    call set_value(ptr, "proj-dir", "fpm-tmp1-dir")
    call add_table(table, "dep2", ptr)
    call set_value(ptr, "version", "0.55.3")
    call set_value(ptr, "proj-dir", "fpm-tmp2-dir")
    call set_value(ptr, "git", "https://github.com/fortran-lang/dep2")

    call new_dependency_tree(deps)
    call deps%load(table, error)
    if (allocated(error)) return

    if (deps%finished()) then
      call test_failed(error, "Newly initialized dependency tree cannot be reolved")
      return
    end if

  end subroutine test_status

  subroutine test_add_dependencies(error)

    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    type(toml_table) :: table
    type(toml_table), pointer :: ptr
    type(mock_dependency_tree_t) :: deps
    type(dependency_config_t), allocatable :: nodes(:)

    table = toml_table()
    call add_table(table, "sub1", ptr)
    call set_value(ptr, "path", "external")
    call add_table(table, "lin2", ptr)
    call set_value(ptr, "git", "https://github.com/fortran-lang/lin2")
    call add_table(table, "pkg3", ptr)
    call set_value(ptr, "git", "https://gitlab.com/fortran-lang/pkg3")
    call set_value(ptr, "rev", "c0ffee")
    call add_table(table, "proj4", ptr)
    call set_value(ptr, "path", "vendor")

    call new_dependencies(nodes, table, error=error)
    if (allocated(error)) return

    call new_dependencies(nodes, table, root='.', error=error)
    if (allocated(error)) return

    call new_dependency_tree(deps%dependency_tree_t)
    call deps%add(nodes, error)
    if (allocated(error)) return

    if (deps%finished()) then
      call test_failed(error, "Newly added nodes cannot be already resolved")
      return
    end if

    if (deps%ndep /= 4) then
      call test_failed(error, "Expected for dependencies in tree")
      return
    end if

    call deps%resolve(".", error)
    if (allocated(error)) return

    if (.not. deps%finished()) then
      call test_failed(error, "Mocked dependency tree must resolve in one step")
      return
    end if

  end subroutine test_add_dependencies

  !> Directories for namespace and package name not found in path registry.
  subroutine registry_dir_not_found(error)
    type(error_t), allocatable, intent(out) :: error

    type(toml_table) :: table
    type(dependency_node_t) :: node
    type(fpm_global_settings) :: global_settings
    character(len=:), allocatable :: target_dir
    type(toml_table), pointer :: child

    call new_table(table)
    table%key = 'test-dep'
    call set_value(table, 'namespace', 'test-org')

    call new_dependency(node%dependency_config_t, table, error=error)
    if (allocated(error)) return

    call delete_tmp_folder
    call mkdir(join_path(tmp_folder, 'cache')) ! Missing directories for namesapce and package name

    call new_table(table)
    call add_table(table, 'registry', child)
    call set_value(child, 'path', 'cache')

    call setup_global_settings(global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_registry_settings(child, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call node%get_from_registry(target_dir, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call delete_tmp_folder

  end subroutine registry_dir_not_found

  !> No versions found in path registry.
  subroutine no_versions_in_registry(error)
    type(error_t), allocatable, intent(out) :: error

    type(toml_table) :: table
    type(dependency_node_t) :: node
    type(fpm_global_settings) :: global_settings
    character(len=:), allocatable :: target_dir
    type(toml_table), pointer :: child

    call new_table(table)
    table%key = 'test-dep'
    call set_value(table, 'namespace', 'test-org')

    call new_dependency(node%dependency_config_t, table, error=error)
    if (allocated(error)) return

    call delete_tmp_folder
    call mkdir(join_path(tmp_folder, 'cache', 'test-org', 'test-dep'))

    call new_table(table)
    call add_table(table, 'registry', child)
    call set_value(child, 'path', 'cache')

    call setup_global_settings(global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_registry_settings(child, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call node%get_from_registry(target_dir, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call delete_tmp_folder

  end subroutine no_versions_in_registry

  !> Specific version not found in path registry.
  subroutine version_not_found_in_registry(error)
    type(error_t), allocatable, intent(out) :: error

    type(toml_table) :: table
    type(dependency_node_t) :: node
    type(fpm_global_settings) :: global_settings
    character(len=:), allocatable :: target_dir
    type(toml_table), pointer :: child

    call new_table(table)
    table%key = 'test-dep'
    call set_value(table, 'namespace', 'test-org')
    call set_value(table, 'v', '0.1.0')

    call new_dependency(node%dependency_config_t, table, error=error)
    if (allocated(error)) return

    call delete_tmp_folder
    call mkdir(join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '0.0.9'))
    call mkdir(join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '0.1.1'))

    call new_table(table)
    call add_table(table, 'registry', child)
    call set_value(child, 'path', 'cache')

    call setup_global_settings(global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_registry_settings(child, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call node%get_from_registry(target_dir, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call delete_tmp_folder

  end subroutine version_not_found_in_registry

  !> Target package in path registry does not contain manifest.
  subroutine version_found_without_manifest(error)
    type(error_t), allocatable, intent(out) :: error

    type(toml_table) :: table
    type(dependency_node_t) :: node
    type(fpm_global_settings) :: global_settings
    character(len=:), allocatable :: target_dir
    type(toml_table), pointer :: child

    call new_table(table)
    table%key = 'test-dep'
    call set_value(table, 'namespace', 'test-org')
    call set_value(table, 'v', '0.1.0')

    call new_dependency(node%dependency_config_t, table, error=error)
    if (allocated(error)) return

    call delete_tmp_folder
    call mkdir(join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '0.0.9'))
    call mkdir(join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '0.1.0'))
    call mkdir(join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '0.1.1'))

    call new_table(table)
    call add_table(table, 'registry', child)
    call set_value(child, 'path', 'cache')

    call setup_global_settings(global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_registry_settings(child, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call node%get_from_registry(target_dir, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call delete_tmp_folder

  end subroutine version_found_without_manifest

  !> Target package in path registry contains manifest.
  subroutine version_found_with_manifest(error)
    type(error_t), allocatable, intent(out) :: error

    type(toml_table) :: table
    type(dependency_node_t) :: node
    type(fpm_global_settings) :: global_settings
    character(len=:), allocatable :: target_dir, cwd
    type(toml_table), pointer :: child

    call new_table(table)
    table%key = 'test-dep'
    call set_value(table, 'namespace', 'test-org')
    call set_value(table, 'v', '0.1.0')

    call new_dependency(node%dependency_config_t, table, error=error)
    if (allocated(error)) return

    call delete_tmp_folder
    call mkdir(join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '0.0.0'))
    call mkdir(join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '0.1.0'))
    call filewrite(join_path(join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '0.1.0'), 'fpm.toml'), [''])
    call mkdir(join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '0.2.0'))

    call new_table(table)
    call add_table(table, 'registry', child)
    call set_value(child, 'path', 'cache')

    call setup_global_settings(global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_registry_settings(child, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call node%get_from_registry(target_dir, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_current_directory(cwd, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    if (target_dir /= join_path(cwd, join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '0.1.0'))) then
      call test_failed(error, 'target_dir not set correctly')
      call delete_tmp_folder; return
    end if

    call delete_tmp_folder

  end subroutine version_found_with_manifest

  !> Target is a file, not a directory.
  subroutine not_a_dir(error)
    type(error_t), allocatable, intent(out) :: error

    type(toml_table) :: table
    type(dependency_node_t) :: node
    type(fpm_global_settings) :: global_settings
    character(len=:), allocatable :: target_dir
    type(toml_table), pointer :: child

    call new_table(table)
    table%key = 'test-dep'
    call set_value(table, 'namespace', 'test-org')

    call new_dependency(node%dependency_config_t, table, error=error)
    if (allocated(error)) return

    call delete_tmp_folder
    call mkdir(join_path(tmp_folder, 'cache', 'test-org', 'test-dep'))
    call filewrite(join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '0.1.0'), ['']) ! File, not directory

    call new_table(table)
    call add_table(table, 'registry', child)
    call set_value(child, 'path', 'cache')

    call setup_global_settings(global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_registry_settings(child, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call node%get_from_registry(target_dir, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call delete_tmp_folder

  end subroutine not_a_dir

  !> Try fetching the latest version in the local registry, but none are found.
  !> Compared to no-versions-in-registry, we aren't requesting a specific version here.
  subroutine no_versions_found(error)
    type(error_t), allocatable, intent(out) :: error

    type(toml_table) :: table
    type(dependency_node_t) :: node
    type(fpm_global_settings) :: global_settings
    character(len=:), allocatable :: target_dir
    type(toml_table), pointer :: child

    call new_table(table)
    table%key = 'test-dep'
    call set_value(table, 'namespace', 'test-org')

    call new_dependency(node%dependency_config_t, table, error=error)
    if (allocated(error)) return

    call delete_tmp_folder
    call mkdir(join_path(tmp_folder, 'cache', 'test-org', 'test-dep'))

    call new_table(table)
    call add_table(table, 'registry', child)
    call set_value(child, 'path', 'cache')

    call setup_global_settings(global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_registry_settings(child, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call node%get_from_registry(target_dir, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call delete_tmp_folder

  end subroutine no_versions_found

  !> Latest version in the local registry does not have a manifest.
  subroutine newest_version_without_manifest(error)
    type(error_t), allocatable, intent(out) :: error

    type(toml_table) :: table
    type(dependency_node_t) :: node
    type(fpm_global_settings) :: global_settings
    character(len=:), allocatable :: target_dir, cwd
    type(toml_table), pointer :: child

    call new_table(table)
    table%key = 'test-dep'
    call set_value(table, 'namespace', 'test-org')

    call new_dependency(node%dependency_config_t, table, error=error)
    if (allocated(error)) return

    call delete_tmp_folder
    call mkdir(join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '0.0.0'))
    call mkdir(join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '1.3.0'))
    call mkdir(join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '1.2.1'))

    call new_table(table)
    call add_table(table, 'registry', child)
    call set_value(child, 'path', 'cache')

    call setup_global_settings(global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_registry_settings(child, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call node%get_from_registry(target_dir, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_current_directory(cwd, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    if (target_dir /= join_path(cwd, join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '1.3.0'))) then
      call test_failed(error, 'target_dir not set correctly: '//target_dir//"'")
      call delete_tmp_folder; return
    end if

    call delete_tmp_folder

  end subroutine newest_version_without_manifest

  !> Latest version in the local registry has a manifest.
  subroutine newest_version_with_manifest(error)
    type(error_t), allocatable, intent(out) :: error

    type(toml_table) :: table
    type(dependency_node_t) :: node
    type(fpm_global_settings) :: global_settings
    character(len=:), allocatable :: target_dir, cwd
    type(toml_table), pointer :: child

    call new_table(table)
    table%key = 'test-dep'
    call set_value(table, 'namespace', 'test-org')

    call new_dependency(node%dependency_config_t, table, error=error)
    if (allocated(error)) return

    call delete_tmp_folder
    call mkdir(join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '0.0.0'))
    call mkdir(join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '1.3.0'))
    call filewrite(join_path(join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '1.3.0'), 'fpm.toml'), [''])
    call mkdir(join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '1.2.1'))

    call new_table(table)
    call add_table(table, 'registry', child)
    call set_value(child, 'path', 'cache')

    call setup_global_settings(global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_registry_settings(child, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call node%get_from_registry(target_dir, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_current_directory(cwd, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    if (target_dir /= join_path(cwd, join_path(tmp_folder, 'cache', 'test-org', 'test-dep', '1.3.0'))) then
      call test_failed(error, 'target_dir not set correctly: '//target_dir//"'")
      call delete_tmp_folder; return
    end if

    call delete_tmp_folder

  end subroutine newest_version_with_manifest

  !> No version specified, get the newest version from the registry.
  subroutine get_newest_version_from_registry(error)
    type(error_t), allocatable, intent(out) :: error

    type(toml_table) :: table
    type(dependency_node_t) :: node
    type(fpm_global_settings) :: global_settings
    character(len=:), allocatable :: target_dir, cwd
    type(toml_table), pointer :: child
    type(mock_downloader_t) :: mock_downloader

    call new_table(table)
    table%key = 'test-dep'
    call set_value(table, 'namespace', 'test-org')

    call new_dependency(node%dependency_config_t, table, error=error)
    if (allocated(error)) return

    call delete_tmp_folder
    call mkdir(tmp_folder)

    call new_table(table)
    call add_table(table, 'registry', child)

    call setup_global_settings(global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_registry_settings(child, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call node%get_from_registry(target_dir, global_settings, error, mock_downloader)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_current_directory(cwd, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    if (target_dir /= join_path(cwd, join_path(tmp_folder, 'dependencies', 'test-org', 'test-dep', '0.1.0'))) then
      call test_failed(error, "Target directory not set correctly: '"//target_dir//"'")
      call delete_tmp_folder; return
    end if

    call delete_tmp_folder

  end subroutine get_newest_version_from_registry

  !> Version specified in manifest, version found in cache.
  subroutine version_found_in_cache(error)
    type(error_t), allocatable, intent(out) :: error

    type(toml_table) :: table
    type(dependency_node_t) :: node
    type(fpm_global_settings) :: global_settings
    character(len=:), allocatable :: target_dir, cwd, path
    type(toml_table), pointer :: child

    call new_table(table)
    table%key = 'test-dep'
    call set_value(table, 'namespace', 'test-org')
    call set_value(table, 'v', '2.3.0')

    call new_dependency(node%dependency_config_t, table, error=error)
    if (allocated(error)) return

    call delete_tmp_folder
    path = join_path(tmp_folder, 'dependencies', 'test-org', 'test-dep', '2.3.0')
    call mkdir(path)
    call filewrite(join_path(path, 'fpm.toml'), [''])

    call new_table(table)
    call add_table(table, 'registry', child) ! No cache_path specified, use default

    call setup_global_settings(global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_registry_settings(child, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call node%get_from_registry(target_dir, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_current_directory(cwd, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    if (target_dir /= join_path(cwd, join_path(tmp_folder, 'dependencies', 'test-org', 'test-dep', '2.3.0'))) then
      call test_failed(error, "Target directory not set correctly: '"//target_dir//"'")
      call delete_tmp_folder; return
    end if

    call delete_tmp_folder

  end subroutine version_found_in_cache

  !> Version specified in manifest, but not found in cache. Therefore download dependency.
  subroutine no_version_in_default_cache(error)
    type(error_t), allocatable, intent(out) :: error

    type(toml_table) :: table
    type(dependency_node_t) :: node
    type(fpm_global_settings) :: global_settings
    character(len=:), allocatable :: target_dir, cwd
    type(toml_table), pointer :: child
    type(mock_downloader_t) :: mock_downloader

    call new_table(table)
    table%key = 'test-dep'
    call set_value(table, 'namespace', 'test-org')
    call set_value(table, 'v', '0.1.0')

    call new_dependency(node%dependency_config_t, table, error=error)
    if (allocated(error)) return

    call delete_tmp_folder
    call mkdir(tmp_folder) ! Dependencies folder doesn't exist

    call new_table(table)
    call add_table(table, 'registry', child)

    call setup_global_settings(global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_registry_settings(child, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call node%get_from_registry(target_dir, global_settings, error, mock_downloader)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_current_directory(cwd, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    if (target_dir /= join_path(cwd, join_path(tmp_folder, 'dependencies', 'test-org', 'test-dep', '0.1.0'))) then
      call test_failed(error, "Target directory not set correctly: '"//target_dir//"'")
      call delete_tmp_folder; return
    end if

    call delete_tmp_folder

  end subroutine no_version_in_default_cache

  !> Version specified in manifest, but not found in cache or registry.
  subroutine no_version_in_cache_or_registry(error)
    type(error_t), allocatable, intent(out) :: error

    type(toml_table) :: table
    type(dependency_node_t) :: node
    type(fpm_global_settings) :: global_settings
    character(len=:), allocatable :: target_dir
    type(toml_table), pointer :: child
    type(mock_downloader_t) :: mock_downloader

    call new_table(table)
    table%key = 'test-dep'
    call set_value(table, 'namespace', 'test-org')
    call set_value(table, 'v', '9.9.9')

    call new_dependency(node%dependency_config_t, table, error=error)
    if (allocated(error)) return

    call delete_tmp_folder
    call mkdir(tmp_folder)

    call new_table(table)
    call add_table(table, 'registry', child)

    call setup_global_settings(global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_registry_settings(child, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call node%get_from_registry(target_dir, global_settings, error, mock_downloader)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call delete_tmp_folder

  end subroutine no_version_in_cache_or_registry

  subroutine other_versions_in_default_cache(error)
    type(error_t), allocatable, intent(out) :: error

    type(toml_table) :: table
    type(dependency_node_t) :: node
    type(fpm_global_settings) :: global_settings
    character(len=:), allocatable :: target_dir
    type(toml_table), pointer :: child
    type(mock_downloader_t) :: mock_downloader

    call new_table(table)
    table%key = 'test-dep'
    call set_value(table, 'namespace', 'test-org')
    call set_value(table, 'v', '0.1.0')

    call new_dependency(node%dependency_config_t, table, error=error)
    if (allocated(error)) return

    call delete_tmp_folder
    call mkdir(join_path(tmp_folder, 'dependencies', 'test-org', 'test-dep', '2.1.0'))
    call mkdir(join_path(tmp_folder, 'dependencies', 'test-org', 'test-dep', '9.1.0'))

    call new_table(table)
    call add_table(table, 'registry', child)

    call setup_global_settings(global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call get_registry_settings(child, global_settings, error)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call node%get_from_registry(target_dir, global_settings, error, mock_downloader)
    if (allocated(error)) then
      call delete_tmp_folder; return
    end if

    call delete_tmp_folder

  end subroutine other_versions_in_default_cache

  !> Package data returned from the registry does not contain a code field.
  subroutine pkg_data_no_code(error)
    type(error_t), allocatable, intent(out) :: error

    type(dependency_node_t) :: node
    character(:), allocatable :: url
    type(version_t) :: version
    type(json_object) :: json
    class(json_value), allocatable :: j_value

    call json_loads(j_value, '{}')
    json = cast_to_object(j_value)

    call check_and_read_pkg_data(json, node, url, version, error)

  end subroutine pkg_data_no_code

  !> Error reading status code from package data.
  subroutine pkg_data_corrupt_code(error)
    type(error_t), allocatable, intent(out) :: error

    type(dependency_node_t) :: node
    character(:), allocatable :: url
    type(version_t) :: version
    type(json_object) :: json
    class(json_value), allocatable :: j_value

    call json_loads(j_value, '{"code": "integer expected"}')
    json = cast_to_object(j_value)

    call check_and_read_pkg_data(json, node, url, version, error)

  end subroutine pkg_data_corrupt_code

  subroutine pkg_data_missing_error_msg(error)
    type(error_t), allocatable, intent(out) :: error

    type(dependency_node_t) :: node
    character(:), allocatable :: url
    type(version_t) :: version
    type(json_object) :: json
    class(json_value), allocatable :: j_value

    call json_loads(j_value, '{"code": 123}')
    json = cast_to_object(j_value)

    call check_and_read_pkg_data(json, node, url, version, error)

  end subroutine pkg_data_missing_error_msg

  subroutine pkg_data_error_reading_msg(error)
    type(error_t), allocatable, intent(out) :: error

    type(dependency_node_t) :: node
    character(:), allocatable :: url
    type(version_t) :: version
    type(json_object) :: json
    class(json_value), allocatable :: j_value

    call json_loads(j_value, '{"code": 123, "message": 123}')
    json = cast_to_object(j_value)

    call check_and_read_pkg_data(json, node, url, version, error)

  end subroutine pkg_data_error_reading_msg

  subroutine pkg_data_error_has_msg(error)
    type(error_t), allocatable, intent(out) :: error

    type(dependency_node_t) :: node
    character(:), allocatable :: url
    type(version_t) :: version
    type(json_object) :: json
    class(json_value), allocatable :: j_value

    call json_loads(j_value, '{"code": 123, "message": "Really bad error message"}')
    json = cast_to_object(j_value)

    call check_and_read_pkg_data(json, node, url, version, error)

  end subroutine pkg_data_error_has_msg

  subroutine pkg_data_no_data(error)
    type(error_t), allocatable, intent(out) :: error

    type(dependency_node_t) :: node
    character(:), allocatable :: url
    type(version_t) :: version
    type(json_object) :: json
    class(json_value), allocatable :: j_value

    call json_loads(j_value, '{"code": 200}')
    json = cast_to_object(j_value)

    call check_and_read_pkg_data(json, node, url, version, error)

  end subroutine pkg_data_no_data

  subroutine pkg_data_error_reading_data(error)
    type(error_t), allocatable, intent(out) :: error

    type(dependency_node_t) :: node
    character(:), allocatable :: url
    type(version_t) :: version
    type(json_object) :: json
    class(json_value), allocatable :: j_value

    call json_loads(j_value, '{"code": 200, "data": 123}')
    json = cast_to_object(j_value)

    call check_and_read_pkg_data(json, node, url, version, error)

  end subroutine pkg_data_error_reading_data

  subroutine pkg_data_requested_version_wrong_key(error)
    type(error_t), allocatable, intent(out) :: error

    type(dependency_node_t) :: node
    character(:), allocatable :: url
    type(version_t) :: version
    type(json_object) :: json
    class(json_value), allocatable :: j_value

    allocate (node%requested_version)
    call json_loads(j_value, '{"code": 200, "data": {"latest_version_data": 123}}') ! Expected key: "version_data"
    json = cast_to_object(j_value)

    call check_and_read_pkg_data(json, node, url, version, error)

  end subroutine pkg_data_requested_version_wrong_key

  subroutine pkg_data_no_version_requested_wrong_key(error)
    type(error_t), allocatable, intent(out) :: error

    type(dependency_node_t) :: node
    character(:), allocatable :: url
    type(version_t) :: version
    type(json_object) :: json
    class(json_value), allocatable :: j_value

    call json_loads(j_value, '{"code": 200, "data": {"version_data": 123}}') ! Expected key: "latest_version_data"
    json = cast_to_object(j_value)

    call check_and_read_pkg_data(json, node, url, version, error)

  end subroutine pkg_data_no_version_requested_wrong_key

  subroutine pkg_data_error_reading_latest_version(error)
    type(error_t), allocatable, intent(out) :: error

    type(dependency_node_t) :: node
    character(:), allocatable :: url
    type(version_t) :: version
    type(json_object) :: json
    class(json_value), allocatable :: j_value

    call json_loads(j_value, '{"code": 200, "data": {"latest_version_data": 123}}')
    json = cast_to_object(j_value)

    call check_and_read_pkg_data(json, node, url, version, error)

  end subroutine pkg_data_error_reading_latest_version

  subroutine pkg_data_no_download_url(error)
    type(error_t), allocatable, intent(out) :: error

    type(dependency_node_t) :: node
    character(:), allocatable :: url
    type(version_t) :: version
    type(json_object) :: json
    class(json_value), allocatable :: j_value

    call json_loads(j_value, '{"code": 200, "data": {"latest_version_data": {}}}')
    json = cast_to_object(j_value)

    call check_and_read_pkg_data(json, node, url, version, error)

  end subroutine pkg_data_no_download_url

  subroutine pkg_data_error_reading_download_url(error)
    type(error_t), allocatable, intent(out) :: error

    type(dependency_node_t) :: node
    character(:), allocatable :: url
    type(version_t) :: version
    type(json_object) :: json
    class(json_value), allocatable :: j_value

    call json_loads(j_value, '{"code": 200, "data": {"latest_version_data": {"download_url": 123}}}')
    json = cast_to_object(j_value)

    call check_and_read_pkg_data(json, node, url, version, error)

  end subroutine pkg_data_error_reading_download_url

  subroutine pkg_data_no_version(error)
    type(error_t), allocatable, intent(out) :: error

    type(dependency_node_t) :: node
    character(:), allocatable :: url
    type(version_t) :: version
    type(json_object) :: json
    class(json_value), allocatable :: j_value

    call json_loads(j_value, '{"code": 200, "data": {"latest_version_data": {"download_url": "abc"}}}')
    json = cast_to_object(j_value)

    call check_and_read_pkg_data(json, node, url, version, error)

  end subroutine pkg_data_no_version

  subroutine pkg_data_error_reading_version(error)
    type(error_t), allocatable, intent(out) :: error

    type(dependency_node_t) :: node
    character(:), allocatable :: url
    type(version_t) :: version
    type(json_object) :: json
    class(json_value), allocatable :: j_value

    call json_loads(j_value, '{"code": 200, "data": {"latest_version_data": {"download_url": "abc", "version": 123}}}')
    json = cast_to_object(j_value)

    call check_and_read_pkg_data(json, node, url, version, error)

  end subroutine pkg_data_error_reading_version

  subroutine pkg_data_invalid_version(error)
    type(error_t), allocatable, intent(out) :: error

    type(dependency_node_t) :: node
    character(:), allocatable :: url
    type(version_t) :: version
    type(json_object) :: json
    class(json_value), allocatable :: j_value

    call json_loads(j_value, '{"code": 200, "data": {"latest_version_data": {"download_url": "abc", "version": "abc"}}}')
    json = cast_to_object(j_value)

    call check_and_read_pkg_data(json, node, url, version, error)

  end subroutine pkg_data_invalid_version

  !> Resolve a single dependency node
  subroutine resolve_dependency_once(self, dependency, root, error)
    !> Mock instance of the dependency tree
    class(mock_dependency_tree_t), intent(inout) :: self
    !> Dependency configuration to add
    type(dependency_node_t), intent(inout) :: dependency
    !> Current installation prefix
    character(len=*), intent(in) :: root
    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    if (dependency%done) then
      call test_failed(error, "Should only visit this node once")
      return
    end if

    dependency%done = .true.

  end subroutine resolve_dependency_once

  subroutine delete_tmp_folder
    if (is_dir(tmp_folder)) call os_delete_dir(os_is_unix(), tmp_folder)
  end

  subroutine setup_global_settings(global_settings, error)
    type(fpm_global_settings), intent(out) :: global_settings
    type(error_t), allocatable, intent(out) :: error

    character(:), allocatable :: cwd

    call get_current_directory(cwd, error)
    if (allocated(error)) return

    global_settings%path_to_config_folder = join_path(cwd, tmp_folder)
    global_settings%config_file_name = config_file_name
  end

  subroutine get_pkg_data(url, version, tmp_file, json, error)
    character(*), intent(in) :: url
    type(version_t), allocatable, intent(in) :: version
    character(*), intent(in) :: tmp_file
    type(json_object), intent(out) :: json
    type(error_t), allocatable, intent(out) :: error

    class(json_value), allocatable :: j_value

    if (allocated(version)) then
      if (version%s() == '9.9.9') then
        call json_loads(j_value, '{"code": 404, "message": "Package not found"}')
      else
        call json_loads(j_value, '{"code": 200, "data": {"version_data": {"version": "0.1.0", "download_url": "abc"}}}')
      end if
    else
      call json_loads(j_value, '{"code": 200, "data": {"latest_version_data": {"version": "0.1.0", "download_url": "abc"}}}')
    end if

    json = cast_to_object(j_value)
  end

  subroutine get_file(url, tmp_file, error)
    character(*), intent(in) :: url
    character(*), intent(in) :: tmp_file
    type(error_t), allocatable, intent(out) :: error
  end

  subroutine unpack_mock_package(tmp_file, destination, error)
    character(*), intent(in) :: tmp_file
    character(*), intent(in) :: destination
    type(error_t), allocatable, intent(out) :: error

    integer :: stat

    call execute_command_line('cp '//tmp_file//' '//destination, exitstat=stat)

    if (stat /= 0) then
      call test_failed(error, "Failed to create mock package"); return
    end if
  end

end module test_package_dependencies
