/**
 * Code to manage a D component repository.
 */

module digger.build.repo;

import std.algorithm;
import std.conv : text;
import std.datetime : SysTime;
import std.exception;
import std.file;
import std.process : environment;
import std.range;
import std.regex;
import std.string;
import std.path;

import ae.sys.git;
import ae.utils.exception;
import ae.utils.json;
import ae.utils.regex;
import ae.utils.time : StdTime;

/// Base class for a managed repository.
class ManagedRepository
{
private:
	// --- Subclass interface

	/// Repository provider
	protected abstract Git getRepo();

	/// Override to add logging.
	protected abstract void log(string line);

	/// Optional callbacks which shall attempt to resolve a merge conflict.
	protected alias MergeConflictResolver = void delegate(ref Git git);
	protected MergeConflictResolver[] getMergeConflictResolvers() { return null; } /// ditto

final:
	/// Git repository we manage.
	public @property ref const(Git) git()
	{
		if (!gitRepo.path)
		{
			gitRepo = getRepo();
			assert(gitRepo.path, "No repository");
			foreach (person; ["AUTHOR", "COMMITTER"])
			{
				gitRepo.environment["GIT_%s_DATE".format(person)] = "Thu, 01 Jan 1970 00:00:00 +0000";
				gitRepo.environment["GIT_%s_NAME".format(person)] = "digger.build";
				gitRepo.environment["GIT_%s_EMAIL".format(person)] = "digger.build\x40cy.md";
			}
		}
		return gitRepo;
	}

	/// Should we fetch the latest stuff?
	public bool offline;

	private Git gitRepo;

	private Git.ObjectReader reader;
	private Git.ObjectMultiWriter writer;

	private ref Git.ObjectReader needReader()
	{
		if (reader is Git.ObjectReader.init) reader = git.createObjectReader();
		return reader;
	}

	private ref Git.ObjectMultiWriter needWriter()
	{
		if (writer is Git.ObjectMultiWriter.init) writer = git.createObjectWriter();
		return writer;
	}

	/// Base name of the repository directory
	public @property string name() { return git.path.baseName; }

	// --- Head

	private bool haveCommit(string hash)
	{
		try
			enforce(needReader().read(hash).type == "commit", "Wrong object type");
		catch (Git.ObjectMissingException e)
			return false;
		return true;
	}

	void exportCommit(string hash, string targetPath)
	{
		if (!haveCommit(hash) && mergeCache.find!(entry => entry.result == hash)())
		{
			// Might be a GC-ed merge. Try to recreate the merge
			auto hit = mergeCache.find!(entry => entry.result == hash)();
			enforce(!hit.empty, "Unknown hash %s".format(hash));
			auto mergeResult = performMerge(hit.front.spec);
			enforce(mergeResult == hash, "Unexpected merge result: expected %s, got %s".format(hash, mergeResult));
		}

		git.exportCommit(hash, targetPath, needReader());
	}

	/// Returns the commit OID of the given named ref.
	public string getRef(string name)
	{
		return git.query("rev-parse", "--verify", "--quiet", name);
	}

	/// Ensure that the specified commit is fetched.
	protected void needCommit(string hash)
	{
		void check()
		{
			enforce(git.query(["cat-file", "-t", hash]) == "commit",
				"Unexpected object type");
		}

		try
			check();
		catch (Exception e)
		{
			if (offline)
			{
				log("Don't have commit " ~ hash ~ " and in offline mode, can't proceed.");
				throw new Exception("Giving up");
			}
			else
			{
				log("Don't have commit " ~ hash ~ ", updating and retrying...");
				update();
				check();
			}
		}
	}

	/// Update the remote.
	/// Return true if any updates were fetched.
	public bool update()
	{
		if (!offline)
		{
			log("Updating " ~ name ~ "...");
			auto oldRefs = git.query(["show-ref"]);
			git.run("-c", "fetch.recurseSubmodules=false", "remote", "update", "--prune");
			git.run("-c", "fetch.recurseSubmodules=false", "fetch", "--force", "--tags");
			auto newRefs = git.query(["show-ref"]);
			return oldRefs != newRefs;
		}
		else
			return false;
	}

	// --- Merge cache

