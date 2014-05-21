module repo;

import std.algorithm;
import std.exception;
import std.file;
import std.parallelism : parallel;
import std.path;
import std.process;
import std.range;
import std.regex;
import std.string;

import ae.sys.file;
import ae.sys.d.builder;
import ae.sys.d.manager;

import cache;
import common;

alias BuildConfig = DBuilder.Config.Build;

final class DiggerManager : DManager
{
	this()
	{
		this.config.workDir = common.config.workDir;
	}

	override void log(string s)
	{
		common.log(s);
	}

	override void prepareEnv()
	{
		super.prepareEnv();

		applyEnv(common.config.environment);
	}

	void applyEnv(in string[string] env)
	{
		auto oldEnv = environment.toAA();
		foreach (name, value; dEnv)
			oldEnv[name] = value;
		foreach (name, value; env)
		{
			string newValue = value;
			foreach (oldName, oldValue; oldEnv)
				newValue = newValue.replace("%" ~ oldName ~ "%", oldValue);
			dEnv[name] = oldEnv[name] = newValue;
		}
	}

	enum UNBUILDABLE_MARKER = "unbuildable";
	bool inDelve;

	/// This override adds caching.
	override void build()
	{
		auto commit = d.repo.query("rev-parse", "HEAD");
		string currentCacheDir; // this build's cache location

		if (common.config.cache)
		{
			auto buildID = "%s-%s".format(commit, config.build);

			currentCacheDir = buildPath(cacheDir, buildID);
			if (currentCacheDir.exists)
			{
				log("Found in cache: " ~ currentCacheDir);
				currentCacheDir.dirLink(buildDir);
				enforce(!buildPath(buildDir, UNBUILDABLE_MARKER).exists, "This build was cached as unbuildable.");
				return;
			}
		}

		scope (exit)
		{
			if (currentCacheDir && buildDir.exists)
			{
				ensurePathExists(currentCacheDir);
				buildDir.rename(currentCacheDir);
				currentCacheDir.dirLink(buildDir);
				optimizeRevision(commit);
			}
		}

		scope (failure)
		{
			if (buildDir.exists)
			{
				// An incomplete build is useless, nuke the directory
				// and create a new one just for the UNBUILDABLE_MARKER.
				rmdirRecurse(buildDir);
				mkdir(buildDir);
				buildPath(buildDir, UNBUILDABLE_MARKER).touch();

				// Don't cache failed build results during delve
				if (inDelve)
					currentCacheDir = null;
			}
		}

		super.build();
	}
}

DiggerManager d;

static this()
{
	d = new DiggerManager();
}

string parseRev(string rev)
{
	auto args = ["log", "--pretty=format:%H"];

	// git's approxidate accepts anything, so a disambiguating prefix is required
	if (rev.canFind('@'))
	{
		auto parts = rev.findSplit("@");
		args ~= ["--until", parts[2].strip()];
		rev = parts[0].strip();
	}

	if (rev.empty)
		rev = "origin/master";

	try
		return d.repo.query(args ~ ["-n", "1", "origin/" ~ rev]);
	catch (Exception e)
	try
		return d.repo.query(args ~ ["-n", "1", rev]);
	catch (Exception e)
		{}

	auto grep = d.repo.query("log", "-n", "2", "--pretty=format:%H", "--grep", rev, "origin/master").splitLines();
	if (grep.length == 1)
		return grep[0];

	auto pickaxe = d.repo.query("log", "-n", "3", "--pretty=format:%H", "-S" ~ rev, "origin/master").splitLines();
	if (pickaxe.length && pickaxe.length <= 2) // removed <- added
		return pickaxe[$-1];   // the one where it was added

	throw new Exception("Unknown/ambiguous revision: " ~ rev);
}
