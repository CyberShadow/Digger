module custom;

import std.algorithm;
import std.array;
import std.exception;
import std.file;
import std.getopt;
import std.path;
import std.stdio;
import std.string;

import ae.sys.d.customizer;
import ae.utils.array;
import ae.utils.regex;

import common;
import repo;

alias indexOf = std.string.indexOf;

alias subDir!"result" resultDir;

class DiggerCustomizer : DCustomizer
{
	this() { super(repo.d); }

	override void initialize()
	{
		if (!d.repoDir.exists)
			d.log("First run detected.\nPlease be patient, " ~
				"cloning everything might take a few minutes...\n");

		super.initialize();
	}

	/// Build the customized D version.
	/// The result will be in resultDir.
	void runBuild(BuildConfig buildConfig)
	{
		d.config.build = buildConfig;
		d.build();

		d.log("Moving...");
		if (resultDir.exists)
			resultDir.rmdirRecurse();
		rename(d.buildDir, resultDir);

		d.log("Build successful.\n\nAdd %s to your PATH to start using it.".format(
			resultDir.buildPath("bin").absolutePath()
		));
	}

	override string getCallbackCommand()
	{
		return escapeShellFileName(thisExePath) ~ " do callback";
	}
}

int handleWebTask(string[] args)
{
	enforce(args.length, "No task specified");
	auto customizer = new DiggerCustomizer();
	switch (args[0])
	{
		case "initialize":
			customizer.initialize();
			log("Ready.");
			return 0;
		case "begin":
			customizer.begin(args.length == 1 ? null : args[1]);
			log("Ready.");
			return 0;
		case "merge":
			enforce(args.length == 3);
			customizer.mergePull(args[1], args[2]);
			return 0;
		case "unmerge":
			enforce(args.length == 3);
			customizer.unmergePull(args[1], args[2]);
			return 0;
		case "merge-fork":
			enforce(args.length == 4);
			customizer.mergeFork(args[1], args[2], args[3]);
			return 0;
		case "unmerge-fork":
			enforce(args.length == 4);
			customizer.unmergeFork(args[1], args[2], args[3]);
			return 0;
		case "callback":
			customizer.callback(args[1..$]);
			return 0;
		case "build":
		{
			string model;
			getopt(args,
				"model", &model,
			);
			enforce(args.length == 1, "Unrecognized build option");

			BuildConfig buildConfig;
			if (model.length)
				buildConfig.model = model;

			customizer.runBuild(buildConfig);
			return 0;
		}
		case "branches":
			foreach (line; d.repo.query("branch", "--remotes").splitLines())
				if (line.startsWith("  origin/") && line[2..$].indexOf(" ") < 0)
					writeln(line[9..$]);
			return 0;
		case "tags":
			d.repo.run("tag");
			return 0;
		default:
			assert(false);
	}
}

/// Build D according to the given spec string
/// (e.g. master+dmd#123).
void buildCustom(string spec, BuildConfig buildConfig)
{
	auto customizer = new DiggerCustomizer();
	customizer.initialize();

	auto parts = spec.split("+");
	parts = parts.map!strip().array();
	if (parts.empty)
		parts = [null];
	auto rev = parseRev(parts.shift());

	customizer.begin(rev);

	foreach (part; parts)
	{
		if (part.matchCaptures(re!`^(\w+)#(\d+)$`,
			(string component, string pull)
			{
				customizer.mergePull(component, pull);
			}))
			continue;

		if (part.matchCaptures(re!`^(\w+)/(\w[\w\-]*)/(\w[\w\-]*)$`,
			(string user, string repo, string branch)
			{
				customizer.mergeFork(user, repo, branch);
			}))
			continue;

		throw new Exception("Don't know how to apply customization: " ~ spec);
	}

	customizer.runBuild(buildConfig);
}
