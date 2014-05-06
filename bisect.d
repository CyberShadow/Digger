module bisect;

import std.exception;
import std.file;
import std.getopt : getopt;
import std.path;
import std.process;
import std.string;

import ae.sys.d.builder;
import ae.sys.file;
import ae.utils.sini;

import cache;
import common;
import repo;

enum EXIT_UNTESTABLE = 125;

string bisectConfigFile;
struct BisectConfig
{
	string bad, good;
	bool reverse;
	string tester;

	BuildConfig build;

	string[string] environment;
}
BisectConfig bisectConfig;

/// Final build directory for bisect tests.
alias currentDir = subDir!"current";

int doBisect()
{
	bool inBisect, noVerify;

	auto args = opts.args.dup;
	getopt(args,
		"in-bisect", &inBisect,
		"no-verify", &noVerify,
	);

	enforce(args.length >= 2, "Specify bisect.ini");
	enforce(args.length == 2, "Too many arguments");
	bisectConfigFile = args[1];
	bisectConfig = bisectConfigFile
		.readText()
		.splitLines()
		.parseStructuredIni!BisectConfig();

	if (inBisect)
	{
		log("Invoked by git-bisect - performing bisect step.");
		auto result = doBisectStep();
		if (bisectConfig.reverse && result != EXIT_UNTESTABLE)
			result = result ? 0 : 1;
		return result;
	}

	d.initialize(true);

	void test(bool good, string rev)
	{
		auto name = good ? "GOOD" : "BAD";
		log("Sanity-check, testing %s revision %s...".format(name, rev));
		d.repo.run("checkout", rev);
		auto result = doBisectStep();
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

		auto nGood = d.repo.query(["log", "--format=oneline", good]).splitLines().length;
		auto nBad  = d.repo.query(["log", "--format=oneline", bad ]).splitLines().length;
		if (bisectConfig.reverse)
		{
			enforce(nBad < nGood, "Bad commit is newer than good commit (and reverse search is enabled)");
			test(false, bad);
			test(true, good);
		}
		else
		{
			enforce(nGood < nBad, "Good commit is newer than bad commit");
			test(true, good);
			test(false, bad);
		}
	}

	auto startPoints = [getRev!false(), getRev!true()];
	if (bisectConfig.reverse)
		startPoints.reverse;
	d.repo.run(["bisect", "start"] ~ startPoints);
	d.repo.run("bisect", "run",
		thisExePath,
		"--dir", getcwd(),
		"--config-file", opts.configFile,
		"bisect",
		"--in-bisect", bisectConfigFile,
	);

	return 0;
}

int doBisectStep()
{
	d.prepareEnv();

	auto oldEnv = d.dEnv.dup;
	scope(exit) d.dEnv = oldEnv;
	d.applyEnv(bisectConfig.environment);

	try
		prepareBuild(bisectConfig.build);
	catch (Exception e)
	{
		log("Build failed: " ~ e.toString());
		return EXIT_UNTESTABLE;
	}

	auto oldPath = environment["PATH"];
	scope(exit) environment["PATH"] = oldPath;

	// Add the final DMD to the environment PATH
	d.dEnv["PATH"] = buildPath(currentDir, "bin").absolutePath() ~ pathSeparator ~ d.dEnv["PATH"];
	environment["PATH"] = d.dEnv["PATH"];

	d.logProgress("Running test command...");
	auto result = spawnShell(bisectConfig.tester, d.dEnv, Config.newEnv).wait();
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

bool inDelve;

/// Find the earliest revision that Digger can build.
/// Used during development to extend Digger's range.
int doDelve()
{
	bool inBisect;

	auto args = opts.args.dup;
	getopt(args,
		"in-bisect", &inBisect,
	);

	if (inBisect)
	{
		log("Invoked by git-bisect - performing bisect step.");

		import std.conv;
		auto t = d.repo.query("log", "-n1", "--pretty=format:%ct").to!int();
		foreach (r; badCommits)
			if (r.startTime <= t && t < r.endTime)
			{
				log("This revision is known to be unbuildable, skipping.");
				return EXIT_UNTESTABLE;
			}

		inDelve = true;
		try
		{
			prepareBuild(bisectConfig.build);
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
		d.initialize(false);
		auto root = d.repo.query("log", "--pretty=format:%H", "--reverse", "master").splitLines()[0];
		d.repo.run(["bisect", "start", "master", root]);
		d.repo.run("bisect", "run",
			thisExePath,
			"--dir", getcwd(),
			"--config-file", opts.configFile,
			"delve", "--in-bisect",
		);
		return 0;
	}
}

// ---------------------------------------------------------------------------

enum UNBUILDABLE_MARKER = "unbuildable";

void prepareBuild(BuildConfig buildConfig)
{
	auto commit = d.repo.query("rev-parse", "HEAD");
	string currentCacheDir; // this build's cache location

	d.config.build = buildConfig;

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

	d.reset();
	d.build();
}
