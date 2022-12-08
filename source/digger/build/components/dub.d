module digger.build.components.dub;

import digger.build.components;
import digger.build.manager;

/// The Dub package manager and build tool
final class Dub : Component
{
	protected @property override string submoduleName() { return "dub"; }
	protected @property override string[] sourceDependencies() { return []; }
	protected @property override string[] dependencies() { return []; }
	protected @property override string configString() { return null; }

	protected override void performBuild()
	{
		auto env = baseEnvironment;
		run([dmd, "-i", "-run", "build.d"], env.vars, sourceDir);
	}

	protected override void performStage()
	{
		cp(
			buildPath(sourceDir, "bin", "dub" ~ binExt),
			buildPath(stageDir , "bin", "dub" ~ binExt),
		);
	}
}
