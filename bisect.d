module bisect;

import core.thread;

import std.algorithm;
import std.exception;
import std.file;
import std.getopt : getopt;
import std.path;
import std.process;
import std.range;
import std.string;

import ae.sys.file;
import ae.sys.git;
import ae.utils.math;
import ae.utils.sini;

import common;
import config;
import repo;

enum EXIT_UNTESTABLE = 125;

string bisectConfigFile;
struct BisectConfig
{
	string bad, good;
	bool reverse;
	string tester;
	bool bisectBuild;
	bool bisectBuildTest;

	DiggerManager.Config.Build* build;
	DiggerManager.Config.Local* local;

	string[string] environment;
}
BisectConfig bisectConfig;

/// Final build directory for bisect tests.
alias currentDir = subDir!"current";

int doBisect(bool noVerify, string bisectConfigFile, string[] bisectConfigLines)
{
	bisectConfig.build = &d.config.build;
	bisectConfig.local = &d.config.local;
	if (bisectConfigFile)
	{
		log("Loading bisect configuration from " ~ bisectConfigFile);
		bisectConfigFile
			.readText()
			.splitLines()
			.parseIniInto(bisectConfig);
	}
	else
		log("No bisect.ini file specified! Using options from command-line only.");
	bisectConfigLines.parseIniInto(bisectConfig);

	void ensureDefault(ref string var, string which, string def)
	{
		if (!var)
		{
			log("No %s revision specified, assuming '%s'".format(which, def));
			var = def;
		}
	}
	ensureDefault(bisectConfig.bad , "bad" , "master");
	ensureDefault(bisectConfig.good, "good", "@ 1 month ago");

	if (bisectConfig.bisectBuildTest)
	{
		bisectConfig.bisectBuild = true;
		d.config.local.cache = "none";
	}
	if (bisectConfig.bisectBuild)
		enforce(!bisectConfig.tester, "bisectBuild and specifying a test command are mutually exclusive");
	enforce(bisectConfig.tester || bisectConfig.bisectBuild, "No tester specified (and bisectBuild is false)");

	auto repo = &d.getMetaRepo().git();

	d.needUpdate();

	void test(bool good, string rev)
	{
		auto name = good ? "GOOD" : "BAD";
		log("Sanity-check, testing %s revision %s...".format(name, rev));
		auto result = doBisectStep(rev);
		enforce(result != EXIT_UNTESTABLE,
			"%s revision %s is not testable"
			.format(name, rev));
		enforce(!result == good,
			"%s revision %s is not correct (exit status is %d)"
			.format(name, rev, result));
	}

	if (!noVerify)
	{
		auto good = getRev!true();
		auto bad = getRev!false();

		enforce(good != bad, "Good and bad revisions are both " ~ bad);

		auto commonAncestor = repo.query("merge-base", good, bad);
		if (bisectConfig.reverse)
		{
			enforce(good != commonAncestor, "Bad commit is newer than good commit (and reverse search is enabled)");
			test(false, bad);
			test(true, good);
		}
		else
		{
			enforce(bad  != commonAncestor, "Good commit is newer than bad commit");
			test(true, good);
			test(false, bad);
		}
	}

	auto p0 = getRev!true();  // good
	auto p1 = getRev!false(); // bad
	if (bisectConfig.reverse)
		swap(p0, p1);

	auto cacheState = d.getCacheState([p0, p1]);
	bool[string] untestable;

	bisectLoop:
	while (true)
	{
		log("Finding shortest path between %s and %s...".format(p0, p1));
		auto fullPath = repo.pathBetween(p0, p1); // closed interval
		enforce(fullPath.length >= 2 && fullPath[0].commit == p0 && fullPath[$-1].commit == p1,
			"Bad path calculation result");
		auto path = fullPath[1..$-1].map!(step => step.commit).array; // open interval
		log("%d commits (about %d tests) remaining.".format(path.length, ilog2(path.length+1)));

		if (!path.length)
		{
			assert(fullPath.length == 2);
			auto p = fullPath[1].downwards ? p0 : p1;
			log("%s is the first %s commit".format(p, bisectConfig.reverse ? "good" : "bad"));
			repo.run("--no-pager", "show", p);
			log("Bisection completed successfully.");
			return 0;
		}

		log("(%d total, %d cached, %d untestable)".format(
			path.length,
			path.filter!(commit => cacheState.get(commit, false)).walkLength,
			path.filter!(commit => commit in untestable).walkLength,
		));

		// First try all cached commits in the range (middle-most first).
		// Afterwards, do a binary-log search across the commit range for a testable commit.
		auto order = chain(
			path.radial     .filter!(commit =>  cacheState.get(commit, false)),
			path.binaryOrder.filter!(commit => !cacheState.get(commit, false))
		).filter!(commit => commit !in untestable).array;

		foreach (i, p; order)
		{
			auto result = doBisectStep(p);
			if (result == EXIT_UNTESTABLE)
			{
				log("Commit %s (%d/%d) is untestable.".format(p, i+1, order.length));
				untestable[p] = true;
				continue;
			}

			if (bisectConfig.reverse)
				result = result ? 0 : 1;

			if (result == 0) // good
				p0 = p;
			else
				p1 = p;

			continue bisectLoop;
		}

		log("There are only untestable commits left to bisect.");
		log("The first %s commit could be any of:".format(bisectConfig.reverse ? "good" : "bad"));
		foreach (p; path ~ [p1])
			repo.run("log", "-1", "--pretty=format:%h %ci: %s", p);
		log("We cannot bisect more!");
		return 2;
	}

	assert(false);
}

struct BisectStep
{
	string commit;
	bool downwards; // on the way to the common ancestor
}

