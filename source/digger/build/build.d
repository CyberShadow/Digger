module digger.build.build;

import std.algorithm.iteration;
import std.algorithm.searching;
import std.array;
import std.datetime.systime;
import std.exception;
import std.typecons;

import ae.utils.typecons;

import digger.build.config;
import digger.build.components;
import digger.build.gitstore;
import digger.build.versions;
import digger.build.site;

/**
   Manages one build session.

   Stores state about the build progress, and allows post-build
   operations (such as incremental rebuilds).
*/
final class Builder
{
private:
	// /// Current build environment.
	// struct Environment
	// {
	// 	/// Configuration for software dependencies
	// 	struct Deps
	// 	{
	// 		string dmcDir;   /// Where dmc.zip is unpacked.
	// 		string vsDir;    /// Where Visual Studio is installed
	// 		string sdkDir;   /// Where the Windows SDK is installed
	// 		string hostDC;   /// Host D compiler (for DDMD bootstrapping)
	// 	}
	// 	Deps deps; /// ditto

	// 	/// Calculated local environment, incl. dependencies
	// 	string[string] vars;
	// }

	BuildSite buildSiteRef;
	public @property BuildSite buildSite() { return buildSiteRef; }

	package BuildConfig buildConfig;

	VersionSpec versionSpec;

	package this(BuildSite buildSite, BuildConfig buildConfig, VersionSpec versionSpec)
	{
		this.buildSiteRef = buildSite;
		this.buildConfig = buildConfig;
		this.versionSpec = versionSpec;
	}

	// --- Versions / history

	CommitID[string] versions;

	package CommitID getVersion(Component component, GitRemote remote)
	{
		return versions.require(remote.name,
			versionSpec(HistoryWalker(this, component, remote))
		);
	}

	// --- Repository

	CommitID[string /*refName*/][string /*remoteName*/] resolvedRefs;

	/// Resolve the ref from a git remote to a CommitID, fetching it
	/// if necessary and caching the result.
	package CommitID getRef(GitRemote remote, string refName)
	{
		return resolvedRefs
			.require(remote.name, null)
			.require(refName, buildSite
				.gitStore
				.getRemoteRef(remote, refName)
			);
	}

	/// 
	package CommitID getCommitAt(CommitID tip, SysTime date, string branchName)
	{
		import ae.sys.git : Git;
		import ae.utils.time.parse : parseTime;

		auto history = buildSite.gitStore.getLinearHistory(tip, branchName);
		// Note: we don't use binary search here in order to get
		// consistent behavior (regardless of history length) just
		// in case the commit dates are not always increasing.
		foreach_reverse (commit; history)
			if (commit.parsedCommitter.date.parseTime!(Git.Authorship.dateFormat) <= date.get())
				return commit.oid;
		throw new Exception("Timestamp is before first commit");
	}

	// --- Product

	Nullable!Product productInstance;
	public @property Product product()
	{
		return productInstance.require(productRegistry
			.get(buildConfig.productName, null)
			.enforce("Unknown product: " ~ buildConfig.productName)
			(this)
		);
	}

	// --- Components

	Component[string] components;

	package Component getComponent(string componentName)
	{
		return components.require(componentName,
			componentRegistry
			.get(componentName, null)
			.enforce("Unknown component: " ~ componentName)
			(this)
		);
	}
}
