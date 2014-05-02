module common;

import std.exception;
import std.process;
import std.stdio;
import std.string;

import core.runtime;

import std.file;
import std.getopt;
import std.path;

import ae.utils.sini;

struct Opts
{
	immutable(string)[] args;

	string dir;
	string configFile;
}
immutable Opts opts;

struct ConfigFile
{
	string workDir;
	bool cache;
	immutable string[string] environment;
}
immutable ConfigFile config;

shared static this()
{
	Opts opts;
	auto args = Runtime.args;
	getopt(args,
		"dir"        , &opts.dir,
		"config-file", &opts.configFile,
		std.getopt.config.stopOnFirstNonOption
	);
	if (args.length > 1)
		opts.args = args[1..$].idup;

	if (opts.dir)
		chdir(opts.dir);

	enum CONFIG_FILE = "digger.ini";

	if (!opts.configFile)
	{
		opts.configFile = CONFIG_FILE;
		if (!opts.configFile.exists)
			opts.configFile = buildPath(thisExePath.dirName, CONFIG_FILE);
		if (!opts.configFile.exists)
			opts.configFile = buildPath(__FILE__.dirName, CONFIG_FILE);
		if (!opts.configFile.exists)
			opts.configFile = buildPath(environment.get("HOME", environment.get("USERPROFILE")), ".digger", CONFIG_FILE);
	}

	if (opts.configFile.exists)
	{
		config = opts.configFile
			.readText()
			.splitLines()
			.parseStructuredIni!ConfigFile();
	}

	.opts = opts;
}

@property string subDir(string name)() { return buildPath(config.workDir, name); }

// ****************************************************************************

/// Send to stderr iff we have a console to write to
void writeToConsole(string s)
{
	version (Windows)
	{
		import core.sys.windows.windows;
		auto h = GetStdHandle(STD_ERROR_HANDLE);
		if (!h || h == INVALID_HANDLE_VALUE)
			return;
	}

	stderr.write(s); stderr.flush();
}

void log(string s)
{
	writeToConsole("digger: " ~ s ~ "\n");
}
