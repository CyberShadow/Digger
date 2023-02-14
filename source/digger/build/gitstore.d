module digger.build.gitstore;

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
import std.typecons;

import ae.sys.git;
import ae.utils.exception;
import ae.utils.json;
import ae.utils.regex;
import ae.utils.time : StdTime;
import ae.utils.typecons;

import digger.build.site;

alias CommitID = Git.CommitID;

/**
   Manages the Git object store repository.

   `digger.build` uses a single bare Git repository for a local cache
   of all Git remotes.  All refs (including tags) are namespaced to
   avoid collisions.

   This repository also stores the results of transient source/history
   operations, such as merges and cherry-picks.
*/
final class GitStore
{
private:

	BuildSite buildSite;

	public this(BuildSite buildSite)
	{
		this.buildSite = buildSite;
	}

	// private ManagedRepository getSubmodule(string name)
	// {
	// 	assert(name, "This component is not associated with a submodule");
	// 	return submodules.require(name,
	// 		{
	// 			auto repo = new SubmoduleRepository();
	// 			repo.dir = buildPath(repoDir, name);

	// 			if (!repo.dir.exists)
	// 			{
	// 				log("Cloning repository %s...".format(name));

	// 				void cloneTo(string target)
	// 				{
	// 					withInstaller({
	// 						import ae.sys.cmd : run;
	// 						auto gitExecutable = gitInstaller.requireInstalled().getExecutable("git");
	// 						run([gitExecutable, "clone", "--mirror", url, target]);
	// 					});


	// 				}
	// 				atomic!cloneTo(repo.dir);

	// 				getMetaRepo().git.run(["submodule", "update", "--init", name]);
	// 			}

	// 			return repo;
	// 		}());
	// } /// ditto

	// 	protected override Git getRepo()
	// 	{
	// 		auto git = Git(dir);
	// 		withInstaller({
	// 			auto gitExecutable = gitInstaller.requireInstalled().getExecutable("git");
	// 			assert(git.commandPrefix[0] == "git");
	// 			git.commandPrefix[0] = gitExecutable;
	// 		});
	// 		return git;
	// 	}


	/// Optional callbacks which shall attempt to resolve a merge conflict.
	public alias MergeConflictResolver = void delegate(ref Git git);
	public static MergeConflictResolver[] mergeConflictResolvers; /// ditto

	Nullable!Git gitInstance;

	/// Low-level wrapper for the Git repository we manage.
	public @property ref const(Git) git()
	{
		return gitInstance.require({
			auto git = buildSite.createGit(buildSite.gitStoreDir);
			if (!git.path.exists)
			{
				git.path.mkdirRecurse();
				git.run("init", "--bare");
			}
			return git;
		}());
	}

	Nullable!(Git.ObjectReader) readerInstance;
	@property ref Git.ObjectReader reader() { return readerInstance.require(git.createObjectReader()); }

	Nullable!(Git.ObjectMultiWriter) writerInstance;
	@property ref Git.ObjectMultiWriter writer() { return writerInstance.require(git.createObjectWriter()); }

	// --- Head

	bool haveCommit(CommitID commitID)
	{
		try
			enforce(reader.read(commitID).type == "commit", "Wrong object type");
		catch (Git.ObjectMissingException e)
			return false;
		return true;
	}

	public void exportCommit(CommitID commitID, string targetPath)
	{
		if (!haveCommit(commitID) && mergeCache.find!(entry => entry.result == commitID)())
		{
			// Might be a GC-ed merge. Try to recreate the merge
			auto hit = mergeCache.find!(entry => entry.result == commitID)();
			enforce(!hit.empty, "Unknown commit %s".format(commitID));
			auto mergeResult = performMerge(hit.front.spec);
			enforce(mergeResult == commitID, "Unexpected merge result: expected %s, got %s".format(commitID, mergeResult));
		}

		git.exportCommit(commitID, targetPath, reader);
	}

	/// Returns the commit OID of the given named ref.
	package CommitID getRef(string refName)
	{
		return git.query("rev-parse", "--verify", "--quiet", refName).CommitID;
	}

	// /// Ensure that the specified commit is fetched.
	// void needCommit(CommitID commitID)
	// {
	// 	enforce(haveCommit(commitID), "Don't have commit " ~ commitID.toString() ~ ", can't proceed.");

	// 	// void check()
	// 	// {
	// 	// 	enforce(git.query(["cat-file", "-t", commitID.toString()]) == "commit",
	// 	// 		"Unexpected object type");
	// 	// }

	// 	// try
	// 	// 	check();
	// 	// catch (Exception e)
	// 	// {
	// 	// 	if (offline)
	// 	// 	{
	// 	// 		log("Don't have commit " ~ commitID.toString() ~ " and in offline mode, can't proceed.");
	// 	// 		throw new Exception("Giving up");
	// 	// 	}
	// 	// 	else
	// 	// 	{
	// 	// 		log("Don't have commit " ~ commitID.toString() ~ ", updating and retrying...");
	// 	// 		update();
	// 	// 		check();
	// 	// 	}
	// 	// }
	// }

