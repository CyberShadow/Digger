module cache;

import std.algorithm;
import std.exception;
import std.file;
import std.path;
import std.string;

import ae.sys.file;

import common;
import config;
import repo;

alias cacheDir = subDir!"cache";

/// Run a build process, but only if necessary.
/// Throws an exception if the build was cached as unbuildable.
void cached(string commit, BuildConfig buildConfig, string buildDir, void delegate() buildAction)
{
	assert(commit.length == 40, "Bad commit SHA1");
	string currentCacheDir; // this build's cache location

	if (.config.config.cache)
	{
		currentCacheDir = cacheLocation(commit, buildConfig);
		if (currentCacheDir.exists)
		{
			log("Found in cache: " ~ currentCacheDir);
			currentCacheDir.dirLink(buildDir);
			enforce(!buildPath(buildDir, UNBUILDABLE_MARKER).exists, "This build was cached as unbuildable.");
			return;
		}
		else
			log("Cache miss: " ~ currentCacheDir);
	}
	else
		log("Build caching is not enabled.");

	scope (exit)
	{
		if (currentCacheDir && buildDir.exists)
		{
			log("Saving to cache: " ~ currentCacheDir);
			ensurePathExists(currentCacheDir);
			buildDir.rename(currentCacheDir);
			currentCacheDir.dirLink(buildDir);
			optimizeRevision(commit);
		}
	}

	scope (failure)
	{
		// Don't cache failed build results during delve
		if (inDelve)
			currentCacheDir = null;
	}

	buildAction();
}

bool isCached(string commit, BuildConfig buildConfig)
{
	return .config.config.cache && cacheLocation(commit, buildConfig).exists;
}

string cacheLocation(string commit, BuildConfig buildConfig)
{
	auto buildID = "%s-%s".format(commit, buildConfig);
	return buildPath(cacheDir, buildID);
}

// ---------------------------------------------------------------------------

/// Replace all files that have duplicate subpaths and content 
/// which exist under both dirA and dirB with hard links.
void dedupDirectories(string dirA, string dirB)
{
	foreach (de; dirEntries(dirA, SpanMode.depth))
		if (de.isFile)
		{
			auto pathA = de.name;
			auto subPath = pathA[dirA.length..$];
			auto pathB = dirB ~ subPath;

			if (pathB.exists
			 && pathA.getSize() == pathB.getSize()
			 && pathA.getFileID() != pathB.getFileID()
			 && pathA.mdFileCached() == pathB.mdFileCached())
			{
				debug log(pathB ~ " = " ~ pathA);
				pathB.remove();
				try
					pathA.hardLink(pathB);
				catch (FileException e)
				{
					log(" -- Hard link failed: " ~ e.msg);
					pathA.copy(pathB);
				}
			}
		}
}

private void optimizeCacheImpl(bool reverse = false, string onlyRev = null)
{
	string[] history = d.repo.query("log", "--pretty=format:%H", "origin/master").splitLines();
	if (reverse)
		history.reverse();
	
	string[][string] cacheContent;
	foreach (de; dirEntries(cacheDir, SpanMode.shallow))
		cacheContent[de.baseName()[0..40]] ~= de.name;

	string[string] lastRevisions;

	foreach (rev; history)
	{
		auto cacheEntries = cacheContent.get(rev, null);
		bool optimizeThis = onlyRev is null || onlyRev == rev;
		
		// Optimize with previous revision
		foreach (entry; cacheEntries)
		{
			auto suffix = entry.baseName()[40..$];
			if (optimizeThis && suffix in lastRevisions)
				dedupDirectories(lastRevisions[suffix], entry);
			lastRevisions[suffix] = entry;
		}

		// Optimize with alternate builds of this revision
		if (optimizeThis && cacheEntries.length)
			foreach (i, entry; cacheEntries[0..$-1])
				foreach (entry2; cacheEntries[i+1..$])
					dedupDirectories(entry, entry2);
	}
}

/// Optimize entire cache.
void optimizeCache()
{
	optimizeCacheImpl();
}

/// Optimize specific revision.
void optimizeRevision(string revision)
{
	optimizeCacheImpl(false, revision);
	optimizeCacheImpl(true , revision);
}

private ubyte[16] mdFileCached(string fn)
{
	static ubyte[16][ulong] cache;
	auto id = getFileID(fn);
	auto phash = id in cache;
	if (phash)
		return *phash;
	return cache[id] = mdFile(fn);
}