	/// Represents a series of commits as a start and end point in the repository history.
	struct CommitRange
	{
		/// The commit before the first commit in the range.
		/// May be null in some circumstances.
		string base;
		/// The last commit in the range.
		string tip;
	}

	/// How to merge a branch into another
	public enum MergeMode
	{
		merge,      /// git merge (commit with multiple parents) of the target and branch tips
		cherryPick, /// apply the commits as a patch
	}
	private static struct MergeSpec
	{
		string target;
		CommitRange branch;
		MergeMode mode;
		bool revert = false;
	}
	private static struct MergeInfo
	{
		MergeSpec spec;
		string result;
		int mainline = 0; // git parent index of the "target", if any
	}
	private alias MergeCache = MergeInfo[];
	private MergeCache mergeCacheData;
	private bool haveMergeCache;

	private @property ref MergeCache mergeCache()
	{
		if (!haveMergeCache)
		{
			if (mergeCachePath.exists)
				mergeCacheData = mergeCachePath.readText().jsonParse!MergeCache;
			haveMergeCache = true;
		}

		return mergeCacheData;
	}

	private void saveMergeCache()
	{
		std.file.write(mergeCachePath(), toJson(mergeCache));
	}

	private @property string mergeCachePath()
	{
		return buildPath(git.gitDir, "ae-sys-d-mergecache-v2.json");
	}

	// --- Merge

	/// Returns the hash of the merge between the target and branch commits.
	/// Performs the merge if necessary. Caches the result.
	public string getMerge(string target, CommitRange branch, MergeMode mode)
	{
		return getMergeImpl(MergeSpec(target, branch, mode, false));
	}

	/// Returns the resulting hash when reverting the branch from the base commit.
	/// Performs the revert if necessary. Caches the result.
	/// mainline is the 1-based mainline index (as per `man git-revert`),
	/// or 0 if commit is not a merge commit.
	public string getRevert(string target, CommitRange branch, MergeMode mode)
	{
		return getMergeImpl(MergeSpec(target, branch, mode, true));
	}

	private string getMergeImpl(MergeSpec spec)
	{
		auto hit = mergeCache.find!(entry => entry.spec == spec)();
		if (!hit.empty)
			return hit.front.result;

		auto mergeResult = performMerge(spec);

		mergeCache ~= MergeInfo(spec, mergeResult);
		saveMergeCache();
		return mergeResult;
	}

	private static const string mergeCommitMessage = "digger.build merge";
	private static const string revertCommitMessage = "digger.build revert";

	/// Performs a merge or revert.
	private string performMerge(MergeSpec spec)
	{
		import ae.sys.cmd : getTempFileName;
		import ae.sys.file : removeRecurse;

		log("%s %s into %s.".format(spec.revert ? "Reverting" : "Merging", spec.branch, spec.target));

		auto conflictResolvers = getMergeConflictResolvers();
		if (!conflictResolvers.length)
			conflictResolvers = [null];
		foreach (conflictResolverIndex, conflictResolver; conflictResolvers)
		{
			auto tmpRepoPath = getTempFileName("digger");
			tmpRepoPath.mkdir();
			scope(exit) tmpRepoPath.removeRecurse();

			auto tmpRepo = Git(tmpRepoPath);
			tmpRepo.commandPrefix = git.commandPrefix.replace(git.path, tmpRepoPath).dup;
			tmpRepo.run("init", "--quiet");

			// Ensures `hash` is pulled in to the temporary work repo.
			string needCommit(string hash)
			{
				tmpRepo.run(["fetch", "--quiet", git.path.absolutePath, hash]);
				return hash;
			}

			tmpRepo.run("checkout", "--quiet", needCommit(spec.target));

			void doMerge()
			{
				final switch (spec.mode)
				{
					case MergeMode.merge:
						if (!spec.revert)
							tmpRepo.run("merge", "--quiet", "--no-ff", "-m", mergeCommitMessage, needCommit(spec.branch.tip));
						else
						{
							// When reverting in merge mode, we try to
							// find the merge commit following the branch
							// tip, and revert only that merge commit.
							string mergeCommit; int mainline;
							getChild(spec.target, spec.branch.tip, /*out*/mergeCommit, /*out*/mainline);

							string[] args = ["revert", "--no-edit"];
							if (mainline)
								args ~= ["--mainline", text(mainline)];
							args ~= [needCommit(mergeCommit)];
							tmpRepo.run(args);
						}
						break;

					case MergeMode.cherryPick:
						enforce(spec.branch.base, "Must specify a branch base for a cherry-pick merge");
						auto range = needCommit(spec.branch.base) ~ ".." ~ needCommit(spec.branch.tip);
						if (!spec.revert)
							tmpRepo.run("cherry-pick", range);
						else
							tmpRepo.run("revert", "--no-edit", range);
						break;
				}
			}

			void doMergeAndResolve()
			{
				if (conflictResolver)
					try
						doMerge();
					catch (Exception e)
					{
						log("Merge failed. Attempting conflict resolution...");
						conflictResolver(tmpRepo);
						if (!spec.revert)
							tmpRepo.run("-c", "rerere.enabled=false", "commit", "-m", mergeCommitMessage);
						else
							tmpRepo.run("revert", "--continue");
					}
				else
					doMerge();
			}

			if (conflictResolverIndex + 1 < conflictResolvers.length)
				try
					doMergeAndResolve();
				catch (Exception e)
				{
					log("Merge and conflict resolution failed. Trying next conflict resolver...");
					continue;
				}
			else
				doMergeAndResolve();

			auto hash = tmpRepo.query("rev-parse", "HEAD");
			log("Merge successful: " ~ hash);
			git.run(["fetch", "--quiet", tmpRepo.path.absolutePath, hash]);
			return hash;
		}

		assert(false, "Unreachable");
	}