	// /// Update the remote.
	// /// Return true if any updates were fetched.
	// public bool update()
	// {
	// 	if (!offline)
	// 	{
	// 		log("Updating...");
	// 		auto oldRefs = git.query(["show-ref"]);
	// 		git.run("-c", "fetch.recurseSubmodules=false", "remote", "update", "--prune");
	// 		git.run("-c", "fetch.recurseSubmodules=false", "fetch", "--force", "--tags");
	// 		auto newRefs = git.query(["show-ref"]);
	// 		return oldRefs != newRefs;
	// 	}
	// 	else
	// 		return false;
	// }

	// --- Merge cache

	/// Represents a series of commits as a start and end point in the repository history.
	public struct CommitRange
	{
		/// The commit before the first commit in the range.
		/// May be null in some circumstances.
		Nullable!CommitID base;
		/// The last commit in the range.
		CommitID tip;
	}

	/// How to merge a branch into another
	public enum MergeMode
	{
		merge,      /// git merge (commit with multiple parents) of the target and branch tips
		cherryPick, /// apply the commits as a patch
	}
	struct MergeSpec
	{
		CommitID target;       /// What is it merged onto (or out of, when un-merging)
		CommitRange branch;    /// What is being merged (or un-merged)
		MergeMode mode;        /// How to merge
		bool revert = false;   /// Un-merge instead of merge
	}
	struct MergeInfo
	{
		MergeSpec spec;
		CommitID result;
		int mainline = 0; // git parent index of the "target", if any
	}
	alias MergeCache = MergeInfo[];

	@property string mergeCachePath() { return buildPath(git.path, "digger-build-mergecache.json"); }

	Nullable!MergeCache mergeCacheInstance;
	@property ref MergeCache mergeCache()
	{
		return mergeCacheInstance.require({
			if (mergeCachePath.exists)
				return mergeCachePath.readText().jsonParse!MergeCache;
			return MergeCache.init;
		}());
	}

	void saveMergeCache()
	{
		std.file.write(mergeCachePath(), toJson(mergeCache));
	}

	// --- Merge

	/// Returns the hash of the merge between the target and branch commits.
	/// Performs the merge if necessary. Caches the result.
	public CommitID getMerge(CommitID target, CommitRange branch, MergeMode mode)
	{
		return getMergeImpl(MergeSpec(target, branch, mode, false));
	}

	/// Returns the resulting hash when reverting the branch from the base commit.
	/// Performs the revert if necessary. Caches the result.
	/// mainline is the 1-based mainline index (as per `man git-revert`),
	/// or 0 if commit is not a merge commit.
	public CommitID getRevert(CommitID target, CommitRange branch, MergeMode mode)
	{
		return getMergeImpl(MergeSpec(target, branch, mode, true));
	}

	CommitID getMergeImpl(MergeSpec spec)
	{
		auto hit = mergeCache.find!(entry => entry.spec == spec)();
		if (!hit.empty)
			return hit.front.result;

		auto mergeResult = performMerge(spec);

		mergeCache ~= MergeInfo(spec, mergeResult);
		saveMergeCache();
		return mergeResult;
	}

	enum mergeCommitMessage = "digger.build merge";
	enum revertCommitMessage = "digger.build revert";

