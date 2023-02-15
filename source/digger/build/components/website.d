module digger.build.components.website;

import digger.build.components;
import digger.build.manager;

/// Website (dlang.org). Only buildable on POSIX.
final class Website : DlangComponent
{
	protected @property override string submoduleName() { return "dlang.org"; }
	protected @property override string[] sourceDependencies() { return ["druntime", "phobos", "dub"]; }
	protected @property override string[] dependencies() { return ["dmd", "druntime", "phobos", "rdmd"]; }

	/// Website build configuration.
	struct Config
	{
		/// Do not include timestamps, line numbers, or other
		/// volatile dynamic content in generated .ddoc files.
		/// Improves cache efficiency and allows meaningful diffs.
		bool diffable = false;

		deprecated alias noDateTime = diffable;
	}

	protected @property override string configString()
	{
		static struct FullConfig
		{
			Config config;
		}

		return FullConfig(
			config.build.components.website,
		).toJson();
	}

	/// Get the latest version of DMD at the time.
	/// Needed for the makefile's "LATEST" parameter.
	string getLatest()
	{
		auto dmd = getComponent("dmd").submodule;

		auto t = dmd.git.query(["log", "--pretty=format:%ct"]).splitLines.map!(to!int).filter!(n => n > 0).front;

		foreach (line; dmd.git.query(["log", "--decorate=full", "--tags", "--pretty=format:%ct%d"]).splitLines())
			if (line.length > 10 && line[0..10].to!int < t)
				if (line[10..$].startsWith(" (") && line.endsWith(")"))
				{
					foreach (r; line[12..$-1].split(", "))
						if (r.skipOver("tag: refs/tags/"))
							if (r.match(re!`^v2\.\d\d\d(\.\d)?$`))
								return r[1..$];
				}
		throw new Exception("Can't find any DMD version tags at this point!");
	}

	private enum Target { build, test }

	private void make(Target target)
	{
		foreach (dep; ["dmd", "druntime", "phobos"])
		{
			auto c = getComponent(dep);
			c.needInstalled();

			// Need DMD source because https://github.com/dlang/phobos/pull/4613#issuecomment-266462596
			// Need Druntime/Phobos source because we are building its documentation from there.
			c.needSource();
		}
		foreach (dep; ["tools", "dub"]) // for changelog; also tools for changed.d
			getComponent(dep).needSource();

		auto env = baseEnvironment;

		version (Windows)
			throw new Exception("The dlang.org website is only buildable on POSIX platforms.");
		else
		{
			getComponent("dmd").updateEnv(env);

			// Need an in-tree build for SYSCONFDIR.imp, which is
			// needed to parse .d files for the DMD API
			// documentation.
			getComponent("dmd").needBuild(target == Target.test);

			needKindleGen(env);

			foreach (dep; dependencies)
				getComponent(dep).submodule.clean = false;

			auto makeFullName = sourceDir.buildPath(makeFileName);
			auto makeSrc = makeFullName.readText();
			makeSrc
				// https://github.com/D-Programming-Language/dlang.org/pull/1011
				.replace(": modlist.d", ": modlist.d $(DMD)")
				// https://github.com/D-Programming-Language/dlang.org/pull/1017
				.replace("dpl-docs: ${DUB} ${STABLE_DMD}\n\tDFLAGS=", "dpl-docs: ${DUB} ${STABLE_DMD}\n\t${DUB} upgrade --missing-only --root=${DPL_DOCS_PATH}\n\tDFLAGS=")
				.toFile(makeFullName)
			;
			submodule.saveFileState(makeFileName);

			// Retroactive OpenSSL 1.1.0 fix
			// See https://github.com/dlang/dlang.org/pull/1654
			auto dubJson = sourceDir.buildPath("dpl-docs/dub.json");
			dubJson
				.readText()
				.replace(`"versions": ["VibeCustomMain"]`, `"versions": ["VibeCustomMain", "VibeNoSSL"]`)
				.toFile(dubJson);
			submodule.saveFileState("dpl-docs/dub.json");
			scope(exit) submodule.saveFileState("dpl-docs/dub.selections.json");

			string latest = null;
			if (!sourceDir.buildPath("VERSION").exists)
			{
				latest = getLatest();
				log("LATEST=" ~ latest);
			}
			else
				log("VERSION file found, not passing LATEST parameter");

			string[] diffable = null;

			auto pdf = makeSrc.indexOf("pdf") >= 0 ? ["pdf"] : [];

			string[] targets =
				[
					config.build.components.website.diffable
					? makeSrc.indexOf("dautotest") >= 0
						? ["dautotest"]
						: ["all", "verbatim"] ~ pdf ~ (
							makeSrc.indexOf("diffable-intermediaries") >= 0
							? ["diffable-intermediaries"]
							: ["dlangspec.html"])
					: ["all", "verbatim", "kindle"] ~ pdf,
					["test"]
				][target];

			if (config.build.components.website.diffable)
			{
				if (makeSrc.indexOf("DIFFABLE") >= 0)
					diffable = ["DIFFABLE=1"];
				else
					diffable = ["NODATETIME=nodatetime.ddoc"];

				env.vars["SOURCE_DATE_EPOCH"] = "0";
			}

			auto args =
				getMake(env) ~
				[ "-f", makeFileName ] ~
				diffable ~
				(latest ? ["LATEST=" ~ latest] : []) ~
				targets ~
				gnuMakeArgs;
			run(args, env.vars, sourceDir);
		}
	}

	protected override void performBuild()
	{
		make(Target.build);
	}

	protected override void performTest()
	{
		make(Target.test);
	}

	protected override void performStage()
	{
		foreach (item; ["web", "dlangspec.tex", "dlangspec.html"])
		{
			auto src = buildPath(sourceDir, item);
			auto dst = buildPath(stageDir , item);
			if (src.exists)
				cp(src, dst);
		}
	}
}

