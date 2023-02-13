module digger.build.versions;

import std.exception;

import ae.utils.aa;

import digger.build.build;
import digger.build.gitstore : CommitID, GitStore;

/// A version specification, indicated as a function which returns a
/// Versions struct.
/// A `VersionSpec` implementation generally begins with a call to
/// `HistoryWalker.resetToProductVersion` and ends with
/// `HistoryWalker.finish`.
alias VersionSpec = Versions delegate(HistoryWalker);

/// Holds a map of versions of each repository to use.
struct Versions
{
	/// Commit hashes of repositories.
	/// The key is the identifier of the remote as returned by Component.repositories
	CommitID[string] commitIDs;
}

/**
   Holds and allows manipulating a map of versions of each repository
   to use.
*/
struct HistoryWalker
{
private:
	/// Current versions.
	Versions versions;

	Builder builder;

	package this(Builder builder, string repositoryName)
	{
		this.builder = builder;
	}

	this(Builder builder, Versions versions)
	{
		this.builder = builder;
		this.versions = versions;
	}

	/// Reset to the specified versions.
	public HistoryWalker reset(Versions versions)
	{
		return HistoryWalker(builder, versions);
	}

	/// Reset versions to the specified point, specified as a product version.
	public HistoryWalker resetToProductVersion(string productVersion)
	{
		builder.buildSite.log("Starting at product version " ~ productVersion);
		Versions versions;
		foreach (componentName; builder.getEnabledComponentNames())
		{
			auto component = builder.getComponent(componentName);
			foreach (repositoryName, repositoryURL; component.repositories)
			{
				auto refName = component.resolveProductVersion(repositoryName, productVersion);
				auto oid = builder.getRef(repositoryName, repositoryURL, refName);
				versions.commitIDs.require(repositoryName, oid);
				if (versions.oids[repositoryName] != oid)
					assert(false, "Component repository version conflict");
			}
		}
		return HistoryWalker(builder, versions);
	}

	public Versions finish() { return versions; }

	alias MergeMode = GitStore.MergeMode; ///
	alias CommitRange = GitStore.CommitRange; ///

	/// Applies a merge onto the given SubmoduleState.
	public HistoryWalker merge(string repositoryName, CommitRange branch, MergeMode mode)
	{
		builder.buildSite.log("Merging %s commits %s..%s".format(submoduleName, branch.base.isNull() ? "" : branch.base.get(), branch.tip));
		enforce(repositoryName in submoduleState.submoduleCommits, "Unknown submodule: " ~ submoduleName);
		auto submodule = getSubmodule(submoduleName);
		auto head = submoduleState.submoduleCommits[submoduleName];
		auto result = submodule.getMerge(head, branch, mode);
		submoduleState.submoduleCommits[submoduleName] = result;
	}

	// /// Removes a merge from the given SubmoduleState.
	// void unmerge(ref SubmoduleState submoduleState, string submoduleName, string[2] branch, MergeMode mode)
	// {
	// 	log("Unmerging %s commits %s..%s".format(submoduleName, branch[0], branch[1]));
	// 	enforce(submoduleName in submoduleState.submoduleCommits, "Unknown submodule: " ~ submoduleName);
	// 	auto submodule = getSubmodule(submoduleName);
	// 	auto head = submoduleState.submoduleCommits[submoduleName];
	// 	auto result = submodule.getUnMerge(head, branch, mode);
	// 	submoduleState.submoduleCommits[submoduleName] = result;
	// }

	// /// Reverts a commit from the given SubmoduleState.
	// /// parent is the 1-based mainline index (as per `man git-revert`),
	// /// or 0 if commit is not a merge commit.
	// void revert(ref SubmoduleState submoduleState, string submoduleName, string[2] branch, MergeMode mode)
	// {
	// 	log("Reverting %s commits %s..%s".format(submoduleName, branch[0], branch[1]));
	// 	enforce(submoduleName in submoduleState.submoduleCommits, "Unknown submodule: " ~ submoduleName);
	// 	auto submodule = getSubmodule(submoduleName);
	// 	auto head = submoduleState.submoduleCommits[submoduleName];
	// 	auto result = submodule.getRevert(head, branch, mode);
	// 	submoduleState.submoduleCommits[submoduleName] = result;
	// }

	// /// Returns the commit hash for the given pull request # (base and tip).
	// /// The result can then be used with addMerge/removeMerge.
	// string[2] getPull(string submoduleName, int pullNumber)
	// {
	// 	auto tip = getSubmodule(submoduleName).getPullTip(pullNumber);
	// 	auto pull = needGitHub().query("https://api.github.com/repos/%s/%s/pulls/%d"
	// 		.format("dlang", submoduleName, pullNumber)).data.parseJSON;
	// 	auto base = pull["base"]["sha"].str;
	// 	return [base, tip];
	// }

	// /// Returns the commit hash for the given branch (optionally GitHub fork).
	// /// The result can then be used with addMerge/removeMerge.
	// string[2] getBranch(string submoduleName, string user, string base, string tip)
	// {
	// 	return getSubmodule(submoduleName).getBranch(user, base, tip);
	// }
}
