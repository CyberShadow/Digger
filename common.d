module common;

import std.exception;
import std.process;
import std.stdio;
import std.string;

import core.runtime;

import std.file;
static import std.getopt;
import std.path;

import ae.utils.funopt;
import ae.utils.meta;
import ae.utils.sini;

struct Opts
{
	Option!(string, hiddenOption) dir;
	Option!(string, "Path to the configuration file to use", "PATH") configFile;
	Switch!("Do not update D repositories from GitHub") offline;

	string action;
	Parameter!(immutable(string)[]) actionArguments;
}
immutable Opts opts;

struct ConfigFile
{
	string workDir;
	bool cache;
	string[string] environment;
}
immutable ConfigFile config;

shared static this()
{
	alias fun = structFun!Opts;
	enum funOpts = FunOptConfig([std.getopt.config.stopOnFirstNonOption]);
	void usageFun(string) {}
	auto opts = funopt!(fun, funOpts, usageFun)(Runtime.args);

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
		config = cast(immutable)
			opts.configFile
			.readText()
			.splitLines()
			.parseStructuredIni!ConfigFile();
	}

	.opts = opts;
}

@property string subDir(string name)() { return buildPath(config.workDir.expandTilde(), name); }

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
