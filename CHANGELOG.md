Digger Changelog
================

Digger v3.0 (WIP)
------------------------

 * Major internal changes for improved reliability
   * Cache version bumped to 3
 * Updated, backwards-incompatible .ini settings
   * All settings are now equally available from `digger.ini`, `bisect.ini` 
     and command line
   * Search for the configuration file according to the XDG Base Directory
     Specification
 * Add `-c` options to specify arbitrary `digger.ini` and `bisect.ini`
   setting on the command line
   * Specifying a `bisect.ini` for the `bisect` command is now optional,
   and can be entirely substituted with `-c` options.
 * Add `digger checkout` command, which simply checks out a given D revision 
   (`master` by default)
 * Add `digger test` command, to run tests for working tree state
 * Add ability to revert a branch or pull request.  
   The syntax is to prefix the branch or PR with a `-` (minus sign).  
   Example: `digger build "master + -phobos#1234"`
 * Add ability to specify commit SHA1 instead of a branch or PR number.  
   Example: `digger build "master + -dmd/0123456789abcdef0123456789abcdef01234567"`
 * Add `tools`, `extras` and `curl` components
 * Add `32mscoff` model support for Windows
 * Add `--jobs` option for controlling the GNU make `-j` parameter
 * Add `components.dmd.releaseDMD` build option to complement `debugDMD`
 * Add `components.dmd.dmdModel` option, which allows building a 64-bit
   `dmd.exe` on Windows (also supports `32mscoff`).
 * Improve bootstrapping up to arbitrary depths
 * Refuse to clobber working tree changes not done by Digger
 * Verify integrity of all downloaded files
 * Only download/install Visual Studio components as-needed
 * Prevent git from loading user/system configuration
 * Add `dub.sdl`
 * Add test suite
   * Enable continuous integration on Travis and AppVeyor
 * Various fixes

Digger v2.4 (2015-10-05)
------------------------

 * Fetch tags explicitly when updating
   (fixes some "unknown /ambiguous revision" errors)
 * Prepend result `bin` directory to `PATH`
   (fixes behavior when a `dmd` binary was installed in `/usr/bin`)
 * Add support for the `debugDMD` build option on POSIX
 * Fix incorrect repository tree order when using `git` cache engine
 * Fix `rebuild` ignoring build options on the command-line
 * Automatically install KindleGen locally when building website
 * Update OptLink installer
 * Download platform-specific DMD release packages
   (contributed by Martin Nowak)

Digger v2.3 (2015-06-14)
------------------------

 * Add `bisectBuild` bisect config option
 * Add `--with` and `--without` switches to control D components to build
 * Add `website` component for building dlang.org (POSIX-only)
 * Work around `appender` memory corruption bug with `git` cache engine
 * Various fixes

Digger v2.2 (2015-06-05)
------------------------

 * Fix `digger install` to work with `object.d`
 * Improve resilience of `digger install`
 * Add `--bootstrap` switch to build compiler entirely from C++ source
 * Replace usage of `git bisect run` with internal implementation
   * Bisection now prefers cached builds when choosing a commit to test
 * Allow customizing the set of components to build during bisection
 * Use git plumbing in git cache driver for concurrency and better performance
 * Don't cache build failures if the error is likely temporary

Digger v2.1 (2015-05-03)
------------------------

 * Add [license](LICENSE.md)
 * Add `git` cache engine
 * Add `cache` action and subcommands
 * Fix starting `digger-web` in OS X
   (auto-correct working directory)

Digger v2.0 (2015-04-26)
------------------------

 * `idgen.d` update (DMD now requires DMD to build)
 * Full core overhaul, for improved performance, granularity and extensibility.
   A fresh install is recommended.

Digger v1.1 (2015-03-04)
------------------------

 * Add `rebuild` action, for incremental rebuilds
   (thanks to Sergei Nosov)
 * Add `install` and `uninstall` actions
 * Add `--help` text
 * Add `--make-args` option
 * Add `--model` option to replace the `--64` switch
 * Add `--host` and `--port` to `digger-web`
 * Various smaller improvements

Digger v1.0 (2014-09-18)
------------------------

 * On Windows, Digger may now download and locally install (unpack) required 
   software, as needed:
   - Git
   - A number of Visual Studio 2013 Express and Windows SDK components (for 
     64-bit builds)
   - 7-Zip and WiX (necessary for unpacking Visual Studio Express components)
 * Various smaller improvements

Digger v0.3 (2014-05-22) [DConf edition]
----------------------------------------

 * Allow merging arbitrary GitHub forks
 * Add `--offline`, which suppresses updating the D repositories.
 * Move digger-web tasks to digger, thus removing D building logic from 
   digger-web binary
 * Improve revision parsing, allowing e.g. `digger build 2.065 @ 3 weeks ago`
 * Rename `digger-web` directory to `web`, to avoid conflict with POSIX binary 
   of `digger-web.d`
 * Fix web UI behavior when refreshing
 * Fix exit status code propagation
 * Various smaller improvements

Digger v0.2 (2014-04-01) [April Fools' edition]
-----------------------------------------------

 * Add `digger-web`
 * Fix parsing Environment configuration section
 * Various smaller improvements

Digger v0.1 (2014-02-17) [Initial release]
------------------------------------------

 * Initial announcement