	/// Finds and returns the merge parents of the given merge commit.
	/// Queries the git repository if necessary. Caches the result.
	public MergeInfo getMergeInfo(string merge)
	{
		auto hit = mergeCache.find!(entry => entry.result == merge && !entry.spec.revert)();
		if (!hit.empty)
			return hit.front;

		auto parents = git.query(["log", "--pretty=%P", "-n", "1", merge]).split();
		enforce(parents.length > 1, "Not a merge: " ~ merge);
		enforce(parents.length == 2, "Too many parents: " ~ merge);

		auto info = MergeInfo(MergeSpec(parents[0], CommitRange(null, parents[1]), MergeMode.merge, false), merge, 1);
		mergeCache ~= info;
		return info;
	}

	/// Follows the string of merges starting from the given
	/// head commit, up till the merge with the given branch.
	/// Then, reapplies all merges in order,
	/// except for that with the given branch.
	public string getUnMerge(string head, CommitRange branch, MergeMode mode)
	{
		// This could be optimized using an interactive rebase

		auto info = getMergeInfo(head);
		if (info.spec.branch.tip == branch.tip)
			return info.spec.target;

		// Recurse to keep looking
		auto unmerge = getUnMerge(info.spec.target, branch, mode);
		// Re-apply this non-matching merge
		return getMerge(unmerge, info.spec.branch, info.spec.mode);
	}

	// --- Branches, forks and customization

	/// Return SHA1 of the given remote ref.
	/// Fetches the remote first, unless offline mode is on.
	string getRemoteRef(string remote, string remoteRef, string localRef)
	{
		if (!offline)
		{
			log("Fetching from %s (%s -> %s) ...".format(remote, remoteRef, localRef));
			git.run("fetch", remote, "+%s:%s".format(remoteRef, localRef));
		}
		return getRef(localRef);
	}

	/// Return SHA1 of the given pull request #.
	/// Fetches the pull request first, unless offline mode is on.
	string getPullTip(int pull)
	{
		return getRemoteRef(
			"origin",
			"refs/pull/%d/head".format(pull),
			"refs/digger/pull/%d".format(pull),
		);
	}

