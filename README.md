# Digger [![Build Status](https://travis-ci.org/CyberShadow/Digger.svg?branch=master)](https://travis-ci.org/CyberShadow/Digger) [![AppVeyor](https://ci.appveyor.com/api/projects/status/tm98i6iw931ma3yg/branch/master?svg=true)](https://ci.appveyor.com/project/CyberShadow/digger)

Digger can:

- build and test D from [git](https://github.com/dlang)
- build older versions of D
- build D plus forks and pending pull requests
- bisect D's history to find where regressions are introduced (or bugs fixed)

### Requirements

On POSIX, Digger needs git, g++, binutils and make. gcc-multilib and g++-multilib or equivalent are required for targeting x86 on x86_64 systems.

On Windows, Digger will download and unpack everything it needs (Git, DMC, DMD, 7-Zip, WiX, VS2013 and Windows SDK components).

### Get Digger

The easiest way to obtain and run Digger is through Dub. As Dub is included with DMD, simply run:

    $ dub fetch digger
    $ dub run digger -- ARGS...

where `ARGS...` are the Digger command and arguments (see below).

### Command-line usage

(The command line examples below assume that Digger is installed in a location under `PATH` -
replace `digger ...` with `./digger ...` or `dub run digger -- ...` as appropriate.)

##### Building D

    # build latest master branch commit
    $ digger build

    # build a specific D version
    $ digger build v2.064.2

    # build for x86-64
    $ digger build --model=64 v2.064.2

    # build commit from a point in time
    $ digger build "@ 3 weeks ago"

    # build latest 2.065 (release) branch commit
    $ digger build 2.065

    # build specified branch from a point in time
    $ digger build "2.065 @ 3 weeks ago"

    # build with added pull request
    $ digger build "master + dmd#123"

    # build with added GitHub fork branch
    $ digger build "master + Username/dmd/awesome-feature"

    # build with reverted commit
    $ digger build "master + -dmd/0123456789abcdef0123456789abcdef01234567"

    # build with reverted pull request
    $ digger build "master + -dmd#123"

##### Building D programs

    # Run the last built DMD version
    $ digger run - -- dmd --help

    # Build and run latest DMD master
    $ digger run master -- dmd --help

    # Build latest DMD master, and then build and run a D program using it
    $ digger run master -- dmd -i -run program.d

##### Hacking on D

    # check out git master (or some other version)
    $ digger checkout

    # build / incrementally rebuild current checkout
    $ digger rebuild

    # run tests
    $ digger test

Run `digger` with no arguments for detailed usage help.

##### Installing

Digger does not build all D components - only those that change frequently and depend on one another.
You can get a full package by upgrading an installation of a stable DMD release with Digger's build result:

    # upgrade the DMD in your PATH with Digger's result
    $ digger install

You can undo this at any time by running:

    $ digger uninstall

Successive installs will not clobber the backups created by the first `digger install` invocation,
so `digger uninstall` will revert to the state from before you first ran `digger install`.

You can also simultaneously install 32-bit and 64-bit versions of Phobos by first building and installing a 32-bit DMD,
then a 64-bit DMD (`--model=64`). `digger uninstall` will revert both actions.

To upgrade a system install of DMD on POSIX, simply run `digger install` as root, e.g. `sudo digger install`.

`digger install` should be compatible with [DVM](https://github.com/jacob-carlborg/dvm) or any other DMD installation.

Installation and uninstallation are designed with safety in mind.
When installing, Digger will provide detailed information and ask for confirmation before making any changes
(you can use the `--dry-run` / `--yes` switches to suppress the prompt).
Uninstallation will refuse to remove files if they were modified since they were installed,
to prevent accidentally clobbering user work (you can use `--force` to override this).

##### Bisecting

To bisect D's history to find which pull request introduced a bug, first copy `bisect.ini.sample` to `bisect.ini`, adjust as instructed by the comments, then run:

    $ digger bisect path/to/bisect.ini

If Digger ends up with a master/stable merge as the bisection result, switch the branches on the starting points accordingly, e.g.:

- If you specified `good=v2.080.0` and `bad=v2.081.0`, try `good=master@v2.080.0` and `bad=master@v2.081.0`
- If you specified `good=@2018-01-01` and `bad=@2019-01-01`, try `good=stable@2018-01-01` and `bad=stable@2019-01-01`
- Note that the master/stable branch-offs/merges do not happen at the same time as when releases are tagged,
  so you may need to increase the bisection range accordingly. See [DIP75](https://wiki.dlang.org/DIP75) for details.

### Configuration

You can optionally configure a few settings using a configuration file.
To do so, copy `digger.ini.sample` to `digger.ini` and adjust as instructed by the comments.

### Building

    $ dub build

— or —

    $ git clone --recursive https://github.com/CyberShadow/Digger
    $ cd Digger
    $ rdmd --build-only -Isource -ofdigger source/digger/digger.d

* If you get a link error, you may need to add `-allinst` or `-debug` due to [a DMD bug](https://github.com/CyberShadow/Digger/issues/37).

* On Windows, you may see:

      Warning 2: File Not Found version.lib

  This is a benign warning.

### Hacking

##### Backend

The code which builds D and manages the git repository is located in the `digger.build` package, so as to be reusable.

Currently, the bulk of the code is in  [`digger.build.manager`](https://github.com/CyberShadow/Digger/blob/master/source/digger/build/manager.d).

`digger.build.manager` clones [a meta-repository on BitBucket](https://bitbucket.org/cybershadow/d), which contains the major D components as submodules.
The meta-repository is created and maintained by another program, [D-dot-git](https://github.com/CyberShadow/D-dot-git).

The build requirements are fulfilled by the [`ae.sys.install`](https://github.com/CyberShadow/ae/tree/master/sys/install) package.

##### Frontend

Digger is the frontend to the above library code, implementing configuration, bisecting, etc.

Module list is as follows:

- `config` - configuration
- `repo` - customized D repository management, revision parsing
- `bisect` - history bisection
- `custom` - custom build management
- `install` - installation
- `digger` - entry point and command-line UI
- `common` - shared helpers

### Remarks

##### Wine

Digger should work fine under Wine. For 64-bit builds, you must first run `winetricks vcrun2013`.
Digger cannot do this automatically as this must be done from outside Wine.

