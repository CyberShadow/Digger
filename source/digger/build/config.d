module digger.build.config;

import ae.utils.sini : IniFragment;

import digger.build.manager;
import digger.build.components;

/// D build configuration.
struct BuildConfig
{
	/// Explicitly enable or disable a component.
	bool[string] enableComponent;

	/// Returns a list of all enabled components, whether
	/// they're enabled explicitly or by default.
	package string[] getEnabledComponentNames()
	{
		foreach (componentName; buildComponent.byKey)
			enforce(allComponents.canFind(componentName), "Unknown component: " ~ componentName);
		return allComponents
			.filter!(componentName =>
				buildComponent.get(componentName, defaultComponents.canFind(componentName)))
			.array
			.dup;
	}

	/// Common configuration defaults for all components.
	Component.CommonConfig common;

	/// Components' build configuration
	IniFragment!string[string] components;
}

/// An object representing the configuration stage.
/// This object allows setting the build configuration,
/// and choosing which version of D to build.
class Configurator
{
	/// Reference to the parent DManager.
	private DManager manager;

	/// The build configuration.
	private BuildConfig buildConfig;

	package this(DManager manager, BuildConfig buildConfig)
	{
		this.manager = manager;
		this.buildConfig = buildConfig;
	}

	
}
