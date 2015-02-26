Digger Changelog
================

Digger Next
-----------

 * Add `rebuild` command, for incremental rebuilds
   (thanks to Sergei Nosov)
 * Add `--help` text
 * Add `--make-args` option
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

Digger @ DConf (2014-05-22)
---------------------------

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

2014-04-01
----------

 * Add `digger-web`
 * Fix parsing Environment configuration section
 * Various smaller improvements

2014-02-17
----------

 * Initial announcement

