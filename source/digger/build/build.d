module digger.build.build;

import std.algorithm.iteration;
import std.algorithm.searching;
import std.array;
import std.exception;
import std.typecons;

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

	package BuildSite buildSite;
	package BuildConfig buildConfig;
	VersionSpec versionSpec;

	package this(BuildSite buildSite, BuildConfig buildConfig, VersionSpec versionSpec)
	{
		this.buildSite = buildSite;
		this.buildConfig = buildConfig;
		this.versionSpec = versionSpec;
	}

	// --- Versions / history

	CommitID[string] versions;

	package CommitID getVersion(Component component, string repositoryName)
	{
		return versions.require(repositoryName,
			versionSpec(HistoryWalker(this, component, repositoryName))
		);
	}

	// --- Repository

	CommitID[string /*refName*/][string /*remoteName*/] resolvedRefs;

	package CommitID getRef(GitRemote remote, string refName)
	{
		return resolvedRefs
			.require(remote.name, null)
			.require(refName, buildSite
				.gitStore
				.getRemoteRef(remote, refName)
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
