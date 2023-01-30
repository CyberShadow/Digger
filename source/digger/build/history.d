module digger.build.history;

import digger.build.manager;

// /**
//    This type holds and allows manipulating a map of versions of each
//    repository to use.

   
// */
// struct HistoryWalker
// {
// 	/// Commit hashes of submodules to build.
// 	private string[string] submoduleCommits;

	

// 	/// Begin customization, starting at the specified commit.
// 	SubmoduleState begin(string commit)
// 	{
// 		log("Starting at meta repository commit " ~ commit);
// 		return SubmoduleState(getMetaRepo().getSubmoduleCommits(commit));
// 	}

// 	alias MergeMode = ManagedRepository.MergeMode; ///

// 	/// Applies a merge onto the given SubmoduleState.
// 	void merge(ref SubmoduleState submoduleState, string submoduleName, string[2] branch, MergeMode mode)
// 	{
// 		log("Merging %s commits %s..%s".format(submoduleName, branch[0], branch[1]));
// 		enforce(submoduleName in submoduleState.submoduleCommits, "Unknown submodule: " ~ submoduleName);
// 		auto submodule = getSubmodule(submoduleName);
// 		auto head = submoduleState.submoduleCommits[submoduleName];
// 		auto result = submodule.getMerge(head, branch, mode);
// 		submoduleState.submoduleCommits[submoduleName] = result;
// 	}

// 	/// Removes a merge from the given SubmoduleState.
// 	void unmerge(ref SubmoduleState submoduleState, string submoduleName, string[2] branch, MergeMode mode)
// 	{
// 		log("Unmerging %s commits %s..%s".format(submoduleName, branch[0], branch[1]));
// 		enforce(submoduleName in submoduleState.submoduleCommits, "Unknown submodule: " ~ submoduleName);
// 		auto submodule = getSubmodule(submoduleName);
// 		auto head = submoduleState.submoduleCommits[submoduleName];
// 		auto result = submodule.getUnMerge(head, branch, mode);
// 		submoduleState.submoduleCommits[submoduleName] = result;
// 	}

// 	/// Reverts a commit from the given SubmoduleState.
// 	/// parent is the 1-based mainline index (as per `man git-revert`),
// 	/// or 0 if commit is not a merge commit.
// 	void revert(ref SubmoduleState submoduleState, string submoduleName, string[2] branch, MergeMode mode)
// 	{
// 		log("Reverting %s commits %s..%s".format(submoduleName, branch[0], branch[1]));
// 		enforce(submoduleName in submoduleState.submoduleCommits, "Unknown submodule: " ~ submoduleName);
// 		auto submodule = getSubmodule(submoduleName);
// 		auto head = submoduleState.submoduleCommits[submoduleName];
// 		auto result = submodule.getRevert(head, branch, mode);
// 		submoduleState.submoduleCommits[submoduleName] = result;
// 	}

// 	/// Returns the commit hash for the given pull request # (base and tip).
// 	/// The result can then be used with addMerge/removeMerge.
// 	string[2] getPull(string submoduleName, int pullNumber)
// 	{
// 		auto tip = getSubmodule(submoduleName).getPullTip(pullNumber);
// 		auto pull = needGitHub().query("https://api.github.com/repos/%s/%s/pulls/%d"
// 			.format("dlang", submoduleName, pullNumber)).data.parseJSON;
// 		auto base = pull["base"]["sha"].str;
// 		return [base, tip];
// 	}

// 	/// Returns the commit hash for the given branch (optionally GitHub fork).
// 	/// The result can then be used with addMerge/removeMerge.
// 	string[2] getBranch(string submoduleName, string user, string base, string tip)
// 	{
// 		return getSubmodule(submoduleName).getBranch(user, base, tip);
// 	}
// }