	/// Performs a merge or revert.
	CommitID performMerge(MergeSpec spec)
	{
		import ae.sys.cmd : getTempFileName;
		import ae.sys.file : removeRecurse;

		log("%s %s into %s.".format(spec.revert ? "Reverting" : "Merging", spec.branch, spec.target));

		auto conflictResolvers = mergeConflictResolvers;
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
			CommitID needCommit(CommitID commitID)
			{
				tmpRepo.run(["fetch", "--quiet", git.path.absolutePath, commitID.toString()]);
				return commitID;
			}

			tmpRepo.run("checkout", "--quiet", needCommit(spec.target.CommitID).toString());

			void doMerge()
			{
				final switch (spec.mode)
				{
					case MergeMode.merge:
						if (!spec.revert)
							tmpRepo.run("merge", "--quiet", "--no-ff", "-m", mergeCommitMessage, needCommit(spec.branch.tip.CommitID).toString());
						else
						{
							// When reverting in merge mode, we try to
							// find the merge commit following the branch
							// tip, and revert only that merge commit.
							CommitID mergeCommit; int mainline;
							getChild(spec.target, spec.branch.tip, /*out*/mergeCommit, /*out*/mainline);

							string[] args = ["revert", "--no-edit"];
							if (mainline)
								args ~= ["--mainline", text(mainline)];
							args ~= [needCommit(mergeCommit).toString()];
							tmpRepo.run(args);
						}
						break;

					case MergeMode.cherryPick:
						enforce(!spec.branch.base.isNull(), "Must specify a branch base for a cherry-pick merge");
						auto range = needCommit(spec.branch.base.get()).toString() ~ ".." ~ needCommit(spec.branch.tip).toString();
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

			auto commitID = tmpRepo.query("rev-parse", "HEAD");
			log("Merge successful: " ~ commitID);
			git.run(["fetch", "--quiet", tmpRepo.path.absolutePath, commitID]);
			return commitID.CommitID;
		}

		assert(false, "Unreachable");
	}

	/// Finds and returns the merge parents of the given merge commit.
	/// Queries the git repository if necessary. Caches the result.
	public MergeInfo getMergeInfo(CommitID merge)
	{
		auto hit = mergeCache.find!(entry => entry.result == merge && !entry.spec.revert)();
		if (!hit.empty)
			return hit.front;

		auto parents = git.query(["log", "--pretty=%P", "-n", "1", merge.toString()]).split();
		enforce(parents.length > 1, "Not a merge: " ~ merge.toString());
		enforce(parents.length == 2, "Too many parents: " ~ merge.toString());

		auto spec = MergeSpec(parents[0].CommitID, CommitRange(Nullable!CommitID.init, parents[1].CommitID), MergeMode.merge, false);
		auto info = MergeInfo(spec, merge, 1);
		mergeCache ~= info;
		return info;
	}

	/// Follows the string of merges starting from the given
	/// head commit, up till the merge with the given branch.
	/// Then, reapplies all merges in order,
	/// except for that with the given branch.
	public CommitID getUnMerge(CommitID head, CommitRange branch, MergeMode mode)
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
	package CommitID getRemoteRef(string remoteName, string remoteURL, string remoteRef)
	{
		enforce(remoteRef.startsWith("refs/"), "Invalid remote ref");
		auto localRef = "refs/" ~ remoteName ~ remoteRef["refs".length .. $];
		if (!offline)
		{
			log("Fetching from %s (%s -> %s) ...".format(remoteURL, remoteRef, localRef));
			git.run("fetch", remoteURL, "+%s:%s".format(remoteRef, localRef));
		}
		return getRef(localRef);
	}

	/// Fetch all remote refs.
	/// Generally we should never need to do this,
	/// except for very specific cases like getting a commit
	/// for which we don't know a containing branch.
	package void fetchAllRemoteRefs(string remoteName, string remoteURL)
	{
		enforce(!offline, "Cannot fetch all refs while offline");
		log("Fetching all refs from %s ...".format(remoteURL));
		git.run("fetch", remoteURL, "+refs/*:refs/%s/*".format(remoteName));
	}

	/**
	   Find the child of a commit, and, if the commit was a merge,
	   the mainline index of said commit for the child.
	*/
	void getChild(
		/// Tip of the history which will be scanned to find the child.
		CommitID branch,
		/// The parent commit, whose child is to be found.
		CommitID commit,
		/// Will store the commit ID of the found child.
		out CommitID child,
		/// When the found child is a merge commit, will store the
		/// parent index of `commit`.
		out int mainline,
	)
	{
		// Note: there is an edge case which the current version of this function can't handle:
		// when `commit` has multiple children which are visible from `branch`.
		// To avoid this we could add a `mainBranchName` parameter and scan in the same way as
		// `gitLinearHistory`, but let's cross that bridge when we get there.

		log("Querying history for commit children...");
		auto history = git.getHistory([branch.toString()]);

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
		enforce(pBranchCommit, "Can't find branch commit " ~ branch.toString() ~ " in history");
		visit(*pBranchCommit);

		auto pCommit = commit in history.commits;
		enforce(pCommit, "Can't find parent commit " ~ commit.toString() ~ " in history");
		auto children = (*pCommit).children;
		enforce(children.length, "Commit has no children");
		children = children.filter!(child => child.oid in seen).array();
		enforce(children.length, "Commit has no children under specified branch");
		enforce(children.length == 1, "Commit has more than one child");
		auto childCommit = children[0];
		child = childCommit.oid;

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
					childCommit.parents[0].oid,
					CommitRange(Nullable!CommitID.init, commit),
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

	alias Commit = Git.History.Commit;

	/// Get the linear history starting from `refName` (typically a
	/// (namespaced) branch or tag).
	/// The linear history is built by walking the repository history
	/// DAG in a way which attempts to reconstruct the publicly
	/// visible history, i.e. such that all points on the returned
	/// linear history were visible to the world when cloning the
	/// repository at some point in time, via the branch `branchName`.
	/// `branchName` is thus used to decide which parent to follow for
	/// some merges.
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

	void log(string line)
	{
		buildSite.log("gitstore: " ~ line);
	}

	bool offline() { return buildSite.config.offline; }
}
