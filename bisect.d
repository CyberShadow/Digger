module bisect;

import std.exception;
import std.file;
import std.getopt : getopt;
import std.process;
import std.string;

import ae.utils.sini;

import build;
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

int doBisect()
{
	bool inBisect;

	auto args = opts.args.dup;
	getopt(args,
		"in-bisect", &inBisect,
	);

	enforce(args.length >= 2, "Specify bisect.ini");
	enforce(args.length == 2, "Too many arguments");
	bisectConfigFile = args[1];
	bisectConfig = bisectConfigFile
		.readText()
		.splitLines()
		.parseStructuredIni!BisectConfig();
	buildConfig = bisectConfig.build;

	if (inBisect)
	{
		log("Invoked by git-bisect - performing bisect step.");
		auto result = doBisectStep();
		if (bisectConfig.reverse && result != EXIT_UNTESTABLE)
			result = result ? 0 : 1;
		return result;
	}

	prepareRepo(true);
	prepareTools();

	auto repo = Repository(repoDir);

	void test(bool good, string rev)
	{
		auto name = good ? "GOOD" : "BAD";
		log("Sanity-check, testing %s revision %s...".format(name, rev));
		repo.run("checkout", rev);
		auto result = doBisectStep();
		enforce(result != EXIT_UNTESTABLE,
			"%s revision %s is not testable"
			.format(name, rev));
		enforce(!result == good,
			"%s revision %s is not correct (exit status is %d)"
			.format(name, rev, result));
	}

	if (!opts.noVerify)
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
		startPoints.reverse;
	repo.run(["bisect", "start"] ~ startPoints);
	repo.run("bisect", "run",
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
	auto oldEnv = dEnv.dup;
	scope(exit) dEnv = oldEnv;
	applyEnv(bisectConfig.environment);

	if (!prepareBuild())
		return EXIT_UNTESTABLE;

	logProgress("Running test command...");
	auto result = spawnShell(bisectConfig.tester, dEnv, Config.newEnv).wait();
	logProgress("Test command exited with status %s (%s).".format(result, result==0 ? "GOOD" : result==EXIT_UNTESTABLE ? "UNTESTABLE" : "BAD"));
	return result;
}

/// Returns SHA-1 of the initial search points.
string getRev(bool good)()
{
	static string result;
	if (!result)
		result = parseRev(good ? bisectConfig.good : bisectConfig.bad);
	return result;
}

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
		inDelve = true;
		auto success = prepareBuild();
		return success ? 1 : 0;
	}
	else
	{
		prepareRepo(false);
		auto repo = Repository(repoDir);
		auto root = repo.query("log", "--pretty=format:%H", "--reverse", "master").splitLines()[0];
		repo.run(["bisect", "start", "master", root]);
		repo.run("bisect", "run",
			thisExePath,
			"--dir", getcwd(),
			"--config-file", opts.configFile,
			"delve", "--in-bisect",
		);
		return 0;
	}
}
