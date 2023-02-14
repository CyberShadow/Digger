module digger.build.versions;

import std.algorithm.searching;
import std.array;
import std.exception;
import std.format;
import std.json;
import std.regex;
import std.typecons;

import ae.utils.aa;
import ae.utils.regex;

import digger.build.build;
import digger.build.components;
import digger.build.gitstore : CommitID, GitStore;

/// A version specification, indicated as a function which returns a
/// `CommitID`.
/// A `VersionSpec` implementation generally begins with a call to
/// `HistoryWalker.resetToProductVersion` and ends with
/// `HistoryWalker.finish`.
/// Though it's called once for each component repository involved,
/// the same `VersionSpec` is used for all repositories.
alias VersionSpec = CommitID delegate(HistoryWalker);

/**
   Holds and allows manipulating a point in a repository's history.
*/
struct HistoryWalker
{
private:
	struct Session
	{
		Builder builder;
		Component component;

		/// The repository whose history we're finding.
		string repositoryName;
	}
	/*immutable*/ Session* session;

	/// Current commit.
	immutable CommitID commitID;

	package this(Builder builder, Component component, string repositoryName)
	{
		this(new Session(builder, component, repositoryName), CommitID.init);
	}

	this(Session* session, CommitID commitID)
	{
		this.session = session;
		this.commitID = commitID;
	}

	/// Reset to the specified commit.
	public HistoryWalker reset(CommitID commitID)
	{
		return HistoryWalker(session, commitID);
	}

	/// Reset versions to the specified point, specified as a product version.
	public HistoryWalker resetToProductVersion(string productVersion)
	{
		session.builder.buildSite.log("Starting at product version " ~ productVersion);
		auto refName = session.component.resolveProductVersion(session.repositoryName, productVersion);
		auto repositoryURL = session.component.repositoryURLs[session.repositoryName];
		auto commitID = session.builder.getRef(session.repositoryName, repositoryURL, refName);
		return HistoryWalker(session, commitID);
	}

	public CommitID finish() { return commitID; }

	alias MergeMode = GitStore.MergeMode; ///
	alias CommitRange = GitStore.CommitRange; ///

	/// Applies a merge onto the given SubmoduleState.
	public HistoryWalker merge(string repositoryName, CommitRange branch, MergeMode mode)
	{
		if (repositoryName != session.repositoryName)
			return this; // Ignore operation for another repository

		session.builder.buildSite.log("Merging %s commits %s..%s".format(
			repositoryName,
			branch.base.isNull() ? "" : branch.base.get().toString(), branch.tip
		));

		auto result = session.builder.buildSite.gitStore.getMerge(commitID, branch, mode);
		return HistoryWalker(session, result);
	}

	/// Removes a merge from the given SubmoduleState.
	public HistoryWalker unmerge(string repositoryName, CommitRange branch, MergeMode mode)
	{
		if (repositoryName != session.repositoryName)
			return this; // Ignore operation for another repository

		session.builder.buildSite.log("Unmerging %s commits %s..%s".format(
			repositoryName,
			branch.base.isNull() ? "" : branch.base.get().toString(), branch.tip
		));

		auto result = session.builder.buildSite.gitStore.getUnMerge(commitID, branch, mode);
		return HistoryWalker(session, result);
	}

	/// Reverts a commit from the given SubmoduleState.
	/// parent is the 1-based mainline index (as per `man git-revert`),
	/// or 0 if commit is not a merge commit.
	HistoryWalker revert(string repositoryName, CommitRange branch, MergeMode mode)
	{
		if (repositoryName != session.repositoryName)
			return this; // Ignore operation for another repository

		session.builder.buildSite.log("Unmerging %s commits %s..%s".format(
			repositoryName,
			branch.base.isNull() ? "" : branch.base.get().toString(), branch.tip
		));

		auto result = session.builder.buildSite.gitStore.getRevert(commitID, branch, mode);
		return HistoryWalker(session, result);
	}

	/// Returns the commit hash for the given GitHub pull request # (base and tip).
	/// The result can then be used with addMerge/removeMerge.
	CommitRange getPull(string repositoryName, int pullNumber)
	{
		if (repositoryName != session.repositoryName)
			return CommitRange.init; // Ignore operation for another repository

		auto repositoryURL = session.component.repositoryURLs[repositoryName];
		enforce(repositoryURL.startsWith("https://github.com/"), "Not a GitHub repository");

		auto refName = "refs/pull/%d/head".format(pullNumber);
		auto tip = session.builder.getRef(session.repositoryName, repositoryURL, refName);

		auto githubOwner = repositoryURL.split("/")[3];
		auto githubRepositoryName = repositoryURL.split("/")[4];

		auto pull = session.builder.buildSite.github.query("https://api.github.com/repos/%s/%s/pulls/%d"
			.format(githubOwner, githubRepositoryName, pullNumber)).data.parseJSON;
		auto base = CommitID(pull["base"]["sha"].str);

		return CommitRange(
			Nullable!CommitID(base),
			tip,
		);
	}

	/// Returns the commit hash for the given branch (optionally GitHub fork).
	/// The result can then be used with `merge`/`unmerge`.
	CommitRange getBranch(string repositoryName, string user, string base, string tip)
	{
		if (repositoryName != session.repositoryName)
			return CommitRange.init; // Ignore operation for another repository

		auto repositoryURL = session.component.repositoryURLs[repositoryName];
		enforce(repositoryURL.startsWith("https://github.com/"), "Not a GitHub repository");
		auto githubOwner = repositoryURL.split("/")[3];
		auto githubRepositoryName = repositoryURL.split("/")[4];

		if (user) enforce(user.match(re!`^\w[\w\-]*$`), "Bad remote name");
		if (base) enforce(base.match(re!`^\w[\w\-\.]*$`), "Bad branch base name");
		if (true) enforce(tip .match(re!`^\w[\w\-\.]*$`), "Bad branch tip name");

		if (!user)
			user = githubOwner;
		auto name = githubRepositoryName;

		auto forkName = repositoryName ~ "-@" ~ user;
		auto forkURL = "https://github.com/%s/%s".format(user, name);

		if (!CommitID(tip).collectException)
		{
			if (!session.builder.buildSite.config.offline)
			{
				// We don't know which branch the commit will be in, so just grab everything.
				session.builder.buildSite.log("Fetching everything from %s ...".format(forkURL));
				session.builder.buildSite.gitStore.fetchAllRemoteRefs(forkName, forkURL);
			}
			if (!base)
				base = session.builder.buildSite.gitStore.getRef(tip ~ "^").toString();
			return CommitRange(
				Nullable!CommitID(CommitID(base)),
				CommitID(tip),
			);
		}
		else
		{
			return CommitRange(
				Nullable!CommitID.init,
				session.builder.getRef(
					forkName,
					forkURL,
					"refs/heads/%s".format(tip),
				),
			);
		}
	}
}
