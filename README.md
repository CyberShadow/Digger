# Digger [![Build Status](https://travis-ci.org/CyberShadow/Digger.svg?branch=master)](https://travis-ci.org/CyberShadow/Digger) [![AppVeyor](https://ci.appveyor.com/api/projects/status/tm98i6iw931ma3yg?svg=true)](https://ci.appveyor.com/project/CyberShadow/digger)

Digger can:

- build D from [git](https://github.com/D-Programming-Language)
- build older versions of D
- build D plus forks and pending pull requests
- bisect D's history to find where regressions are introduced (or bugs fixed)

Digger has a simple command-line interface, as well as a web interface for customizing your custom D build.

### Requirements

On POSIX, Digger needs git, g++, binutils and make.

On Windows, Digger will download and unpack everything it needs (Git, DMC, DMD, 7-Zip, WiX, VS2013 and Windows SDK components).

### Get Digger

You can find binaries on the [GitHub releases](https://github.com/CyberShadow/Digger/releases) page.

### Command-line usage

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

### Web interface

Run `digger-web` to start the web interface, which allows interactively customizing a D version to build.

If you built `digger-web` from source, you also need to build `digger` itself.

### Configuration

You can optionally configure a few settings using a configuration file.
To do so, copy `digger.ini.sample` to `digger.ini` and adjust as instructed by the comments.

### Building

    $ git clone --recursive https://github.com/CyberShadow/Digger
    $ cd Digger
    $ rdmd --build-only digger
    $ rdmd --build-only digger-web

On Windows, you may see:

    Warning 2: File Not Found version.lib

This is a benign warning.

### Hacking

##### Backend

The code which builds D and manages the git repository is located in the [ae library](https://github.com/CyberShadow/ae)
(`ae.sys.d` package), so as to be reusable.

Currently, the bulk of the code is in [`ae.sys.d.manager`](https://github.com/CyberShadow/ae/blob/master/sys/d/manager.d).

`ae.sys.d.manager` clones [a meta-repository on BitBucket](https://bitbucket.org/cybershadow/d), which contains the major D components as submodules.
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
- `digger-web` - web interface, works by launching `digger` sub-processes
- `common` - helpers shared by `digger` and `digger-web`

### Remarks

##### Wine

Digger should work fine under Wine. For 64-bit builds, you must first run `winetricks vcrun2013`.
Digger cannot do this automatically as this must be done from outside Wine.
