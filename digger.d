module digger;

import std.exception;
import std.file : thisExePath;
import std.typetuple;

version(Windows) static import ae.sys.net.wininet;

import ae.utils.funopt;
import ae.utils.meta : structFun;
import ae.utils.text : eatLine;

import bisect;
import cache;
import config;
import custom;
import repo;

// http://d.puremagic.com/issues/show_bug.cgi?id=7016
version(Windows) static import ae.sys.windows;

alias BuildOptions = TypeTuple!(
	Switch!("Build a 64-bit compiler", 0, "64"),
	Option!(string[], `Additional make parameters, e.g. "-j8" or "HOST_CC=g++48"`, "ARG", 0, "makeArgs"),
);

alias Spec = Parameter!(string, "D ref (branch / tag / point in time) to build, plus any additional forks or pull requests. Example:\n"
	"\"master @ 3 weeks ago + dmd#123 + You/dmd/awesome-feature\"");

BuildConfig parseBuildOptions(BuildOptions options)
{
	BuildConfig buildConfig;
	if (options[0])
		buildConfig.model = "64";
	buildConfig.makeArgs = options[1];
	return buildConfig;
}

struct Digger
{
static:
	@(`Build D from source code`)
	int build(BuildOptions options, Spec spec = "master")
	{
		buildCustom(spec, parseBuildOptions(options));
		return 0;
	}

	@(`Incrementally rebuild the current D checkout`)
	int rebuild(BuildOptions options)
	{
		incrementalBuild(parseBuildOptions(options));
		return 0;
	}

	@(`Bisect D history according to a bisect.ini file`)
	int bisect(bool inBisect, bool noVerify, string bisectConfigFile)
	{
		return doBisect(inBisect, noVerify, bisectConfigFile);
	}

	@(`Compact the cache (replace identical files with hard links)`)
	int compact()
	{
		optimizeCache();
		return 0;
	}

	// hidden actions

	int buildAll(BuildOptions options, int step = 1, string spec = "master")
	{
		.buildAll(spec, parseBuildOptions(options), step);
		return 0;
	}

	int delve(bool inBisect)
	{
		return doDelve(inBisect);
	}

	int show(string revision)
	{
		d.repo.run("log", "-n1", revision);
		d.repo.run("log", "-n1", "--pretty=format:t=%ct", revision);
		return 0;
	}

	int help()
	{
		throw new Exception("For help, run digger without any arguments.");
	}
}

int doMain()
{
	if (opts.action == "do")
		return handleWebTask(opts.actionArguments.dup);

	static void usageFun(string usage)
	{
		import std.algorithm, std.array, std.stdio, std.string;
		auto lines = usage.splitLines();

		stderr.writeln("Digger - a D source code building and archaeology tool");
		stderr.writeln("Created by Vladimir Panteleev <vladimir@thecybershadow.net>");
		stderr.writeln("https://github.com/CyberShadow/Digger");
		stderr.writeln();

		if (lines[0].canFind("ACTION [ACTION-ARGUMENTS]"))
		{
			lines =
				[lines[0].replace(" ACTION ", " [OPTION]... ACTION ")] ~
				getUsageFormatString!(structFun!Opts).splitLines()[1..$] ~
				lines[1..$];

			stderr.writefln("%-(%s\n%)", lines);
			stderr.writeln();
			stderr.writeln("For help on a specific action, run: digger ACTION --help");
			stderr.writeln("For more information, see README.md.");
			stderr.writeln();
		}
		else
			stderr.writefln("%-(%s\n%)", lines);
	}

	return funoptDispatch!(Digger, FunOptConfig.init, usageFun)([thisExePath] ~ (opts.action ? [opts.action.value] ~ opts.actionArguments : []));
}

int main()
{
	debug
		return doMain();
	else
	{
		try
			return doMain();
		catch (Exception e)
		{
			import std.stdio : stderr;
			stderr.writefln("Fatal error: %s", e.msg);
			return 1;
		}
	}
}
