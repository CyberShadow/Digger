# Digger

Digger is a tool for working with D's history.
It can build old D versions, and find the exact pull request which introduced a regression (or fixed a bug).

### Requirements

Git is required.

Currently, you must have Microsoft Visual Studio 2010 and Windows SDK v7.0A installed to build for Windows/64.

### Configuration

Copy `digger.ini.sample` to `digger.ini` and adjust as instructed by the comments.

### Usage

To build a specific D version:

    $ digger build v2.064.2
    $ digger build master
    $ digger build --64 master
    $ digger build "@ 3 weeks ago"

To bisect D's history to find which pull request introduced a bug, first copy `bisect.ini.sample` to `bisect.ini`, adjust as instructed by the comments, then run:

    $ digger bisect path/to/bisect.ini

