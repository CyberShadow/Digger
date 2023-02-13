module digger.digger;

import std.array;
// import std.exception;
import std.file : thisExePath, exists;
import std.meta;
// import std.path;
// import std.process;
// import std.stdio;

static if(!is(typeof({import ae.utils.text;}))) static assert(false, "ae library not found, did you clone with --recursive?"); else:

version (Windows)
	static import ae.sys.net.wininet;
else
	static import ae.sys.net.curl;

import ae.utils.funopt;
import ae.utils.main;
import ae.utils.meta : structFun;
import ae.utils.text : eatLine;

import digger.bisect;
import digger.build.config : BuildConfig;
import digger.common;
import digger.config;
import digger.custom;
import digger.site;

// http://d.puremagic.com/issues/show_bug.cgi?id=7016
version(Windows) static import ae.sys.windows;

alias BuildOptions = AliasSeq!(
	Option!(string[],
		"Do not include a component (that would otherwise be included by default). " ~
		"List of default components: " ~ defaultComponents.join(", ") ~ " [build.components.enable.COMPONENT=false]",
		"COMPONENT", 0, "without"
	),
	Option!(string[],
		"Specify an additional D component to include. " ~
		"Run \"digger list-components\" for a list of all available components. [build.components.enable.COMPONENT=true]",
		"COMPONENT", 0, "with"
	),
);

enum versionSpecDescription =
	"D ref (branch / tag / point in time) to build, plus any additional forks or pull requests. Example:\n" ~
	"\"master @ 3 weeks ago + dmd#123 + You/dmd/awesome-feature\"";

/// Build instructions as specified on the Digger CLI.
struct DiggerBuildSpec
{
	/// Version specification in Digger CLI syntax
	/// (e.g. "master+dmd#123")
	string versionSpec;

	/// Build config
	immutable BuildConfig buildConfig;

	/// Explicitly enable or disable a component.
	/// Overrides digger.config.defaultComponents.
	bool[string] enableComponent;
}

void parseBuildOptions(T...)(ref DiggerBuildSpec spec, T options) // T == BuildOptions!action
{
	foreach (componentName; options[0])
		spec.enableComponent[componentName] = false;
	foreach (componentName; options[1])
		spec.enableComponent[componentName] = true;
	static assert(options.length == 2);
}

struct Digger
{
static:
	@(`Build D from source code`)
	int build(BuildOptions options, Parameter!(string, versionSpecDescription) versionSpec = "master")
	{
		auto spec = DiggerBuildSpec(versionSpec, config.build);
		parseBuildOptions(spec, options);
		buildCustom(spec);
		return 0;
	}

	// @(`Incrementally rebuild the current D checkout`)
	// int rebuild(BuildOptions!("rebuild", "rebuilt") options)
	// {
	// 	parseBuildOptions(options);
	// 	incrementalBuild();
	// 	return 0;
	// }

	// @(`Run tests for enabled components`)
	// int test(BuildOptions!("test", "tested") options)
	// {
	// 	parseBuildOptions(options);
	// 	runTests();
	// 	return 0;
	// }

	// @(`Check out D source code from git`)
	// int checkout(BuildOptions!("check out", "checked out", false) options, Parameter!(string, versionSpecDescription) spec = "master")
	// {
	// 	parseBuildOptions(options);
	// 	.checkout(spec);
	// 	return 0;
	// }

	// @(`Run a command using a D version`)
	// int run(
	// 	BuildOptions options,
	// 	Parameter!(string, versionSpecDescription) versionSpec,
	// 	Parameter!(string[], "Command to run and its arguments (use -- to pass switches)") command)
	// {
	// 	DiggerBuildSpec spec;
	// 	spec.versionSpec = versionSpec;
	// 	parseBuildOptions(spec, options);
	// 	buildCustom(spec, /*asNeeded*/true);

	// 	auto binPath = resultDir.buildPath("bin").absolutePath();
	// 	environment["PATH"] = binPath ~ pathSeparator ~ environment["PATH"];

	// 	version (Windows)
	// 		return spawnProcess(command).wait();
	// 	else
	// 	{
	// 		execvp(command[0], command);
	// 		errnoEnforce(false, "execvp failed");
	// 		assert(false); // unreachable
	// 	}
	// }

	// @(`Bisect D history according to a bisect.ini file`)
	// int bisect(
	// 	Switch!("Skip sanity-check of the GOOD/BAD commits.") noVerify,
	// 	Option!(string[], "Additional bisect configuration. Equivalent to bisect.ini settings.", "NAME=VALUE", 'c', "config") configLines,
	// 	Parameter!(string, "Location of the bisect.ini file containing the bisection description.") bisectConfigFile = null,
	// )
	// {
	// 	return doBisect(noVerify, bisectConfigFile, configLines);
	// }

	// @(`Cache maintenance actions (run with no arguments for details)`)
	// int cache(string[] args)
	// {
	// 	static struct CacheActions
	// 	{
	// 	static:
	// 		@(`Compact the cache`)
	// 		int compact()
	// 		{
	// 			d.optimizeCache();
	// 			return 0;
	// 		}

	// 		@(`Delete entries cached as unbuildable`)
	// 		int purgeUnbuildable()
	// 		{
	// 			d.purgeUnbuildable();
	// 			return 0;
	// 		}

	// 		@(`Migrate cached entries from one cache engine to another`)
	// 		int migrate(string source, string target)
	// 		{
	// 			d.migrateCache(source, target);
	// 			return 0;
	// 		}
	// 	}

	// 	return funoptDispatch!CacheActions(["digger cache"] ~ args);
	// }

	// // hidden actions

	// int buildAll(BuildOptions options, string spec = "master")
	// {
	// 	parseBuildOptions(options);
	// 	.buildAll(spec);
	// 	return 0;
	// }

	// int delve(bool inBisect)
	// {
	// 	return doDelve(inBisect);
	// }

	// int parseRev(string rev)
	// {
	// 	stdout.writeln(.parseRev(rev));
	// 	return 0;
	// }

	// int show(string revision)
	// {
	// 	d.getMetaRepo().git.run("log", "-n1", revision);
	// 	d.getMetaRepo().git.run("log", "-n1", "--pretty=format:t=%ct", revision);
	// 	return 0;
	// }

	// int getLatest()
	// {
	// 	writeln((cast(DManager.Website)d.getComponent("website")).getLatest());
	// 	return 0;
	// }

	// int help()
	// {
	// 	throw new Exception("For help, run digger without any arguments.");
	// }

	// version (Windows)
	// int getAllMSIs()
	// {
	// 	d.getVSInstaller().getAllMSIs();
	// 	return 0;
	// }
}

int program()
{
	version (D_Coverage)
	{
		import core.runtime;
		dmd_coverSetMerge(true);
	}

	static void usageFun(string usage)
	{
		import std.algorithm, std.array, std.stdio, std.string;
		auto lines = usage.splitLines();

		stderr.writeln("Digger v" ~ diggerVersion ~ " - a D source code building and archaeology tool");
		stderr.writeln("Created by Vladimir Panteleev <digger@cy.md>");
		stderr.writeln("https://github.com/CyberShadow/Digger");
		stderr.writeln();
		stderr.writeln("Configuration file: ", opts.configFile.value.exists ? opts.configFile.value : "(not present)");
		stderr.writeln("Working directory: ", config.local.workDir);
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

mixin main!program;
