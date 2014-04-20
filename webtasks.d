module webtasks;

import std.algorithm;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.regex;
import std.string;

import build;
import common;
import repo;

void initialize()
{
	if (!repoDir.exists)
		log("First run detected.\nPlease be patient, " ~
			"cloning everything might take a few minutes...\n");

	log("Preparing repository...");
	prepareRepo(true);
	auto repo = Repository(repoDir);

	log("Preparing component repositories...");
	foreach (component; listComponents().parallel)
	{
		auto crepo = Repository(buildPath(repoDir, component));

		log(component ~ ": Resetting repository...");
		crepo.run("reset", "--hard");

		log(component ~ ": Cleaning up...");
		crepo.run("clean", "--force", "-x", "-d", "--quiet");

		log(component ~ ": Fetching pull requests...");
		crepo.run("fetch", "origin", "+refs/pull/*/head:refs/remotes/origin/pr/*");

		log(component ~ ": Creating work branch...");
		crepo.run("checkout", "-B", "custom", "origin/master");
	}

	log("Preparing tools...");
	prepareTools();

	clean();

	log("Ready.");
}

const mergeCommitMessage = "digger-pr-%s-merge";

void merge(string component, string pull)
{
	enforce(component.match(`^[a-z]+$`), "Bad component");
	enforce(pull.match(`^\d+$`), "Bad pull number");

	auto repo = Repository(buildPath(repoDir, component));

	scope(failure)
	{
		log("Aborting merge...");
		repo.run("merge", "--abort");
	}

	log("Merging...");

	void doMerge()
	{
		repo.run("merge", "--no-ff", "-m", mergeCommitMessage.format(pull), "origin/pr/" ~ pull);
	}

	if (component == "dmd")
	{
		try
			doMerge();
		catch (Exception)
		{
			log("Merge failed. Attempting conflict resolution...");
			repo.run("checkout", "--theirs", "test");
			repo.run("add", "test");
			repo.run("-c", "rerere.enabled=false", "commit", "-m", mergeCommitMessage.format(pull));
		}
	}
	else
		doMerge();

	log("Merge successful.");
}

void unmerge(string component, string pull)
{
	enforce(component.match(`^[a-z]+$`), "Bad component");
	enforce(pull.match(`^\d+$`), "Bad pull number");

	auto repo = Repository(buildPath(repoDir, component));

	log("Rebasing...");
	environment["GIT_EDITOR"] = "%s unmerge-rebase-edit %s".format(escapeShellFileName(thisExePath), pull);
	// "sed -i \"s#.*" ~ mergeCommitMessage.format(pull).escapeRE() ~ ".*##g\"";
	repo.run("rebase", "--interactive", "--preserve-merges", "origin/master");

	log("Unmerge successful.");
}

void unmergeRebaseEdit(string pull, string fileName)
{
	auto lines = fileName.readText().splitLines();

	bool removing, remaining;
	foreach_reverse (ref line; lines)
		if (line.startsWith("pick "))
		{
			if (line.match(`^pick [0-9a-f]+ ` ~ mergeCommitMessage.format(`\d+`) ~ `$`))
				removing = line.canFind(mergeCommitMessage.format(pull));
			if (removing)
				line = "# " ~ line;
			else
				remaining = true;
		}
	if (!remaining)
		lines = ["noop"];

	std.file.write(fileName, lines.join("\n"));
}

alias resultDir = subDir!"result";

void runBuild()
{
	log("Preparing build...");
	prepareEnv();
	prepareBuilder();

	log("Building...");
	builder.build();

	log("Moving...");
	if (resultDir.exists)
		resultDir.rmdirRecurse();
	rename(buildDir, resultDir);

	log("Build successful.\n\nAdd %s to your PATH to start using it.".format(
		resultDir.buildPath("bin").absolutePath()
	));
}
