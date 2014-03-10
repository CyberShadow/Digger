module common;

import std.exception;
import std.process;
import std.stdio;
import std.string;

void invoke(alias runner)(string[] args, ref string[string] newEnv)
{
	//debug scope(failure) std.stdio.writeln("[CWD] ", getcwd());
	//debug scope(failure) foreach (k, v; environment.toAA) std.stdio.writefln("[ENV] %s=%s", k, v);

	if (newEnv is null) newEnv = environment.toAA();
	string oldPath = environment["PATH"];
	scope(exit) environment["PATH"] = oldPath;
	environment["PATH"] = newEnv["PATH"];

	auto status = runner();
	enforce(status == 0, "Command %s failed with status %d".format(args, status));
}

void run(string[] args, string[string] newEnv = null)
{
	invoke!({ return spawnProcess(args, newEnv, Config.newEnv).wait(); })(args, newEnv);
}

string query(string[] args, string[string] newEnv = null)
{
	string output;
	invoke!({ auto result = execute(args, newEnv, Config.newEnv); output = result.output.strip(); return result.status; })(args, newEnv);
	return output;
}

// ****************************************************************************

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

void log(string s)
{
	stderr.writeln("digger: ", s);
}

void logProgress(string s)
{
	log((" " ~ s ~ " ").center(70, '-'));
}