BisectStep[] pathBetween(in Repository* repo, string p0, string p1)
{
	auto commonAncestor = repo.query("merge-base", p0, p1);
	return chain(
		repo.commitsBetween(commonAncestor, p0).retro.map!(commit => BisectStep(commit, true )),
		commonAncestor.only                          .map!(commit => BisectStep(commit, true )),
		repo.commitsBetween(commonAncestor, p1)      .map!(commit => BisectStep(commit, false)),
	).array;
}

string[] commitsBetween(in Repository* repo, string p0, string p1)
{
	return repo.query("log", "--reverse", "--pretty=format:%H", p0 ~ ".." ~ p1).splitLines();
}

/// Reorders [1, 2, ..., 98, 99]
/// into [50, 25, 75, 13, 38, 63, 88, ...]
T[] binaryOrder(T)(T[] items)
{
	auto n = items.length;
	assert(n);
	auto seen = new bool[n];
	auto result = new T[n];
	size_t c = 0;

	foreach (p; 0..30)
		foreach (i; 0..1<<p)
		{
			auto x = cast(size_t)(n/(2<<p) + ulong(n+1)*i/(1<<p));
			if (x >= n || seen[x])
				continue;
			seen[x] = true;
			result[c++] = items[x];
			if (c == n)
				return result;
		}
	assert(false);
}

unittest
{
	assert(iota(1, 7+1).array.binaryOrder.equal([4, 2, 6, 1, 3, 5, 7]));
	assert(iota(1, 100).array.binaryOrder.startsWith([50, 25, 75, 13, 38, 63, 88]));
}

int doBisectStep(string rev)
{
	log("Testing revision: " ~ rev);

	try
	{
		if (currentDir.exists)
		{
			version (Windows)
			{
				try
					currentDir.rmdirRecurse();
				catch (Exception e)
				{
					log("Failed to clean up %s: %s".format(currentDir, e.msg));
					Thread.sleep(500.msecs);
					log("Retrying...");
					currentDir.rmdirRecurse();
				}
			}
			else
				currentDir.rmdirRecurse();
		}

		auto state = d.begin(rev);

		scope (exit)
			if (d.buildDir.exists)
				rename(d.buildDir, currentDir);

		d.build(state);
	}
	catch (Exception e)
	{
		log("Build failed: " ~ e.toString());
		if (bisectConfig.bisectBuild && !bisectConfig.bisectBuildTest)
			return 1;
		return EXIT_UNTESTABLE;
	}

	if (bisectConfig.bisectBuild)
	{
		log("Build successful.");

		if (bisectConfig.bisectBuildTest)
		{
			try
				d.test();
			catch (Exception e)
			{
				log("Tests failed: " ~ e.toString());
				return 1;
			}
			log("Tests successful.");
		}

		return 0;
	}

	string[string] env = d.getBaseEnvironment();
	d.applyEnv(env, bisectConfig.environment);

	auto oldPath = environment["PATH"];
	scope(exit) environment["PATH"] = oldPath;

	// Add the final DMD to the environment PATH
	env["PATH"] = buildPath(currentDir, "bin").absolutePath() ~ pathSeparator ~ env["PATH"];
	environment["PATH"] = env["PATH"];

	// Use host HOME for the test command
	env["HOME"] = environment.get("HOME");

	// For bisecting bootstrapping issues - allows passing the revision to another Digger instance
	env["DIGGER_REVISION"] = rev;

	d.logProgress("Running test command...");
	auto result = spawnShell(bisectConfig.tester, env, Config.newEnv).wait();
	d.logProgress("Test command exited with status %s (%s).".format(result, result==0 ? "GOOD" : result==EXIT_UNTESTABLE ? "UNTESTABLE" : "BAD"));
	return result;
}

/// Returns SHA-1 of the initial search points.
string getRev(bool good)()
{
	static string result;
	if (!result)
	{
		auto rev = good ? bisectConfig.good : bisectConfig.bad;
		result = parseRev(rev);
		log("Resolved %s revision `%s` to %s.".format(good ? "GOOD" : "BAD", rev, result));
	}
	return result;
}

struct CommitRange
{
	uint startTime; /// first bad commit
	uint endTime;   /// first good commit
}
/// Known unbuildable time ranges
const CommitRange[] badCommits =
[
	{ 1342243766, 1342259226 }, // Messed up DMD make files
	{ 1317625155, 1319346272 }, // Missing std.stdio import in std.regex
];

/// Find the earliest revision that Digger can build.
/// Used during development to extend Digger's range.
int doDelve(bool inBisect)
{
	if (inBisect)
	{
		log("Invoked by git-bisect - performing bisect step.");

		import std.conv;
		auto rev = d.getMetaRepo().getRef("BISECT_HEAD");
		auto t = d.getMetaRepo().git.query("log", "-n1", "--pretty=format:%ct", rev).to!int();
		foreach (r; badCommits)
			if (r.startTime <= t && t < r.endTime)
			{
				log("This revision is known to be unbuildable, skipping.");
				return EXIT_UNTESTABLE;
			}

		d.cacheFailures = false;
		//d.config.build = bisectConfig.build; // TODO
		auto state = d.begin(rev);
		try
		{
			d.build(state);
			return 1;
		}
		catch (Exception e)
		{
			log("Build failed: " ~ e.toString());
			return 0;
		}
	}
	else
	{
		auto root = d.getMetaRepo().git.query("log", "--pretty=format:%H", "--reverse", "master").splitLines()[0];
		d.getMetaRepo().git.run(["bisect", "start", "--no-checkout", "master", root]);
		d.getMetaRepo().git.run("bisect", "run",
			thisExePath,
			"--dir", getcwd(),
			"--config-file", opts.configFile,
			"delve", "--in-bisect",
		);
		return 0;
	}
}
