module digger.build.components.dmd;

import ae.utils.time.parse;

import std.algorithm.comparison;
import std.ascii;
import std.datetime.systime;
import std.meta : AliasSeq;
import std.typecons : Nullable;

import digger.build.build : Builder;
import digger.build.components;
import digger.build.gitstore : GitRemote, CommitID;

/// Base class for components following https://github.org/dlang/ conventions.
class DlangComponent : Component
{
private:
}

/// Product definition for the DigitalMars D implementation and
/// distribution, with DMD as the compiler, developed under the
/// https://github.com/dlang/ namespace.
final class DlangProduct : Product
{
private:
	public override @property string name() const { return "dlang"; }

	static bool isVersionNumberTag(string productVersion) { return productVersion.length >= 2 && productVersion[0] == 'v' && productVersion[1].isDigit; }

	/// Repositories which have tags like "v2.100.0".
	alias repositoriesUsingDVersionTags = AliasSeq!("dmd", "druntime", "phobos", "tools", "installer", "dlang.org");

	/// Repositories with a "stable" branch (used for DMD stable releases).
	alias repositoriesUsingStableBranch = AliasSeq!("dmd", "druntime", "phobos", "tools", "installer", "dlang.org", "dub");

	public override CommitID resolveProductVersion(GitRemote remote, string productVersion, Nullable!SysTime date)
	{
		if (isVersionNumberTag(productVersion))
		{
			auto refName = "refs/tags/" ~ productVersion;
			if (remote.name.among(repositoriesUsingDVersionTags))
				return builder.getRef(remote, refName);
			else
			{
				import ae.sys.git : Git;

				// For version numbers, use the time when this version was tagged in the DMD repo.
				auto dmd = builder.getComponent("dmd");
				auto remotes = dmd.gitRemotes;
				assert(remotes.length == 1);
				auto dmdRemote = remotes[0];
				auto commitID = resolveProductVersion(dmdRemote, productVersion, date);
				auto commit = builder.buildSite.gitStore.getCommit(commitID);
				auto dmdDate = commit.parsedCommitter.date.parseTime!(Git.Authorship.dateFormat);

				productVersion = "stable";
				date = dmdDate;
			}
		}
		return super.resolveProductVersion(remote, productVersion, date);
	}

	public override string getBranchName(string repositoryName, string productVersion)
	{
		if (isVersionNumberTag(productVersion))
			if (repositoryName.among(repositoriesUsingStableBranch))
				productVersion = "stable";
		if (productVersion == "stable")
			if (!repositoryName.among(repositoriesUsingStableBranch))
				productVersion = "master";
		return super.getBranchName(repositoryName, productVersion);
	}

	/// Default components.
	public override string[] defaultComponents() { return ["dmd", "druntime", "phobos-includes", "phobos", "rdmd"]; }

	mixin RegisterProduct;
}
