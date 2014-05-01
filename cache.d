module cache;

import std.file;
import std.path;
import std.string;

import ae.sys.file;

import common;
import repo;

alias cacheDir = subDir!"cache";

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
				pathA.hardLink(pathB);
			}
		}
}

private void optimizeCacheImpl(bool reverse = false, string onlyRev = null)
{
	string[] history = d.repo.query("log", "--pretty=format:%H", "origin/master").splitLines();
	if (reverse)
		history.reverse;
	
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

