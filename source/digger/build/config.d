module digger.build.config;

import std.algorithm.iteration;
import std.algorithm.searching;
import std.exception;

import ae.utils.sini : IniFragment;

import digger.build.site;
import digger.build.components;

/// D build configuration.
/// Serializable.
struct BuildConfig
{
	/// Common configuration defaults for all components.
	Component.CommonConfig common;

	/// Components' build configuration
	IniFragment!string[string] components;
}

// /// An object representing the configuration stage.
// /// This object allows setting the build configuration,
// /// and choosing which version of D to build.
// class Configurator
// {
// 	/// Reference to the parent BuildSite.
// 	private BuildSite buildSite;

// 	/// The build configuration.
// 	private BuildConfig buildConfig;

// 	package this(BuildSite buildSite, BuildConfig buildConfig)
// 	{
// 		this.buildSite = buildSite;
// 		this.buildConfig = buildConfig;
// 	}

	
// }
