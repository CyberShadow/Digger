module config;

import std.file;
import std.path;
import std.process : environment;
import std.string;

import core.runtime;

import ae.utils.funopt;
import ae.utils.meta;
import ae.utils.sini;

static import std.getopt;

struct Opts
{
	Option!(string, hiddenOption) dir;
	Option!(string, "Path to the configuration file to use", "PATH") configFile;
	Switch!("Do not update D repositories from GitHub") offline;

	Parameter!(string, "Action to perform (see list below)") action;
	Parameter!(immutable(string)[]) actionArguments;
}
immutable Opts opts;

struct ConfigFile
{
	string workDir;
	string cache;
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
		version (Posix)
		{
			if (!opts.configFile.exists)
				opts.configFile = buildPath("/etc/", CONFIG_FILE);
		}
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

@property string workDir() { return (config.workDir ? config.workDir.expandTilde() : getcwd()).absolutePath(); }
@property string subDir(string name)() { return buildPath(workDir, name); }