	private static bool isCommitHash(string s)
	{
		return s.length == 40 && s.representation.all!(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'));
	}

	/// Return SHA1 (base, tip) of the given branch (possibly of GitHub fork).
	/// Fetches the fork first, unless offline mode is on.
	/// (This is a thin wrapper around getRemoteRef.)
	string[2] getBranch(string user, string base, string tip)
	{
		if (user) enforce(user.match(re!`^\w[\w\-]*$`), "Bad remote name");
		if (base) enforce(base.match(re!`^\w[\w\-\.]*$`), "Bad branch base name");
		if (true) enforce(tip .match(re!`^\w[\w\-\.]*$`), "Bad branch tip name");

		if (!user)
			user = "dlang";

		if (isCommitHash(tip))
		{
			if (!offline)
			{
				// We don't know which branch the commit will be in, so just grab everything.
				auto remote = "https://github.com/%s/%s".format(user, name);
				log("Fetching everything from %s ...".format(remote));
				git.run("fetch", remote, "+refs/heads/*:refs/forks/%s/*".format(user));
			}
			if (!base)
				base = git.query("rev-parse", tip ~ "^");
			return [
				base,
				tip,
			];
		}
		else
		{
			return [
				null,
				getRemoteRef(
					"https://github.com/%s/%s".format(user, name),
					"refs/heads/%s".format(tip),
					"refs/digger/fork/%s/%s".format(user, tip),
				),
			];
		}
	}

	/// Find the child of a commit, and, if the commit was a merge,
	/// the mainline index of said commit for the child.
	void getChild(string branch, string commit, out string child, out int mainline)
	{
		// TODO: this isn't right. We should look at linear history only.

		needCommit(branch);

		log("Querying history for commit children...");
		auto history = git.getHistory([branch]);

		bool[Git.CommitID] seen;
		void visit(Git.History.Commit* commit)
		{
			if (commit.oid !in seen)
			{
				seen[commit.oid] = true;
				foreach (parent; commit.parents)
					visit(parent);
			}
		}
		auto branchHash = Git.CommitID(branch);
		auto pBranchCommit = branchHash in history.commits;
		enforce(pBranchCommit, "Can't find commit " ~ branch ~" in history");
		visit(*pBranchCommit);

		auto commitHash = Git.CommitID(commit);
		auto pCommit = commitHash in history.commits;
		enforce(pCommit, "Can't find commit in history");
		auto children = (*pCommit).children;
		enforce(children.length, "Commit has no children");
		children = children.filter!(child => child.oid in seen).array();
		enforce(children.length, "Commit has no children under specified branch");
		enforce(children.length == 1, "Commit has more than one child");
		auto childCommit = children[0];
		child = childCommit.oid.toString();

		if (childCommit.parents.length == 1)
			mainline = 0;
		else
		{
			enforce(childCommit.parents.length == 2, "Can't get mainline of multiple-branch merges");
			if (childCommit.parents[0] is *pCommit)
				mainline = 2;
			else
				mainline = 1;

			auto mergeInfo = MergeInfo(
				MergeSpec(
					childCommit.parents[0].oid.toString(),
					CommitRange(null, commit),
					MergeMode.merge,
					true),
				child, mainline);
			if (!mergeCache.canFind(mergeInfo))
			{
				mergeCache ~= mergeInfo;
				saveMergeCache();
			}
		}
	}

	// --- Linear history

	private alias Commit = Git.History.Commit;

	/// Get the linear history starting from `refName` (typically a
	/// branch or tag).
	/// The linear history is built by walking the repository history
	/// DAG such that all points on the returned linear history were
	/// visible to the world when cloning the repository at some point
	/// in time, under the branch `branchName`.  `branchName` is thus
	/// used to decide which parent to follow for some merges.
	Commit*[] getLinearHistory(string refName, string branchName = null)
	{
		import std.typecons : tuple;

		const(Commit)*[][Commit*] commonParentsCache;
		const(Commit)*[][Commit*[2]] commitsBetweenCache;

		assert(refName.startsWith("refs/"), "Invalid refName: " ~ refName);
		auto refHash = Git.CommitID(getRef(refName));
		auto history = git.getHistory([refName]);
		if (!branchName)
		{
			if (refName.startsWith("refs/heads/"))
				branchName = refName["refs/heads/".length .. $];
			else
				assert(false, "branchName must be specified for non-branch refs");
		}
		Commit*[] linearHistory;
		Commit* c = history.commits[refHash];
		do
		{
			linearHistory ~= c;
			auto subject = c.message.length ? c.message[0] : null;
			if (subject.startsWith("Merge branch 'master' of github"))
			{
				enforce(c.parents.length == 2);
				c = c.parents[1];
			}
			else
			if (c.parents.length == 2 && subject.startsWith("Merge pull request #"))
			{
				if (subject.endsWith("/merge_" ~ branchName))
				{
					// We have lost our way and are on the wrong
					// branch, but we can get back on our branch
					// here
					c = c.parents[1];
				}
				else
					c = c.parents[0];
			}
			else
			if (c.parents.length == 2 && subject.skipOver("Merge remote-tracking branch 'upstream/master' into "))
			{
				bool ourBranch = subject == branchName;
				c = c.parents[ourBranch ? 0 : 1];
			}
			else
			if (c.parents.length == 2 && subject.skipOver("Merge remote-tracking branch 'upstream/"))
			{
				subject = subject.chomp(" into merge_" ~ branchName);
				bool ourBranch = subject == branchName ~ "'";
				c = c.parents[ourBranch ? 1 : 0];
			}
			else
			if (c.parents.length > 1)
			{
				enforce(c.parents.length == 2, "Octopus merge");

				// Approximately equivalent to git-merge-base
				static const(Commit)*[] commonParents(in Commit*[] commits) pure
				{
					bool[Commit*][] seen;
					seen.length = commits.length;

					foreach (index, parentCommit; commits)
					{
						auto queue = [parentCommit];
						while (!queue.empty)
						{
							auto commit = queue.front;
							queue.popFront;
							foreach (parent; commit.parents)
							{
								if (parent in seen[index])
									continue;
								seen[index][parent] = true;
								queue ~= parent;
							}
						}
					}

					bool[Commit*] commonParents =
						seen[0]
						.byKey
						.filter!(commit => seen.all!(s => commit in s))
						.map!(commit => tuple(commit, true))
						.assocArray;

					foreach (parent; commonParents.keys)
					{
						if (parent !in commonParents)
							continue; // already removed

						auto queue = parent.parents[];
						while (!queue.empty)
						{
							auto commit = queue.front;
							queue.popFront;
							if (commit in commonParents)
							{
								commonParents.remove(commit);
								queue ~= commit.parents;
							}
						}
					}

					return commonParents.keys;
				}

				static const(Commit)*[] commonParentsOfMerge(Commit* merge) pure
				{
					return commonParents(merge.parents);
				}

				static const(Commit)*[] commitsBetween(in Commit* child, in Commit* grandParent) pure
				{
					const(Commit)*[] queue = [child];
					const(Commit)*[Git.CommitID] seen;

					while (queue.length)
					{
						auto commit = queue[0];
						queue = queue[1..$];
						foreach (parent; commit.parents)
						{
							if (parent.hash in seen)
								continue;
							seen[parent.hash] = commit;

							if (parent is grandParent)
							{
								const(Commit)*[] path;
								while (commit)
								{
									path ~= commit;
									commit = seen.get(commit.hash, null);
								}
								path.reverse();
								return path;
							}

							queue ~= parent;
						}
					}
					throw new Exception("No path between commits");
				}

				// bool dbg = false; //c.hash.toString() == "9545447f8529cafab0fb2c51527541870db844b6";
				auto grandParents = commonParentsCache.require(c, commonParentsOfMerge(c));
				// if (dbg) writeln(grandParents.map!(c => c.hash.toString));
				if (grandParents.length == 1)
				{
					bool[] hasMergeCommits = c.parents
						.map!(parent => commitsBetweenCache.require([parent, grandParents[0]], commitsBetween(parent, grandParents[0]))
							.any!(commit => commit.message[0].startsWith("Merge pull request #"))
						).array;

					// if (dbg)
					// {
					// 	writefln("%d %s", hasMergeCommits.sum, subject);
					// 	foreach (parent; c.parents)
					// 	{
					// 		writeln("---------------------");
					// 		foreach (cm; memoize!commitsBetween(parent, grandParents[0]))
					// 			writefln("%s %s", cm.hash.toString(), cm.message[0]);
					// 		writeln("---------------------");
					// 	}
					// }

					if (hasMergeCommits.sum == 1)
						c = c.parents[hasMergeCommits.countUntil(true)];
					else
						c = c.parents[0];
				}
				else
					c = c.parents[0];
			}
			else
				c = c.parents.length ? c.parents[0] : null;
		} while (c);
		return linearHistory;
	}

	// --- Misc

	/// Reset internal state.
	protected void reset()
	{
		haveMergeCache = false;
		mergeCacheData = null;
	}
}
