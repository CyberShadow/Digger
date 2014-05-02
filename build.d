module build;

import std.algorithm;
import std.array;
import std.datetime;
import std.exception;
import std.file;
import std.path;
import std.process : environment;
import std.string;

import ae.sys.file;
import ae.sys.d.builder;

import cache;
import common;
import repo;

alias BuildConfig = DBuilder.Config.Build;
BuildConfig buildConfig;
bool inDelve;

enum UNBUILDABLE_MARKER = "unbuildable";

alias currentDir = subDir!"current";     /// Final build directory.

void prepareBuild()
{
	auto commit = d.repo.query("rev-parse", "HEAD");
	string currentCacheDir; // this build's cache location

	d.config.build = buildConfig;

	d.prepareEnv();
	d.prepareBuilder();

	if (currentDir.exists)
		currentDir.rmdirRecurse();

	if (config.cache)
	{
		auto buildID = "%s-%s".format(commit, buildConfig);

		currentCacheDir = buildPath(cacheDir, buildID);
		if (currentCacheDir.exists)
		{
			log("Found in cache: " ~ currentCacheDir);
			currentCacheDir.dirLink(currentDir);
			enforce(!buildPath(currentDir, UNBUILDABLE_MARKER).exists, "This build was cached as unbuildable.");
			return;
		}
	}

	scope (exit)
	{
		if (d.buildDir.exists)
		{
			if (currentCacheDir)
			{
				ensurePathExists(currentCacheDir);
				d.buildDir.rename(currentCacheDir);
				currentCacheDir.dirLink(currentDir);
				optimizeRevision(commit);
			}
			else
				rename(d.buildDir, currentDir);
		}
	}

	scope (failure)
	{
		if (d.buildDir.exists)
		{
			// An incomplete build is useless, nuke the directory
			// and create a new one just for the UNBUILDABLE_MARKER.
			rmdirRecurse(d.buildDir);
			mkdir(d.buildDir);
			buildPath(d.buildDir, UNBUILDABLE_MARKER).touch();

			// Don't cache failed build results during delve
			if (inDelve)
				currentCacheDir = null;
		}
	}

	d.build();
}
