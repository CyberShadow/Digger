module bisect;

import std.algorithm;
import std.exception;
import std.file;
import std.getopt : getopt;
import std.path;
import std.process;
import std.string;

import ae.sys.file;
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

	BuildConfig build;

	string[string] environment;
}
BisectConfig bisectConfig;

/// Final build directory for bisect tests.
alias currentDir = subDir!"current";

int doBisect(bool inBisect, bool noVerify, string bisectConfigFile)
{
	bisectConfig = bisectConfigFile
		.readText()
		.splitLines()
		.parseStructuredIni!BisectConfig();

	d.getMetaRepo().needRepo();
	auto repo = &d.getMetaRepo().git;

	if (inBisect)
	{
		log("Invoked by git-bisect - performing bisect step.");
		auto result = doBisectStep(d.getMetaRepo().getRef("BISECT_HEAD"));
		if (bisectConfig.reverse && result != EXIT_UNTESTABLE)
			result = result ? 0 : 1;
		return result;
	}

	d.update();

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

		auto nGood = repo.query(["log", "--format=oneline", good]).splitLines().length;
		auto nBad  = repo.query(["log", "--format=oneline", bad ]).splitLines().length;
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
		startPoints.reverse();
	repo.run(["bisect", "start", "--no-checkout"] ~ startPoints);
	repo.run("bisect", "run",
		thisExePath,
		"--dir", getcwd(),
		"--config-file", opts.configFile,
		"bisect",
		"--in-bisect", bisectConfigFile,
	);

	return 0;
}

int doBisectStep(string rev)
{
	log("Testing revision: " ~ rev);

	try
	{
		if (currentDir.exists)
			currentDir.rmdirRecurse();

		auto state = d.begin(rev);

		scope (exit)
			if (d.buildDir.exists)
				rename(d.buildDir, currentDir);

		d.build(state, bisectConfig.build);
	}
	catch (Exception e)
	{
		log("Build failed: " ~ e.toString());
		return EXIT_UNTESTABLE;
	}

	d.applyEnv(bisectConfig.environment);

	auto oldPath = environment["PATH"];
	scope(exit) environment["PATH"] = oldPath;

	// Add the final DMD to the environment PATH
	d.config.env["PATH"] = buildPath(currentDir, "bin").absolutePath() ~ pathSeparator ~ d.config.env["PATH"];
	environment["PATH"] = d.config.env["PATH"];

	d.logProgress("Running test command...");
	auto result = spawnShell(bisectConfig.tester, d.config.env, Config.newEnv).wait();
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
		d.getMetaRepo().needRepo();
		auto rev = d.getMetaRepo().getRef("BISECT_HEAD");
		auto t = d.getMetaRepo().git.query("log", "-n1", "--pretty=format:%ct", rev).to!int();
		foreach (r; badCommits)
			if (r.startTime <= t && t < r.endTime)
			{
				log("This revision is known to be unbuildable, skipping.");
				return EXIT_UNTESTABLE;
			}

		d.config.cacheFailures = false;
		auto state = d.begin(rev);
		try
		{
			d.build(state, bisectConfig.build);
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
		d.getMetaRepo.needRepo();
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
