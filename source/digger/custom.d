module digger.custom;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.getopt;
import std.path;
import std.stdio;
import std.string;

import ae.utils.array;
import ae.utils.json;
import ae.utils.regex;

// import digger.build.manager;
import digger.build.site;
import digger.build.versions;
import digger.common;
import digger.config : config;
import digger.site;

alias indexOf = std.string.indexOf;

// https://issues.dlang.org/show_bug.cgi?id=15777
alias strip = std.string.strip;

// alias subDir!"result" resultDir;

// /// We save a JSON file to the result directory with the build parameters.
// struct BuildInfo
// {
// 	string diggerVersion;
// 	string spec;
// 	DiggerManager.Config.Build config;
// 	DManager.SubmoduleState components;
// }

// enum buildInfoFileName = "build-info.json";

// void prepareResult()
// {
// 	log("Moving...");
// 	if (resultDir.exists)
// 		resultDir.rmdirRecurse();
// 	rename(d.buildDir, resultDir);

// 	log("Build successful.\n\nTo start using it, run `digger install`, or add %s to your PATH.".format(
// 		resultDir.buildPath("bin").absolutePath()
// 	));
// }

// /// Build the customized D version.
// /// The result will be in resultDir.
// void runBuild(string spec, DManager.SubmoduleState submoduleState, bool asNeeded)
// {
// 	auto buildInfoPath = buildPath(resultDir, buildInfoFileName);
// 	auto buildInfo = BuildInfo(diggerVersion, spec, d.config.build, submoduleState);
// 	if (asNeeded && buildInfoPath.exists && buildInfoPath.readText.jsonParse!BuildInfo == buildInfo)
// 	{
// 		log("Reusing existing version in " ~ resultDir);
// 		return;
// 	}
// 	d.build(submoduleState);
// 	prepareResult();
// 	std.file.write(buildInfoPath, buildInfo.toJson());
// }

// /// Perform an incremental build, i.e. don't clean or fetch anything from remote repos
// void incrementalBuild()
// {
// 	d.rebuild();
// 	prepareResult();
// }

// /// Run tests.
// void runTests()
// {
// 	d.test();
// }

VersionSpec parseSpec(string spec)
{
	return (historyWalker) {
		auto parts = spec.split("+");
		parts = parts.map!strip().array();
		if (parts.empty)
			parts = [null];

		historyWalker = historyWalker.resetToProductVersion(parts.shift());

		foreach (part; parts)
		{
			bool revert = part.skipOver("-");

			void apply(string component, string[2] branch, HistoryWalker.MergeMode mode)
			{
				if (revert)
					d.revert(state, component, branch, mode);
				else
					d.merge(state, component, branch, mode);
			}

			if (part.matchCaptures(re!`^(\w[\w\-\.]*)#(\d+)$`,
				(string component, int pull)
				{
					apply(component, d.getPull(component, pull), DManager.MergeMode.cherryPick);
				}))
				continue;

			if (part.matchCaptures(re!`^(?:([a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])/)?(\w[\w\-\.]*)/(?:(\w[\w\-]*)\.\.)?(\w[\w\-]*)$`,
				(string user, string component, string base, string tip)
				{
					// Some "do what I mean" logic here: if the user
					// specified a range, or a single commit, cherry-pick;
					// otherwise (just a branch name), do a git merge
					auto branch = d.getBranch(component, user, base, tip);
					auto mode = branch[0] ? DManager.MergeMode.cherryPick : DManager.MergeMode.merge;
					apply(component, branch, mode);
				}))
				continue;

			throw new Exception("Don't know how to apply customization: " ~ spec);
		}

		return state;
	};
}

// /// Build D according to the given spec string
// /// (e.g. master+dmd#123).
// void buildCustom(string spec, bool asNeeded = false)
// {
// 	log("Building spec: " ~ spec);
// 	auto submoduleState = parseSpec(spec);
// 	runBuild(spec, submoduleState, asNeeded);
// }

// void checkout(string spec)
// {
// 	log("Checking out: " ~ spec);
// 	auto submoduleState = parseSpec(spec);
// 	d.checkout(submoduleState);
// 	log("Done.");
// }

// /// Build all D versions (for the purpose of caching them).
// /// Build order is in steps of decreasing powers of two.
// void buildAll(string spec)
// {
// 	d.needUpdate();
// 	auto commits = d.getLog("refs/remotes/origin/" ~ spec);
// 	commits.reverse(); // oldest first

// 	for (int step = 1 << 30; step; step >>= 1)
// 	{
// 		if (step >= commits.length)
// 			continue;

// 		log("Building all revisions with step %d (%d/%d revisions)".format(step, commits.length/step, commits.length));

// 		for (int n = step; n < commits.length; n += step)
// 			try
// 			{
// 				auto state = d.begin(commits[n].hash);
// 				if (!d.isCached(state))
// 				{
// 					log("Building revision %d/%d".format(n/step, commits.length/step));
// 					d.build(state);
// 				}
// 			}
// 			catch (Exception e)
// 				log(e.toString());
// 	}
// }
