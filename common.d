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
	invoke!{ return spawnProcess(args, newEnv, Config.newEnv).wait(); }(args, newEnv);
}

string query(string[] args, string[string] newEnv = null)
{
	string output;
	invoke!{ auto result = execute(args, newEnv, Config.newEnv); output = result.output.strip(); return result.status; }(args, newEnv);
	return output;
}

// ****************************************************************************

import core.runtime;

import std.file;
import std.getopt;

import ae.utils.sini;

struct Opts
{
	bool inBisect, noVerify, cache;
	string dir;
}
immutable Opts opts;

struct ConfigFile
{
	string bad, good;
	string tester;
	bool cache;
}
immutable ConfigFile config;

shared static this()
{
	Opts opts;
	auto args = Runtime.args;
	getopt(args,
		"no-verify", &opts.noVerify,
		"cache"    , &opts.cache,

		"in-bisect", &opts.inBisect,
		"dir"      , &opts.dir,
	);
	.opts = opts;

	if (opts.dir)
		chdir(opts.dir);

	config = "dsector.ini"
		.readText()
		.splitLines()
		.parseStructuredIni!ConfigFile();
}

// ****************************************************************************

void log(string s)
{
	stderr.writeln("dsector: ", s);
}

alias logProgress = log;

// ****************************************************************************

auto pushd(string dir)
{
	struct Popd { string owd; ~this() { chdir(owd); } }
	auto cwd = getcwd();
	chdir(dir);
	return Popd(cwd);
}
