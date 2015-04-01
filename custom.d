module custom;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.getopt;
import std.path;
import std.stdio;
import std.string;

import ae.sys.d.manager;
import ae.utils.array;
import ae.utils.json;
import ae.utils.regex;

import common;
import config;
import install;
import repo;

alias indexOf = std.string.indexOf;

alias subDir!"result" resultDir;

/// We save a JSON file to the result directory with the build parameters.
struct BuildInfo
{
	string diggerVersion;
	string spec;
	BuildConfig config;
}

enum buildInfoFileName = "build-info.json";

void prepareResult()
{
	log("Moving...");
	if (resultDir.exists)
		resultDir.rmdirRecurse();
	rename(d.buildDir, resultDir);

	log("Build successful.\n\nTo start using it, run `digger install`, or add %s to your PATH.".format(
		resultDir.buildPath("bin").absolutePath()
	));
}

/// Build the customized D version.
/// The result will be in resultDir.
void runBuild(string spec, DManager.SubmoduleState submoduleState, BuildConfig buildConfig, in string[] components = DManager.defaultComponents)
{
	d.build(submoduleState, buildConfig, components);
	prepareResult();
	std.file.write(buildPath(resultDir, buildInfoFileName), BuildInfo(diggerVersion, spec, buildConfig).toJson());
}

/// Perform an incremental build, i.e. don't clean or fetch anything from remote repos
void incrementalBuild(BuildConfig buildConfig)
{
	d.rebuild(buildConfig);
	prepareResult();
}

/// Implements transient persistence for the current customization state.
struct DCustomizer
{
	struct CustomizationState
	{
		string spec;
		DManager.SubmoduleState submoduleState;
		string[string][string] pulls;
		string[string][string][string] forks;
	}
	CustomizationState state;

	enum fileName = "customization-state.json";

	void load()
	{
		state = fileName.readText().jsonParse!CustomizationState();
	}

	void save()
	{
		std.file.write(fileName, state.toJson());
	}

	void finish()
	{
		std.file.remove(fileName);
	}

	string getPull(string submoduleName, string pullNumber)
	{
		string rev = state.pulls.get(submoduleName, null).get(pullNumber, null);
		if (!rev)
			state.pulls[submoduleName][pullNumber] = rev = d.getPull(submoduleName, pullNumber.to!int);
		return rev;
	}

	string getFork(string submoduleName, string user, string branch)
	{
		string rev = state.forks.get(submoduleName, null).get(user, null).get(branch, null);
		if (!rev)
			state.forks[submoduleName][user][branch] = rev = d.getFork(submoduleName, user, branch);
		return rev;
	}
}

DCustomizer customizer;

int handleWebTask(string[] args)
{
	enforce(args.length, "No task specified");
	switch (args[0])
	{
		case "initialize":
			d.needUpdate();
			log("Ready.");
			return 0;
		case "begin":
			d.haveUpdate = true; // already updated in "initialize"
			customizer.state.spec = "digger-web @ " ~ (args.length == 1 ? "(master)" : args[1]);
			customizer.state.submoduleState = d.begin(parseRev(args.length == 1 ? null : args[1]));
			customizer.save();
			log("Ready.");
			return 0;
		case "merge":
			enforce(args.length == 3);
			customizer.load();
			d.merge(customizer.state.submoduleState, args[1], customizer.getPull(args[1], args[2]));
			customizer.save();
			return 0;
		case "unmerge":
			enforce(args.length == 3);
			customizer.load();
			d.unmerge(customizer.state.submoduleState, args[1], customizer.getPull(args[1], args[2]));
			customizer.save();
			return 0;
		case "merge-fork":
			enforce(args.length == 4);
			customizer.load();
			d.merge(customizer.state.submoduleState, args[2], customizer.getFork(args[2], args[1], args[3]));
			customizer.save();
			return 0;
		case "unmerge-fork":
			enforce(args.length == 4);
			customizer.load();
			d.unmerge(customizer.state.submoduleState, args[2], customizer.getFork(args[2], args[1], args[3]));
			customizer.save();
			return 0;
		case "callback":
			d.callback(args[1..$]);
			return 0;
		case "build":
		{
			customizer.load();

			string model;
			getopt(args,
				"model", &model,
			);
			enforce(args.length == 1, "Unrecognized build option");

			BuildConfig buildConfig;
			if (model.length)
				buildConfig.components.common.model = model;

			runBuild(customizer.state.spec, customizer.state.submoduleState, buildConfig);
			customizer.finish();
			return 0;
		}
		case "branches":
			d.getMetaRepo().needRepo();
			foreach (line; d.getMetaRepo().git.query("branch", "--remotes").splitLines())
				if (line.startsWith("  origin/") && line[2..$].indexOf(" ") < 0)
					writeln(line[9..$]);
			return 0;
		case "tags":
			d.getMetaRepo().needRepo();
			d.getMetaRepo().git.run("tag");
			return 0;
		case "install-preview":
			install.install(false, true);
			return 0;
		case "install":
			install.install(true, false);
			return 0;
		default:
			assert(false);
	}
}

/// Build D according to the given spec string
/// (e.g. master+dmd#123).
void buildCustom(string spec, BuildConfig buildConfig)
{
	log("Building spec: " ~ spec);

	auto parts = spec.split("+");
	parts = parts.map!strip().array();
	if (parts.empty)
		parts = [null];
	auto rev = parseRev(parts.shift());

	auto state = d.begin(rev);

	foreach (part; parts)
	{
		if (part.matchCaptures(re!`^(\w+)#(\d+)$`,
			(string component, int pull)
			{
				d.merge(state, component, d.getPull(component, pull));
			}))
			continue;

		if (part.matchCaptures(re!`^(\w+)/(\w[\w\-]*)/(\w[\w\-]*)$`,
			(string user, string component, string branch)
			{
				d.merge(state, component, d.getFork(component, user, branch));
			}))
			continue;

		throw new Exception("Don't know how to apply customization: " ~ spec);
	}

	runBuild(spec, state, buildConfig);
}

/// Build all D versions (for the purpose of caching them).
/// Build order is in steps of decreasing powers of two.
void buildAll(string spec, BuildConfig buildConfig)
{
	d.needUpdate();
	auto commits = d.getLog("refs/remotes/origin/" ~ spec);
	commits.reverse(); // oldest first

	for (int step = 1 << 30; step; step >>= 1)
	{
		if (step >= commits.length)
			continue;

		log("Building all revisions with step %d (%d/%d revisions)".format(step, commits.length/step, commits.length));

		for (int n = step; n < commits.length; n += step)
			try
			{
				auto state = d.begin(commits[n].hash);
				if (!d.isCached(state, buildConfig))
				{
					log("Building revision %d/%d".format(n/step, commits.length/step));
					d.build(state, buildConfig);
				}
			}
			catch (Exception e)
				log(e.toString());
	}
}
