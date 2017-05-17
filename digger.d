module digger;

import std.array;
import std.exception;
import std.file : thisExePath, exists;
import std.stdio;
import std.typetuple;

static if(!is(typeof({import ae.utils.text;}))) static assert(false, "ae library not found, did you clone with --recursive?"); else:

version (Windows)
	static import ae.sys.net.wininet;
else
	static import ae.sys.net.ae;

import ae.sys.d.manager : DManager;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.meta : structFun;
import ae.utils.text : eatLine;

import bisect;
import common;
import config;
import custom;
import install;
import repo;

// http://d.puremagic.com/issues/show_bug.cgi?id=7016
version(Windows) static import ae.sys.windows;

alias BuildOptions(string action, string pastAction, bool showBuildActions = true) = TypeTuple!(
	Switch!(hiddenOption, 0, "64"),
	Option!(string, showBuildActions ? "Select model (32, 64, or, on Windows, 32mscoff).\nOn this system, the default is " ~ DManager.Config.Build.components.common.defaultModel ~ " [build.components.common.model]" : hiddenOption, null, 0, "model"),
	Option!(string[], "Do not " ~ action ~ " a component (that would otherwise be " ~ pastAction ~ " by default). List of default components: " ~ DManager.defaultComponents.join(", ") ~ " [build.components.enable.COMPONENT=false]", "COMPONENT", 0, "without"),
	Option!(string[], "Specify an additional D component to " ~ action ~ ". List of available additional components: " ~ DManager.additionalComponents.join(", ") ~ " [build.components.enable.COMPONENT=true]", "COMPONENT", 0, "with"),
	Option!(string[], showBuildActions ? `Additional make parameters, e.g. "HOST_CC=g++48" [build.components.common.makeArgs]` : hiddenOption, "ARG", 0, "makeArgs"),
	Switch!(showBuildActions ? "Bootstrap the compiler (build from C++ source code) instead of downloading a pre-built binary package [build.components.dmd.bootstrap.fromSource]" : hiddenOption, 0, "bootstrap"),
	Switch!(hiddenOption, 0, "use-vc"),
);

alias Spec = Parameter!(string, "D ref (branch / tag / point in time) to build, plus any additional forks or pull requests. Example:\n" ~
	"\"master @ 3 weeks ago + dmd#123 + You/dmd/awesome-feature\"");

void parseBuildOptions(T...)(T options) // T == BuildOptions!action
{
	if (options[0])
		d.config.build.components.common.model = "64";
	if (options[1])
		d.config.build.components.common.model = options[1];
	foreach (componentName; options[2])
		d.config.build.components.enable[componentName] = false;
	foreach (componentName; options[3])
		d.config.build.components.enable[componentName] = true;
	d.config.build.components.common.makeArgs ~= options[4];
	d.config.build.components.dmd.bootstrap.fromSource |= options[5];
	d.config.build.components.dmd.useVC |= options[6];
	static assert(options.length == 7);
}

struct Digger
{
static:
	@(`Build D from source code`)
	int build(BuildOptions!("build", "built") options, Spec spec = "master")
	{
		parseBuildOptions(options);
		buildCustom(spec);
		return 0;
	}

	@(`Incrementally rebuild the current D checkout`)
	int rebuild(BuildOptions!("rebuild", "rebuilt") options)
	{
		parseBuildOptions(options);
		incrementalBuild();
		return 0;
	}

	@(`Run tests for enabled components`)
	int test(BuildOptions!("test", "tested") options)
	{
		parseBuildOptions(options);
		runTests();
		return 0;
	}

	@(`Check out D source code from git`)
	int checkout(BuildOptions!("check out", "checked out", false) options, Spec spec = "master")
	{
		parseBuildOptions(options);
		.checkout(spec);
		return 0;
	}

	@(`Install Digger's build result on top of an existing stable DMD installation`)
	int install(
		Switch!("Do not prompt", 'y') yes,
		Switch!("Only print what would be done", 'n') dryRun,
		Parameter!(string, "Directory to install to. Default is to find one in PATH.") installLocation = null,
	)
	{
		enforce(!yes || !dryRun, "--yes and --dry-run are mutually exclusive");
		.install.install(yes, dryRun, installLocation);
		return 0;
	}

	@(`Undo the "install" action`)
	int uninstall(
		Switch!("Only print what would be done", 'n') dryRun,
		Switch!("Do not verify files to be deleted; ignore errors") force,
		Parameter!(string, "Directory to uninstall from. Default is to search PATH.") installLocation = null,
	)
	{
		.uninstall(dryRun, force, installLocation);
		return 0;
	}

	@(`Bisect D history according to a bisect.ini file`)
	int bisect(
		Switch!("Skip sanity-check of the GOOD/BAD commits.") noVerify,
		Option!(string[], "Additional bisect configuration. Equivalent to bisect.ini settings.", "NAME=VALUE", 'c', "config") configLines,
		Parameter!(string, "Location of the bisect.ini file containing the bisection description.") bisectConfigFile = null,
	)
	{
		return doBisect(noVerify, bisectConfigFile, configLines);
	}

	@(`Cache maintenance actions (run with no arguments for details)`)
	int cache(string[] args)
	{
		static struct CacheActions
		{
		static:
			@(`Compact the cache`)
			int compact()
			{
				d.optimizeCache();
				return 0;
			}

			@(`Delete entries cached as unbuildable`)
			int purgeUnbuildable()
			{
				d.purgeUnbuildable();
				return 0;
			}

			@(`Migrate cached entries from one cache engine to another`)
			int migrate(string source, string target)
			{
				d.migrateCache(source, target);
				return 0;
			}
		}

		return funoptDispatch!CacheActions(["digger cache"] ~ args);
	}

	// hidden actions

	int buildAll(BuildOptions!("build", "built") options, string spec = "master")
	{
		parseBuildOptions(options);
		.buildAll(spec);
		return 0;
	}

	int delve(bool inBisect)
	{
		return doDelve(inBisect);
	}

	int parseRev(string rev)
	{
		stdout.writeln(.parseRev(rev));
		return 0;
	}

	int show(string revision)
	{
		d.getMetaRepo().needRepo();
		d.getMetaRepo().git.run("log", "-n1", revision);
		d.getMetaRepo().git.run("log", "-n1", "--pretty=format:t=%ct", revision);
		return 0;
	}

	int getLatest()
	{
		writeln((cast(DManager.Website)d.getComponent("website")).getLatest());
		return 0;
	}

	int help()
	{
		throw new Exception("For help, run digger without any arguments.");
	}

	version (Windows)
	int getAllMSIs()
	{
		d.getVSInstaller().getAllMSIs();
		return 0;
	}
}

int digger()
{
	version (D_Coverage)
	{
		import core.runtime;
		dmd_coverSetMerge(true);
	}

	if (opts.action == "do")
		return handleWebTask(opts.actionArguments.dup);

	static void usageFun(string usage)
	{
		import std.algorithm, std.array, std.stdio, std.string;
		auto lines = usage.splitLines();

		stderr.writeln("Digger v" ~ diggerVersion ~ " - a D source code building and archaeology tool");
		stderr.writeln("Created by Vladimir Panteleev <vladimir@thecybershadow.net>");
		stderr.writeln("https://github.com/CyberShadow/Digger");
		stderr.writeln();
		stderr.writeln("Configuration file: ", opts.configFile.value.exists ? opts.configFile.value : "(not present)");
		stderr.writeln("Working directory: ", config.config.local.workDir);
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

mixin main!digger;
